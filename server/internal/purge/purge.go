// Package purge deletes an account and everything that references it (spec
// 02 §15). Who may ask for it is the caller's business: the API's #41 checks
// an account.delete step-up and a writer's signature, the CLI is the operator.
//
// # What "delete" means
//
// Every op-log blob is ciphertext the server cannot open; deleting the account
// deletes the rows that hold it and the wrapped key material, in one
// transaction. Backups are not rewritten; they age out on their own schedule
// (spec 02 §15.5, 05 §5.8).
//
// # Why the relation list is discovered and not written down
//
// A purge is only as good as its least-remembered table. This package asks the
// database which relations carry a user_id, and iterates THAT — so a table
// added by a later change is covered the moment it exists, and one that cannot
// be covered automatically has to be classified by hand before any purge will
// run at all (see Classify). It asks pg_class, NOT information_schema: the
// latter does not list materialized views, cannot see other schemas through a
// `table_schema = 'public'` filter, and is privilege-filtered for the non-owner
// runtime role. A materialized view cannot be deleted from, so the purge
// REFRESHES it once the underlying rows are gone and then re-counts.
//
// # Ordering, and why it is not arbitrary
//
// The deletion itself is ONE statement: DELETE FROM users. Everything else
// follows through ON DELETE CASCADE, and that is load bearing: op_log and
// key_history are append-only by trigger, writers revoke-once, and each
// trigger's one exemption is "the users row is already gone", which only the
// cascade satisfies. The runtime role holds no DELETE on op_log, key_history
// or writers at all; the cascade runs as the referencing table's owner. A
// purge that issued its own DELETE against those tables first would be
// refused, which is the correct answer to that question. The sweep below runs
// AFTER the cascade for the same reason.
package purge

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mailq"
)

// handledWithoutUserID names the relations that hold per-user rows under some
// key OTHER than a user_id column, and that this package therefore has to purge
// by hand. Being on this list is a claim that Purge deals with it; a test
// asserts the claim for each entry.
//
// Names are SCHEMA-QUALIFIED, here and in notUserLinked. Unqualified names
// would classify `archive.users` as "the account table, handled" — a snapshot
// of every account, waved through by a list that was written about a different
// object with the same last name.
var handledWithoutUserID = []string{
	// The account table itself: keyed by `id`, so schema discovery does not see
	// it. It is deleted by name, and that one statement is what cascades
	// everything else.
	"public.users",
}

// notUserLinked names the relations that hold nothing attributable to one user,
// so a purge correctly touches none of them. Every entry is a decision, not an
// omission.
var notUserLinked = []string{
	// Single-use beta invite codes. A row is a code hash, a note in the
	// operator's words, and — once spent — a `redeemed_by` link to the account
	// that spent it.
	//
	// The link is the only user-attributable thing here and it is removed by
	// the schema itself: `redeemed_by uuid REFERENCES users(id) ON DELETE SET
	// NULL`. What survives the purge is "some code was spent, and nobody knows
	// by whom", which is the same unattributable residue dict_entries leaves
	// after ForgetSubmitter.
	//
	// The column is NOT called user_id on purpose. A user_id column here would
	// be discovered as user-scoped, and CheckCascades would then correctly
	// refuse the whole purge because SET NULL is exactly the silent survival it
	// guards against — while CASCADE, the action it would demand instead, would
	// DELETE the row and put a spent code back into circulation. Neither
	// outcome is wanted, so the table is not user-scoped and says so here.
	"public.invite_codes",
	// The deleted-account tombstone: SHA-256 of the session tokens that were
	// live when an account was deleted, so the devices holding them get a 410
	// instead of a 401 and can safely wipe. It is WRITTEN BY the deletion, so it
	// is the one table that must survive one, and it carries no user id, no
	// subject, no address and nothing derived from them.
	"public.deleted_account_sessions",
	// goose's own migration ledger.
	"public.goose_db_version",
	// The account ceremonies' keyless tables (spec 02 §5.3, §15.3): pauses and
	// counters keyed by an email_tag or a writer hash and swept within a day;
	// device-freeze nonces, which name a writer id and no account; the key
	// fingerprints.
	"public.email_code_pauses",
	"public.rate_counters",
	"public.device_freeze_challenges",
	"public.server_meta",
	// Spec 07 §2.12: the bank catalog, and the waitlist with its tokens. An
	// entry is an address that has not become an account (or, once joined, a
	// tag with no address); the account's own joined entry and its mail rows
	// are erased by eraseAddress below, and the 30-day sweep deletes joined
	// entries regardless.
	"public.banks",
	"public.waitlist_entries",
	"public.waitlist_tokens",
	// The operator audit log: internal ids and actions, never an address, and
	// append-only by trigger for 400 days.
	"public.admin_audit",
}

// Report is what a purge did, per table. It is returned even on the paths that
// deleted nothing, so an operator can tell "no rows" from "never ran".
type Report struct {
	// Users are the accounts actually deleted. Empty when the user did not
	// exist, which is not an error: a purge is idempotent by design, and a
	// retry after a network failure must not look like a fresh disaster.
	Users []uuid.UUID

	// Rows maps table name to the number of rows removed for those users. Every
	// discovered user-scoped table appears, including the ones that held
	// nothing — a table silently absent from this map is indistinguishable from
	// a table silently skipped.
	Rows map[string]int

	// SweptWithoutCascade names tables whose rows survived the cascade and had
	// to be deleted explicitly. It is not decoration: an entry here means the
	// table's user_id foreign key is missing ON DELETE CASCADE, so every OTHER
	// path that deletes a user (a manual DELETE, a future task) leaves those
	// rows behind. The purge fixes its own case and reports the schema defect.
	SweptWithoutCascade []string

	// RefreshedViews names the materialized views the purge had to re-run
	// because they still listed the deleted account. A matview cannot be
	// deleted from, so this is the only way its copy of the user's rows goes
	// away — and an entry here means a stored copy of user data exists that
	// nothing else in the system knows about. Spec §5 contemplates one; it
	// should still be looked at.
	RefreshedViews []string

	// UnownedCodes is how many email codes to the account's address that
	// belonged to no account (a signup's, a reset's) the purge deleted by
	// their tag (spec 02 §15.2 step 2). Always 0 without a Tagger.
	UnownedCodes int

	// Goodbyes is how many `deleted` emails the purge queued (step 4).
	Goodbyes int
}

func newReport() Report { return Report{Rows: map[string]int{}} }

// Total is every row this purge removed, across every table.
func (r Report) Total() int {
	n := 0
	for _, v := range r.Rows {
		n += v
	}
	return n
}

// ErrIncomplete means the purge could not prove it removed everything, and
// therefore removed nothing. It is deliberately not recoverable by retrying the
// same call: the fix is a schema or configuration change.
//
// # Blast radius, stated because fail-closed has one
//
// The refusal is GLOBAL, not per-account. One unclassified relation — a DBA's
// `users_backup_20260801`, a matview somebody left behind — makes DELETE
// /api/v1/account answer 500 for EVERY user, and that endpoint is required by
// App Review 5.1.1(v). The reason is named only in the operator log; the
// response deliberately does not carry it.
//
// That is still the right direction (the alternative is reporting a deletion
// that did not happen), but it means a schema change nobody thought of as
// risky can break account deletion for everyone, silently from the outside.
// The operator-facing consequences:
//
//   - `ledgerd purge-user --dry-run` runs the same classification and is the
//     cheapest way to find out. Run it after any schema change.
//   - The fix is one line in handledWithoutUserID / notUserLinked, or a
//     user_id column with ON DELETE CASCADE. It is not an emergency to reason
//     about, but it IS an emergency to notice.
var ErrIncomplete = errors.New("purge: refused: cannot account for every relation")

// ---------------------------------------------------------------------------
// Schema discovery
// ---------------------------------------------------------------------------

// Relation is one object the purge has to account for: which schema it is in,
// what it is called, and what KIND of thing it is.
//
// It is a struct rather than a "schema.name" string because the two are used
// differently and mixing them up is a real bug: the display form goes into
// messages and report keys, while the SQL form has to be quoted as TWO
// identifiers. `pgx.Identifier{"archive.op_log"}.Sanitize()` produces
// `"archive.op_log"` — one identifier with a dot in its name, which does not
// exist — and the count that followed would silently fail rather than protect
// anything.
type Relation struct {
	Schema string
	Name   string
	// Kind is pg_class.relkind: 'r' ordinary table, 'p' partitioned table,
	// 'm' materialized view, 'f' foreign table.
	Kind byte
}

// String is the display form, and the key Report.Rows uses.
func (r Relation) String() string { return r.Schema + "." + r.Name }

// SQL is the correctly quoted two-part identifier.
func (r Relation) SQL() string { return pgx.Identifier{r.Schema, r.Name}.Sanitize() }

// KindName spells relkind for an error message; an operator reading "relkind m"
// learns nothing.
func (r Relation) KindName() string {
	switch r.Kind {
	case 'r':
		return "table"
	case 'p':
		return "partitioned table"
	case 'm':
		return "materialized view"
	case 'f':
		return "foreign table"
	default:
		return fmt.Sprintf("relkind %q", string(r.Kind))
	}
}

// relationFilter is the WHERE clause both discovery queries share, and every
// clause in it is load bearing. It replaced an information_schema query that
// was blind in three separate ways, each of which let a relation holding a
// deleted user's rows go unpurged AND unreported:
//
//   - information_schema.tables does not list MATERIALIZED VIEWS at all. Spec
//     §5 explicitly contemplates one ("the existing PWA may additionally serve
//     alphas via a temporary server-side materialized view"), so this is not a
//     hypothetical object: a matview over op_log holds a COPY of the user's
//     plaintext blobs, and the old query could not see it.
//   - it was scoped to `public`, so a table in any other schema — an
//     `archive.op_log_2026`, the obvious thing a DBA creates — was invisible.
//   - information_schema is PRIVILEGE-FILTERED: it shows only relations the
//     current role has some privilege on. Plan D5 runs ledgerd as a non-owner
//     `ledger_runtime`, and `ledgerd purge-user` opens the same DSN, so a
//     relation that role cannot touch was simply absent from a list whose whole
//     job is to be exhaustive. pg_class is not filtered; a relation the role
//     cannot read is now DISCOVERED, and the count against it fails loudly
//     instead of being skipped silently.
//
// 'i', 'S', 'v', 'c', 't' are excluded because none of them stores rows a purge
// could delete: indexes and sequences hold no user columns, a plain view is a
// query over relations already in this list, and composite/TOAST types are not
// relations a DELETE addresses. A partition (relispartition) is excluded too —
// it IS storage, but deleting from its parent covers it, and listing both would
// demand a classification for every partition anyone ever adds.
const relationFilter = `
	  cl.relkind IN ('r','p','m','f')
	  AND NOT cl.relispartition
	  AND ns.nspname NOT IN ('pg_catalog','information_schema')
	  AND ns.nspname !~ '^pg_'`

// UserScopedTables returns every relation carrying a user_id column, in any
// schema, sorted. This is the list Purge iterates.
//
// The name says "Tables" and the return says Relation: a materialized view with
// a user_id is exactly the case this function exists to stop being invisible,
// and pretending it is a table in the return type would reintroduce the blind
// spot at the type level.
func UserScopedTables(ctx context.Context, pool *pgxpool.Pool) ([]Relation, error) {
	if pool == nil {
		return nil, errors.New("purge: pool is nil")
	}
	return scanRelations(ctx, pool, `
		SELECT ns.nspname, cl.relname, cl.relkind::text
		  FROM pg_class cl
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		  JOIN pg_attribute a ON a.attrelid = cl.oid
		 WHERE`+relationFilter+`
		   AND a.attname = 'user_id'
		   AND a.attnum > 0
		   AND NOT a.attisdropped
		 ORDER BY ns.nspname, cl.relname`, "discover user-scoped relations")
}

// allRelations returns every relation a purge has to have an opinion about.
func allRelations(ctx context.Context, pool *pgxpool.Pool) ([]Relation, error) {
	return scanRelations(ctx, pool, `
		SELECT ns.nspname, cl.relname, cl.relkind::text
		  FROM pg_class cl
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		 WHERE`+relationFilter+`
		 ORDER BY ns.nspname, cl.relname`, "list relations")
}

func scanRelations(ctx context.Context, pool *pgxpool.Pool, sql, what string) ([]Relation, error) {
	rows, err := pool.Query(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("purge: %s: %w", what, err)
	}
	defer rows.Close()
	var out []Relation
	for rows.Next() {
		var r Relation
		var kind string
		if err := rows.Scan(&r.Schema, &r.Name, &kind); err != nil {
			return nil, fmt.Errorf("purge: %s: %w", what, err)
		}
		if kind == "" {
			return nil, fmt.Errorf("purge: %s: %s.%s has an empty relkind", what, r.Schema, r.Name)
		}
		r.Kind = kind[0]
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("purge: %s: %w", what, err)
	}
	// A name is never validated against a pattern and never interpolated raw;
	// Relation.SQL quotes both parts, which is correct for every name Postgres
	// permits — including one with a quote or a dot in it. A regex screen here
	// would refuse legal names while adding nothing Sanitize does not already
	// guarantee.
	return out, nil
}

// Classification is every relation in the database, sorted into what a purge
// does with it.
type Classification struct {
	// UserScoped carry a user_id column and are emptied by the cascade (or,
	// for the kinds nothing cascades into, by the explicit sweep).
	UserScoped []Relation
	// HandledWithoutUserID are purged by a hand-written step.
	HandledWithoutUserID []string
	// NotUserLinked hold nothing attributable to one user.
	NotUserLinked []string
	// Unclassified is the failure case: a relation nobody has decided about.
	// Purge refuses while this is non-empty, because the only honest thing to
	// say about such a relation is that a deleted user's rows might survive
	// in it.
	Unclassified []string
}

// Classify sorts every relation in every non-system schema.
func Classify(ctx context.Context, pool *pgxpool.Pool) (Classification, error) {
	if pool == nil {
		return Classification{}, errors.New("purge: pool is nil")
	}
	scoped, err := UserScopedTables(ctx, pool)
	if err != nil {
		return Classification{}, err
	}
	all, err := allRelations(ctx, pool)
	if err != nil {
		return Classification{}, err
	}
	c := Classification{UserScoped: scoped}
	isScoped := make(map[string]bool, len(scoped))
	for _, r := range scoped {
		isScoped[r.String()] = true
	}
	for _, r := range all {
		name := r.String()
		switch {
		case isScoped[name]:
		case slices.Contains(handledWithoutUserID, name):
			c.HandledWithoutUserID = append(c.HandledWithoutUserID, name)
		case slices.Contains(notUserLinked, name):
			c.NotUserLinked = append(c.NotUserLinked, name)
		default:
			// The kind is named because it changes what the operator has to do:
			// a stray TABLE gets a user_id or a line in notUserLinked, while a
			// materialized VIEW usually wants dropping.
			c.Unclassified = append(c.Unclassified, name+" ("+r.KindName()+")")
		}
	}
	return c, nil
}

// cascadeActions maps a user-scoped relation to EVERY ON DELETE action of its
// foreign keys into users, as pg_constraint spells them: 'c' cascade, 'a' no
// action, 'r' restrict, 'n' set null, 'd' set default. A relation with a
// user_id column and no foreign key at all is absent from the map.
//
// It is a slice per relation, not one action, because a relation may carry more
// than one foreign key naming a user_id column (a composite key, or a second
// column also called user_id in a later revision). Keeping only the last row
// the scan happened to see would let a SET NULL hide behind a CASCADE — a
// silent hole in a check that exists to close a silent hole.
//
// The schema is no longer pinned to `public`: a relation in any schema may
// reference public.users.
func cascadeActions(ctx context.Context, pool *pgxpool.Pool) (map[string][]byte, error) {
	rows, err := pool.Query(ctx, `
		-- confdeltype is Postgres's internal "char" type, which pgx will not
		-- scan into a string; the cast is not cosmetic.
		SELECT ns.nspname, cl.relname, con.confdeltype::text
		  FROM pg_constraint con
		  JOIN pg_class cl ON cl.oid = con.conrelid
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		 WHERE con.contype = 'f'
		   AND con.confrelid = 'public.users'::regclass
		   AND EXISTS (
		       SELECT 1 FROM pg_attribute a
		        WHERE a.attrelid = con.conrelid
		          AND a.attnum = ANY (con.conkey)
		          AND a.attname = 'user_id')`)
	if err != nil {
		return nil, fmt.Errorf("purge: read foreign-key actions: %w", err)
	}
	defer rows.Close()
	out := map[string][]byte{}
	for rows.Next() {
		var schema, name, action string
		if err := rows.Scan(&schema, &name, &action); err != nil {
			return nil, fmt.Errorf("purge: read foreign-key actions: %w", err)
		}
		if action != "" {
			key := schema + "." + name
			out[key] = append(out[key], action[0])
		}
	}
	return out, rows.Err()
}

// deleteActionNames is for the error message; an operator reading "confdeltype
// n" learns nothing.
var deleteActionNames = map[byte]string{
	'a': "NO ACTION", 'r': "RESTRICT", 'c': "CASCADE", 'n': "SET NULL", 'd': "SET DEFAULT",
}

// CheckCascades refuses a purge whose schema cannot deliver one.
//
// Three shapes a later task can produce, and they fail differently:
//
//   - ON DELETE CASCADE — correct, and the only one accepted here.
//   - NO ACTION or RESTRICT — the DELETE FROM users errors with a foreign-key
//     violation. Loud, but mid-transaction and in the database's words rather
//     than ours, and it arrives AFTER the dictionary pseudonyms are already
//     forgotten. Caught here instead, before anything is touched.
//   - SET NULL or SET DEFAULT — the silent one, and the reason this check
//     exists at all. The rows SURVIVE with their user_id blanked, so every
//     count in this file goes to zero and the purge would report complete
//     success over a table that still holds the deleted user's data.
func CheckCascades(ctx context.Context, pool *pgxpool.Pool, rels []Relation) error {
	actions, err := cascadeActions(ctx, pool)
	if err != nil {
		return err
	}
	for _, r := range rels {
		for _, a := range actions[r.String()] {
			// No foreign key at all leaves the loop body unentered; it is
			// handled by the explicit sweep, which reports it. Cascade is the
			// correct case.
			if a == 'c' {
				continue
			}
			name, known := deleteActionNames[a]
			if !known {
				name = fmt.Sprintf("confdeltype %q", string(a))
			}
			return fmt.Errorf("%w: %s.user_id references users ON DELETE %s, not CASCADE — "+
				"deleting the account would %s", ErrIncomplete, r, name,
				map[bool]string{true: "leave the rows behind with a blanked user_id",
					false: "be refused by the foreign key"}[a == 'n' || a == 'd'])
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// The purge
// ---------------------------------------------------------------------------

// Purge deletes one account and everything that references it.
//
// It is idempotent: purging a user that does not exist reports zero rows and no
// error, so a client that lost the response to a successful deletion can retry
// without being told something went wrong.
//
// It is all-or-nothing: every row deletion happens in one transaction, and any
// failure — including "a table exists that this package cannot account for" —
// rolls the whole thing back. A partial purge is worse than none: it leaves a
// live account whose op log has holes in its gap-free seq, which is a corruption
// the invariant checker will report forever, in exchange for deleting some of
// the data the user asked to have deleted.

func Purge(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID) (Report, error) {
	return PurgeWith(ctx, pool, userID, Options{})
}

// Options are what the purging process holds beyond the database (spec 02
// §15.2, §15.4).
type Options struct {
	// Tagger computes email_tag under the server's auth key. serve has one;
	// the CLI and the console do not, and skip step 2 (the address's codes
	// that belong to no account) and step 3's tag clause on joined waitlist
	// entries. Those rows expire within 70 minutes and 30 days on their own.
	Tagger mailq.Tagger
	// Goodbye queues the `deleted` email to the account's address (step 4).
	// The API and `purge-user` set it; a purge replayed after a restore does
	// not.
	Goodbye bool
	// Now dates the goodbye; nil is time.Now.
	Now    func() time.Time
	Record func(users []uuid.UUID) error
	Cancel func(users []uuid.UUID) error
}

var ErrUnsettled = errors.New("purge: the commit failed and the ledger still names the accounts")

const commitWait = 30 * time.Second

// PurgeWith is Purge with the steps that need more than the database.
func PurgeWith(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, opts Options) (Report, error) {
	if pool == nil {
		return Report{}, errors.New("purge: pool is nil")
	}
	if userID == uuid.Nil {
		return Report{}, errors.New("purge: user id is zero")
	}
	return purgeUsers(ctx, pool, []uuid.UUID{userID}, opts)
}

func purgeUsers(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID, opts Options) (Report, error) {
	rep := newReport()
	if len(users) == 0 {
		return rep, nil
	}

	// Before anything is deleted: does this package know about every relation?
	c, err := Classify(ctx, pool)
	if err != nil {
		return rep, err
	}
	if len(c.Unclassified) != 0 {
		return rep, fmt.Errorf("%w: unclassified relations %v — give them a user_id column, "+
			"or classify them in internal/purge", ErrIncomplete, c.Unclassified)
	}

	// Second pre-flight, and still before anything is written: does every
	// discovered table's user_id foreign key actually CASCADE? A user_id column
	// is not the same as a column that goes away with its user, and the three
	// non-cascade shapes fail in three different ways — one of which is silent.
	// See cascadeActions.
	if err := CheckCascades(ctx, pool, c.UserScoped); err != nil {
		return rep, err
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return rep, fmt.Errorf("purge: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id = ANY($1) ORDER BY id FOR UPDATE`, users); err != nil {
		return rep, fmt.Errorf("purge: lock the accounts: %w", err)
	}

	// Counted BEFORE the delete, because after it there is nothing to count.
	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		rep.Rows[r.String()] = n
	}

	// The account's address also sits in rows that never carried its user_id
	// (spec 02 §15.2 steps 2 and 3, spec 07 §6.6, review 2 F-14): the signup
	// code and the invite were sent before the account existed, and another
	// account's notice may name it. The plaintext matches run for every
	// caller, the tag matches only where the auth key is held, and then the
	// goodbye is queued (step 4), all before the account row goes.
	if err := eraseAddress(ctx, tx, users, opts, &rep); err != nil {
		return rep, err
	}

	// The one statement that matters. Everything else cascades from it, which
	// is what satisfies the append-only triggers — see the package comment.
	//
	// RETURNING, so the report names the accounts that were actually deleted
	// rather than the ones that were asked for. Purging a user that no longer
	// exists is not an error — a client retrying after a lost response must not
	// be told something went wrong — and reporting it as a deletion would make
	// the retry indistinguishable from a second disaster.
	rows, err := tx.Query(ctx, `DELETE FROM users WHERE id = ANY($1) RETURNING id`, users)
	if err != nil {
		return rep, fmt.Errorf("purge: delete users: %w", err)
	}
	deleted, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return rep, fmt.Errorf("purge: delete users: %w", err)
	}

	// The sweep: everything the cascade did not reach.
	//
	// Two shapes get here. A TABLE with a user_id and no foreign key at all —
	// nothing cascades into it, so its rows are still present and are deleted
	// explicitly, with the schema defect reported rather than quietly covered
	// for. And a MATERIALIZED VIEW, which cannot be deleted from at all: it is
	// a stored copy of a query, so the only way to make the deleted user's rows
	// go away is to re-run the query now that the underlying rows are gone.
	// Both are then re-counted; a relation that is still not empty refuses the
	// whole purge.
	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if n == 0 {
			continue
		}
		if r.Kind == 'm' {
			// REFRESH takes an ACCESS EXCLUSIVE lock and is refused to a
			// non-owner, so this is where a matview a later task created
			// without thinking becomes a loud failure instead of a copy of a
			// deleted user's plaintext. That is the right direction: spec §5
			// contemplates exactly one such view, and whoever creates it owns
			// the obligation to let the purge reach it.
			if _, err := tx.Exec(ctx, `REFRESH MATERIALIZED VIEW `+r.SQL()); err != nil {
				return rep, fmt.Errorf("%w: materialized view %s holds %d rows for the purged "+
					"accounts and could not be refreshed (%v) — a matview is a stored COPY, so "+
					"the rows survive the cascade; drop it, or grant the purge role ownership",
					ErrIncomplete, r, n, err)
			}
			rep.RefreshedViews = append(rep.RefreshedViews, r.String())
		} else if _, err := tx.Exec(ctx,
			`DELETE FROM `+r.SQL()+` WHERE user_id = ANY($1)`, users); err != nil {
			return rep, fmt.Errorf("purge: sweep %s: %w", r, err)
		} else {
			rep.SweptWithoutCascade = append(rep.SweptWithoutCascade, r.String())
		}
		left, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if left != 0 {
			return rep, fmt.Errorf("%w: %s %s still holds %d rows after an explicit %s",
				ErrIncomplete, r.KindName(), r, left,
				map[bool]string{true: "refresh", false: "delete"}[r.Kind == 'm'])
		}
	}

	// The proof, inside the transaction that would otherwise commit. Every
	// discovered relation, re-counted against the same rows that were just
	// deleted. It cannot pass by omission: the list is the discovered one.
	for _, r := range c.UserScoped {
		n, err := countFor(ctx, tx, r, users)
		if err != nil {
			return rep, err
		}
		if n != 0 {
			return rep, fmt.Errorf("%w: %s %s still holds %d rows for the purged accounts",
				ErrIncomplete, r.KindName(), r, n)
		}
	}
	var left int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = ANY($1)`, users).Scan(&left); err != nil {
		return rep, fmt.Errorf("purge: verify users: %w", err)
	}
	if left != 0 {
		return rep, fmt.Errorf("%w: %d of the accounts survived their own deletion", ErrIncomplete, left)
	}

	if opts.Record != nil && len(deleted) > 0 {
		if err := opts.Record(deleted); err != nil {
			return rep, fmt.Errorf("purge: record the deletion: %w", err)
		}
	}

	commitCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitWait)
	defer cancel()
	if err := tx.Commit(commitCtx); err != nil {
		if opts.Record == nil || len(deleted) == 0 {
			return rep, fmt.Errorf("purge: commit: %w", err)
		}
		committed, serr := settleFailedCommit(ctx, pool, deleted, opts, err)
		if !committed {
			return rep, serr
		}
	}
	rep.Users = deleted
	return rep, nil
}

func settleFailedCommit(ctx context.Context, pool *pgxpool.Pool, deleted []uuid.UUID, opts Options, cause error) (bool, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitWait)
	defer cancel()
	rows, err := pool.Query(ctx, `SELECT id FROM users WHERE id = ANY($1) FOR UPDATE`, deleted)
	if err != nil {
		return false, fmt.Errorf("%w: commit: %v; read back: %v", ErrUnsettled, cause, err)
	}
	survived, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return false, fmt.Errorf("%w: commit: %v; read back: %v", ErrUnsettled, cause, err)
	}
	if len(survived) == 0 {
		return true, nil
	}
	if opts.Cancel == nil {
		return false, fmt.Errorf("%w: commit: %v", ErrUnsettled, cause)
	}
	if err := opts.Cancel(survived); err != nil {
		return false, fmt.Errorf("%w: commit: %v; cancel the line: %v", ErrUnsettled, cause, err)
	}
	return false, fmt.Errorf("purge: commit: %w", cause)
}

func Replay(ctx context.Context, pool *pgxpool.Pool, ids []uuid.UUID) (Report, error) {
	if pool == nil {
		return Report{}, errors.New("purge: pool is nil")
	}
	if len(ids) == 0 {
		return newReport(), nil
	}
	rows, err := pool.Query(ctx, `SELECT id FROM users WHERE id = ANY($1) ORDER BY id`, ids)
	if err != nil {
		return newReport(), fmt.Errorf("purge: replay: %w", err)
	}
	live, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return newReport(), fmt.Errorf("purge: replay: %w", err)
	}
	return purgeUsers(ctx, pool, live, Options{})
}

func countFor(ctx context.Context, tx pgx.Tx, r Relation, users []uuid.UUID) (int, error) {
	var n int
	err := tx.QueryRow(ctx,
		`SELECT count(*) FROM `+r.SQL()+` WHERE user_id = ANY($1)`, users).Scan(&n)
	if err != nil {
		// A relation the role cannot read reaches here rather than being
		// filtered out of discovery, which is the point of reading pg_class
		// instead of information_schema: "I am not allowed to look" is an
		// answer this package has to give out loud.
		return 0, fmt.Errorf("purge: count %s: %w", r, err)
	}
	return n, nil
}

// eraseAddress is spec 02 §15.2 steps 2 to 4 for the accounts being purged:
//   - step 2, with a Tagger: the email codes to the address that belong to no
//     account (a signup's, a reset's) are deleted by their tag;
//   - step 3: a queued mail_log row to the address is deleted, one being sent
//     is suppressed without it, a final one keeps only its hint and tag; the
//     account's joined waitlist entries go, found through the invite it
//     redeemed and, with a Tagger, by the address's tag; a signup or
//     email-change ceremony holding the address goes;
//   - step 4, with Goodbye: the `deleted` email is queued to the address, with
//     no account (the row must outlive it), and loses the address when its
//     send is final (mailq, O-17).
//
// It matches the account's current address only. An earlier address (before
// an email change) stays in final mail_log rows that never carried the
// account's id until the 30-day log sweep.
func eraseAddress(ctx context.Context, tx pgx.Tx, users []uuid.UUID, opts Options, rep *Report) error {
	type account struct {
		id   uuid.UUID
		addr string
		tag  []byte
	}
	rows, err := tx.Query(ctx, `SELECT id, email_norm FROM users WHERE id = ANY($1) AND email_norm IS NOT NULL ORDER BY id`, users)
	if err != nil {
		return fmt.Errorf("purge: read the address: %w", err)
	}
	accts, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (account, error) {
		var a account
		err := r.Scan(&a.id, &a.addr)
		return a, err
	})
	if err != nil {
		return fmt.Errorf("purge: read the address: %w", err)
	}
	var tags [][]byte
	if opts.Tagger != nil {
		for i := range accts {
			accts[i].tag = opts.Tagger.EmailTag(accts[i].addr)
			tags = append(tags, accts[i].tag)
		}
		tag, err := tx.Exec(ctx, `DELETE FROM email_codes WHERE user_id IS NULL AND email_tag = ANY($1::bytea[])`, tags)
		if err != nil {
			return fmt.Errorf("purge: delete the address's codes: %w", err)
		}
		rep.UnownedCodes = int(tag.RowsAffected())
		if _, err := tx.Exec(ctx,
			`DELETE FROM waitlist_entries WHERE state = 'joined' AND email_tag = ANY($1::bytea[])`, tags); err != nil {
			return fmt.Errorf("purge: erase the address: %w", err)
		}
	}
	const addrs = `(SELECT email_norm FROM users WHERE id = ANY($1) AND email_norm IS NOT NULL)`
	if _, err := tx.Exec(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = now(), email_tag = NULL, link_key_hash = NULL
		  WHERE state IN ('awaiting_testflight','queued','active')
		    AND ((email_tag IS NOT NULL AND email_tag = ANY($2::bytea[]))
		      OR id IN (SELECT invite_id FROM mail_log WHERE invite_id IS NOT NULL AND recipient IN `+addrs+`))`,
		users, tags); err != nil {
		return fmt.Errorf("purge: revoke the address's invites: %w", err)
	}
	for _, q := range []string{
		`DELETE FROM mail_log WHERE status = 'queued' AND recipient IN ` + addrs,
		`UPDATE mail_log SET status = 'suppressed', recipient = NULL, lease_until = NULL, final_at = now(), error = 'purged'
		  WHERE status = 'sending' AND recipient IN ` + addrs,
		`UPDATE mail_log SET recipient = NULL WHERE final_at IS NOT NULL AND recipient IN ` + addrs,
		`DELETE FROM waitlist_entries WHERE state = 'joined'
		    AND id IN (SELECT waitlist_entry_id FROM invite_codes WHERE redeemed_by = ANY($1))`,
		`DELETE FROM signup_ceremonies WHERE email_norm IN ` + addrs,
		`DELETE FROM email_change_ceremonies WHERE new_email_norm IN ` + addrs,
	} {
		if _, err := tx.Exec(ctx, q, users); err != nil {
			return fmt.Errorf("purge: erase the address: %w", err)
		}
	}
	if !opts.Goodbye {
		return nil
	}
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}
	q := mailq.New(nil, nil, opts.Tagger)
	for _, a := range accts {
		if _, err := q.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "deleted", Lane: mailq.LaneTransactional, To: a.addr,
			Tag: a.tag, Params: map[string]any{"deleted_at": now().UTC().Format(time.RFC3339Nano)}}); err != nil {
			return fmt.Errorf("purge: queue the goodbye: %w", err)
		}
		rep.Goodbyes++
	}
	return nil
}
