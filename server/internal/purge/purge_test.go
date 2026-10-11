package purge

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

// ---------------------------------------------------------------------------
// Seeding a user into EVERY table that references them
// ---------------------------------------------------------------------------
//
// The seeders below are keyed by table name and are looked up from the set
// UserScopedTables DISCOVERS, never from a list written here. A table added by
// a later change therefore fails seedAFullyPopulatedUser with "no seeder for
// user-scoped table X" long before it can fail silently in production, which is
// the whole point of discovering the set rather than enumerating it.
//
// They are raw INSERTs, run as the runtime role, rather than calls into
// auth/oplog: this file is a test ABOUT THE SCHEMA. Going through the packages
// would mean a table whose package has no writer yet quietly contributes no
// row, and the completeness proof would pass by never having populated it.

type seeder func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID)

// ensureWriter enrols the account's one device writer, device-1, under the
// key deviceKey returns; several seeders need it (op_log and apns_tokens
// reference writers).
func ensureWriter(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
	exec(t, pool, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	               VALUES ($1, 'ios-00000000-0000-4000-8000-000000000206', 'ed25519', $2, $3, now()) ON CONFLICT DO NOTHING`, u, devicePub(t, u), oplogtest.DAK(t))
}

// ensureSession gives the account one live session and returns its hash.
func ensureSession(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) []byte {
	var h []byte
	err := pool.QueryRow(bg, `SELECT token_hash FROM sessions WHERE user_id = $1 LIMIT 1`, u).Scan(&h)
	if err == nil {
		return h
	}
	h = randBytes(t, 32)
	exec(t, pool, `INSERT INTO sessions (token_hash, user_id, minted_by, created_at, last_used_at, expires_at)
	               VALUES ($2, $1, 'login', now(), now(), now() + interval '1 hour')`, u, h)
	return h
}

var seeders = map[string]seeder{
	"public.sessions": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) { ensureSession(t, pool, u) },
	"public.oplog_seq": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO oplog_seq (user_id, next_seq) VALUES ($1, 3)
		               ON CONFLICT (user_id) DO UPDATE SET next_seq = 3`, u)
	},
	// Two real sealed frames: the op_log CHECKs refuse anything else.
	"public.op_log": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		ensureWriter(t, pool, u)
		prev := blob.ZeroHash
		for c := int64(1); c <= 2; c++ {
			s := blobtest.MustSeal3(blob.Envelope{UserID: u, Stream: blob.StreamHot, WriterID: "ios-00000000-0000-4000-8000-000000000206", WriterCounter: c},
				prev, []byte(`{"v":4}`))
			h := blob.Hash(prev, s)
			exec(t, pool, `INSERT INTO op_log
			  (user_id, seq, stream, writer_id, writer_counter, type_flag, blob, size_bucket, blob_hash, prev_hash)
			  VALUES ($1, $2, 'hot', 'ios-00000000-0000-4000-8000-000000000206', $2, 'edit', $3, $4, $5, $6)`,
				u, c, s.Bytes, s.SizeBucket, h[:], prev[:])
			prev = h
		}
	},
	"public.writers": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) { ensureWriter(t, pool, u) },
	"public.key_history": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO key_history (user_id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, nonce, signature, at)
		               VALUES ($1, 'ios-00000000-0000-4000-8000-000000000206', 'ed25519', $2, $3, 'registered', 'authority', $4, $5, now())`,
			u, devicePub(t, u), oplogtest.DAK(t), randBytes(t, 32), randBytes(t, 64))
	},
	"public.writer_challenges": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO writer_challenges (nonce, user_id, issued_at, expires_at)
		               VALUES ($2, $1, now(), now() + interval '5 minutes')`, u, randBytes(t, 32))
	},
	"public.account_deletion_challenges": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO account_deletion_challenges (nonce, user_id, issued_at, expires_at)
		               VALUES ($2, $1, now(), now() + interval '5 minutes')`, u, randBytes(t, 32))
	},
	// An APNs token names the device writer and the session that registered
	// it, so revoking either silences it (spec 02 §9.3).
	"public.apns_tokens": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		ensureWriter(t, pool, u)
		session := ensureSession(t, pool, u)
		exec(t, pool, `INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		               VALUES ($1, 'ios-00000000-0000-4000-8000-000000000206', $2, $3, 'production', now(), now())`,
			u, session, hex.EncodeToString(randBytes(t, 32)))
	},
	// The Gmail mailbox link and its challenge (spec 02 §13.2).
	"public.mailbox_links": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		ensureWriter(t, pool, u)
		exec(t, pool, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
		               VALUES ($1, 'gmail', $2, $3, 'ios-00000000-0000-4000-8000-000000000206', now(), now())`,
			u, randBytes(t, 32), randBytes(t, 8))
	},
	"public.mailbox_link_challenges": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		session := ensureSession(t, pool, u)
		exec(t, pool, `INSERT INTO mailbox_link_challenges (nonce_hash, user_id, session_hash, issued_at, expires_at)
		               VALUES ($2, $1, $3, now(), now() + interval '15 minutes')`, u, randBytes(t, 32), session)
	},
	// Spec 07: an app bank request and an alert in the email log.
	"public.bank_requests": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO bank_requests (other_key, other_text, source, user_id, created_at)
		               VALUES ('some bank', 'Some Bank', 'app', $1, now())`, u)
	},
	"public.webauthn_credentials": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO webauthn_credentials
		  (credential_id, user_id, user_handle, public_key, sign_count, backup_eligible, backup_state, attestation_sha256, created_at)
		  VALUES ($2, $1, $3, $4, 1, true, true, $5, now())`,
			u, randBytes(t, 20), randBytes(t, 32), randBytes(t, 77), randBytes(t, 32))
	},
	// An 'add' ceremony, the only kind that names an account: a registration's
	// account does not exist yet and a discoverable login does not know whose
	// it is. Those carry a NULL user_id and correctly survive a purge.
	"public.webauthn_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO webauthn_ceremonies
		  (id, kind, user_id, user_handle, session_data, add_nonce, created_at, expires_at)
		  VALUES ($2, 'add', $1, $3, '{"challenge":"x"}'::jsonb, $4, now(), now() + interval '5 minutes')`,
			u, u.String()+"-ceremony", randBytes(t, 32), randBytes(t, 32))
	},
	// The account's wrapped key material: a blob that outlived its user would
	// be the one artefact capable of opening that user's data.
	"public.account_keys": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO account_keys
		  (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey, recovery_wrap, phrase_box,
		   current_epoch, created_at, updated_at)
		  VALUES ($1, 1, $2, $3, $4, $5, $6, 1, now(), now())`, u, randBytes(t, 32), randBytes(t, 32), randBytes(t, 32),
			append([]byte{1, 1}, randBytes(t, 125)...), append([]byte{1}, randBytes(t, 44)...))
	},
	"public.account_key_wraps": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		credential := randBytes(t, 20)
		exec(t, pool, `INSERT INTO webauthn_credentials
		  (credential_id, user_id, user_handle, public_key, sign_count, backup_eligible, backup_state, attestation_sha256, created_at)
		  VALUES ($2, $1, $3, $4, 1, true, true, $5, now())`,
			u, credential, randBytes(t, 32), randBytes(t, 77), randBytes(t, 32))
		exec(t, pool, `INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at)
		               VALUES ($1, $2, $3, 1, now())`, u, credential, append([]byte{1, 2}, randBytes(t, 125)...))
	},
	// A step-up challenge names the account and the session it was issued to.
	"public.step_up_challenges": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		session := ensureSession(t, pool, u)
		exec(t, pool, `INSERT INTO step_up_challenges (nonce, user_id, session_hash, action, params_hash, proof_kind, issued_at, expires_at)
		               VALUES ($2, $1, $3, 'passkey.delete', $4, 'passkey', now(), now() + interval '5 minutes')`,
			u, randBytes(t, 32), session, randBytes(t, 32))
	},
	// The per-account isolation tables: how many bytes a forgotten person
	// stored, the ceiling an operator set for one named account, and which
	// days that account was hitting walls. The DEFAULT limit row (user_id
	// NULL) is policy, not anyone's data, and must survive.
	"public.account_usage": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO account_usage (user_id, resource, amount) VALUES ($1, 'oplog_hot_bytes', 2048)
		               ON CONFLICT (user_id, resource) DO UPDATE SET amount = EXCLUDED.amount`, u)
	},
	"public.account_limits": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO account_limits (user_id, oplog_bytes) VALUES ($1, 1024)`, u)
	},
	"public.account_refusals": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO account_refusals (user_id, day, resource, count)
		               VALUES ($1, current_date, 'oplog_hot_bytes', 3)`, u)
	},
	// The account ceremonies (spec 02 §5.3). A signup ceremony carries the
	// reserved id with no foreign key (the account does not exist yet), so the
	// purge's explicit sweep is what erases its plaintext address.
	"public.signup_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name,
		                 email_proven, signup_nonce, claimed_at, created_at, expires_at)
		               VALUES ($2, $1, $3, $4, $5, 'Maya', true, $6, now(), now(), now() + interval '30 minutes')`,
			u, u.String()+"-signup", randBytes(t, 32), "s-"+u.String()+"@example.test", randBytes(t, 32), randBytes(t, 32))
	},
	"public.email_codes": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO email_codes (code_id, purpose, email_tag, user_id, ceremony_kind, ceremony_id, code_mac,
		                 sent, created_at, expires_at)
		               VALUES (gen_random_uuid(), 'email_verify', $2, $1, 'email_verify', $4, $3, true, now(), now() + interval '10 minutes')`,
			u, randBytes(t, 32), randBytes(t, 32), u.String())
	},
	"public.password_login_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO password_login_ceremonies (id, user_id, email_tag, nonce, created_at, expires_at)
		               VALUES ($2, $1, $3, $4, now(), now() + interval '5 minutes')`, u, u.String()+"-pl", randBytes(t, 32), randBytes(t, 32))
	},
	"public.recovery_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO recovery_ceremonies (id, user_id, recover_nonce, code_id, created_at, expires_at)
		               VALUES ($2, $1, $3, gen_random_uuid(), now(), now() + interval '10 minutes')`, u, u.String()+"-rc", randBytes(t, 32))
	},
	"public.password_reset_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO password_reset_ceremonies (id, user_id, email_tag, code_id, reset_nonce, created_at, expires_at)
		               VALUES ($2, $1, $3, gen_random_uuid(), $4, now(), now() + interval '10 minutes')`,
			u, u.String()+"-pr", randBytes(t, 32), randBytes(t, 32))
	},
	"public.email_change_ceremonies": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO email_change_ceremonies (id, user_id, new_email_norm, new_email_tag, new_in_use,
		                 change_nonce, code_old_id, code_new_id, created_at, expires_at)
		               VALUES (gen_random_uuid(), $1, $2, $3, false, $4, gen_random_uuid(), gen_random_uuid(), now(), now() + interval '10 minutes')`,
			u, "n-"+u.String()+"@example.test", randBytes(t, 32), randBytes(t, 32))
	},
	"public.freeze_tokens": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO freeze_tokens (token_hash, user_id, trigger_kind, trigger_at, created_at, expires_at)
		               VALUES ($2, $1, 'new_sign_in', now(), now(), now() + interval '7 days')`, u, randBytes(t, 32))
	},
	"public.auth_events": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO auth_events (user_id, kind, at, method) VALUES ($1, 'sign_in_new', now(), 'passkey')`, u)
	},
	"public.mail_log": func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO mail_log (kind, subkind, lane, recipient, recipient_tag, recipient_hint, user_id, params,
		                 status, next_attempt_at, created_at)
		               VALUES ('alert', 'new_passkey', 'transactional', $2, $3, 'm•••@example.test', $1, '{}', 'queued', now(), now())`,
			u, "a-"+u.String()+"@example.test", randBytes(t, 32))
	},
}

func newUser(t *testing.T, pool *pgxpool.Pool, sub string) uuid.UUID {
	t.Helper()
	sum := sha256.Sum256([]byte(sub + uuid.NewString()))
	var u uuid.UUID
	if err := pool.QueryRow(bg,
		`INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name) VALUES ($1, now(), 'u-' || gen_random_uuid() || '@example.test', now(), 'Test User') RETURNING id`,
		sum[:]).Scan(&u); err != nil {
		t.Fatalf("create user %q: %v", sub, err)
	}
	return u
}

// seedAFullyPopulatedUser puts at least one row for a fresh user in EVERY
// relation the schema says references them, and fails loudly if it cannot.
//
// A materialized view is skipped rather than seeded: nothing can INSERT into
// one. It is populated by whatever it selects from, which is what makes it a
// stored copy, and the matview tests below build their own.
func seedAFullyPopulatedUser(t *testing.T, pool *pgxpool.Pool, sub string) uuid.UUID {
	t.Helper()
	u := newUser(t, pool, sub)
	rels, err := UserScopedTables(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	var seeded []Relation
	for _, r := range rels {
		if r.Kind == 'm' {
			continue
		}
		seed, ok := seeders[r.String()]
		if !ok {
			t.Fatalf("no seeder for user-scoped %s %q: this test proves a purge empties "+
				"every relation that references a user, and it cannot prove it for one it "+
				"never populated. Add a seeder to purge_test.go's `seeders` map.", r.KindName(), r)
		}
		seed(t, pool, u)
		seeded = append(seeded, r)
	}
	for _, r := range seeded {
		if n := rowsFor(t, pool, r, u); n == 0 {
			t.Fatalf("seeder for %q left no row for the user", r)
		}
	}
	return u
}

func rowsFor(t *testing.T, pool *pgxpool.Pool, r Relation, u uuid.UUID) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM `+r.SQL()+` WHERE user_id = $1`, u).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", r, err)
	}
	return n
}

// rel is the Relation for a plain table in `public`, for the tests that name
// one directly.
func rel(name string) Relation { return Relation{Schema: "public", Name: name, Kind: 'r'} }

func exec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(bg, sql, args...); err != nil {
		t.Fatalf("%s: %v", firstLine(sql), err)
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

func randBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// deviceKey returns a stable Ed25519 keypair per user. It must be stable
// because writers and key_history are seeded separately and the pair has to
// look like one enrollment — and because a test that signs with it needs the
// private half of the key the roster holds.
var (
	keyMu   sync.Mutex
	devKeys = map[uuid.UUID]ed25519.PrivateKey{}
)

func deviceKey(t *testing.T, u uuid.UUID) ed25519.PrivateKey {
	t.Helper()
	keyMu.Lock()
	defer keyMu.Unlock()
	if k, ok := devKeys[u]; ok {
		return k
	}
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	devKeys[u] = priv
	return priv
}

func devicePub(t *testing.T, u uuid.UUID) []byte {
	t.Helper()
	return deviceKey(t, u).Public().(ed25519.PublicKey)
}

func countRows(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bg, sql, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", firstLine(sql), err)
	}
	return n
}

// ---------------------------------------------------------------------------
// Completeness
// ---------------------------------------------------------------------------

func TestPurgeLeavesNoRowInAnyUserScopedTable(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")

	rep, err := Purge(bg, pool, u)
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	rels, err := UserScopedTables(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	if len(rels) < 9 {
		t.Fatalf("expected to discover the user-scoped relations, found %v", rels)
	}
	for _, r := range rels {
		if n := rowsFor(t, pool, r, u); n != 0 {
			t.Fatalf("%s %s still holds %d rows for the purged user", r.KindName(), r, n)
		}
		if _, ok := rep.Rows[r.String()]; !ok {
			t.Fatalf("report does not account for %s: %+v", r, rep.Rows)
		}
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 0 {
		t.Fatal("the users row itself must be gone")
	}
	if !slices.Contains(rep.Users, u) {
		t.Fatalf("report does not name the purged user: %+v", rep.Users)
	}
	if rep.Total() == 0 {
		t.Fatal("the report counts no rows for a fully populated account")
	}
}

func TestPurgeTakesTheIsolationLedgerAndLeavesTheDefaultPolicy(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	bystander := seedAFullyPopulatedUser(t, pool, "leave-me")
	tables := []string{"account_usage", "account_limits", "account_refusals"}

	if _, err := Purge(bg, pool, u); err != nil {
		t.Fatalf("purge: %v", err)
	}
	for _, table := range tables {
		if n := rowsFor(t, pool, rel(table), u); n != 0 {
			t.Errorf("%s still holds %d rows for the purged account", table, n)
		}
		if n := rowsFor(t, pool, rel(table), bystander); n == 0 {
			t.Errorf("%s lost the OTHER account's rows", table)
		}
	}
	if n := countRows(t, pool, `SELECT count(*) FROM account_limits WHERE user_id IS NULL`); n != 1 {
		t.Fatalf("the default limit policy row count is %d, want 1", n)
	}
}

// Every table in the database is classified: user-scoped (discovered), handled
// without a user_id column, or deliberately not user-linked. A table added by a
// later change lands in none of those and fails here — and, by the same call
// inside Purge, refuses to purge at all rather than purging incompletely.
func TestEveryTableIsClassified(t *testing.T) {
	pool := pgtest.New(t)
	c, err := Classify(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Unclassified) != 0 {
		t.Fatalf("unclassified tables %v: a table this purge does not know about is a table "+
			"a deleted user's rows can survive in. Either give it a user_id column (it is then "+
			"discovered automatically), or add it to purge.go's handledWithoutUserID / "+
			"notUserLinked with the reason.", c.Unclassified)
	}
	for _, want := range []string{
		"public.op_log", "public.key_history", "public.writers", "public.sessions",
		"public.apns_tokens", "public.account_keys", "public.account_key_wraps", "public.step_up_challenges",
	} {
		if !slices.ContainsFunc(c.UserScoped, func(r Relation) bool { return r.String() == want }) {
			t.Fatalf("%s is not classified as user-scoped: %+v", want, c)
		}
	}
	for _, want := range []string{"public.invite_codes", "public.deleted_account_sessions", "public.goose_db_version"} {
		if !slices.Contains(c.NotUserLinked, want) {
			t.Fatalf("%s is not classified as not-user-linked: %+v", want, c)
		}
	}
}

// What the cascade pre-flight read for the append-only tables and the push
// tokens is ON DELETE CASCADE, so `DELETE FROM users` really does take them:
// the runtime role cannot DELETE from op_log, key_history or writers at all.
func TestTheCascadeCheckCoversTheLogAndItsKeys(t *testing.T) {
	pool := pgtest.New(t)
	actions, err := cascadeActions(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{"public.op_log", "public.key_history", "public.writers", "public.apns_tokens"}
	for _, name := range names {
		got, ok := actions[name]
		if !ok {
			t.Fatalf("%s has no user_id foreign key to users at all", name)
		}
		for _, a := range got {
			if a != 'c' {
				t.Fatalf("%s.user_id references users ON DELETE %s, not CASCADE", name, deleteActionNames[a])
			}
		}
	}
	if err := checkCascades(bg, pool, []Relation{rel("op_log"), rel("key_history"), rel("writers"), rel("apns_tokens")}); err != nil {
		t.Fatalf("checkCascades: %v", err)
	}
}

func TestPurgeRefusesWhenATableIsUnclassified(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	// A later change's table, with no user_id and no classification.
	exec(t, owner, `CREATE TABLE later_task_notes (id bigserial PRIMARY KEY, note text)`)

	_, err := Purge(bg, pool, u)
	if err == nil {
		t.Fatal("purge succeeded with an unclassified table present")
	}
	if !strings.Contains(err.Error(), "later_task_notes") {
		t.Fatalf("error does not name the unclassified table: %v", err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("a refused purge must leave the account intact, not half-deleted")
	}
}

// ---------------------------------------------------------------------------
// The object classes information_schema could not see
// ---------------------------------------------------------------------------
//
// Discovery reads pg_class, not information_schema, which is blind to a
// materialized view, to any other schema, and to anything the current role
// lacks privileges on. In each case the relation must be purged or the purge
// must refuse, never be skipped. See relationFilter in purge.go.

// A matview over op_log is a stored COPY of the user's frames; it survives the
// cascade and cannot be DELETEd from. Refreshing it needs ownership, so the
// runtime role's purge refuses (loudly, naming it) and the owner's reaches it.
func TestPurgeReachesAMaterializedViewOnlyAsItsOwner(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	bystander := seedAFullyPopulatedUser(t, pool, "leave-me")
	exec(t, owner, `CREATE MATERIALIZED VIEW user_blob_archive AS SELECT user_id, seq, blob FROM op_log`)

	mv := Relation{Schema: "public", Name: "user_blob_archive", Kind: 'm'}
	if n := rowsFor(t, pool, mv, u); n == 0 {
		t.Fatal("precondition: the matview holds none of the user's rows")
	}
	rels, err := UserScopedTables(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(rels, func(r Relation) bool { return r.String() == mv.String() }) {
		t.Fatalf("discovery did not find the materialized view: %v", rels)
	}

	if _, err := Purge(bg, pool, u); err == nil || !strings.Contains(err.Error(), "user_blob_archive") {
		t.Fatalf("the runtime role's purge did not refuse over a view it cannot refresh: %v", err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("a refused purge must leave the account intact")
	}

	rep, err := Purge(bg, owner, u)
	if err != nil {
		t.Fatalf("purge as the owner: %v", err)
	}
	if n := rowsFor(t, pool, mv, u); n != 0 {
		t.Fatalf("the materialized view still holds %d rows of the purged user", n)
	}
	if !slices.Contains(rep.RefreshedViews, mv.String()) {
		t.Fatalf("report does not name the refreshed view: %+v", rep.RefreshedViews)
	}
	if n := rowsFor(t, pool, mv, bystander); n == 0 {
		t.Fatal("the refresh dropped the bystander's rows too")
	}
}

// A matview with no user_id is still a relation nobody has classified.
func TestPurgeRefusesAnUnclassifiedMaterializedView(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	exec(t, owner, `CREATE MATERIALIZED VIEW writer_counts AS SELECT writer_id, count(*) AS n FROM op_log GROUP BY writer_id`)

	_, err := Purge(bg, pool, u)
	if err == nil {
		t.Fatal("purge succeeded with an unclassified materialized view present")
	}
	if !strings.Contains(err.Error(), "writer_counts") || !strings.Contains(err.Error(), "materialized view") {
		t.Fatalf("error does not name the view and its kind: %v", err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("a refused purge must leave the account intact")
	}
}

// `archive.op_log_2026` — the obvious thing a DBA creates, in the obvious place
// a `WHERE table_schema = 'public'` filter cannot see.
func TestPurgeReachesATableOutsideThePublicSchema(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	exec(t, owner, `CREATE SCHEMA archive`)
	exec(t, owner, `CREATE TABLE archive.op_log_2026 (id bigserial PRIMARY KEY, user_id uuid NOT NULL, blob bytea NOT NULL)`)
	exec(t, owner, `GRANT USAGE ON SCHEMA archive TO hasala_runtime`)
	exec(t, owner, `GRANT SELECT, INSERT, DELETE ON archive.op_log_2026 TO hasala_runtime`)
	exec(t, owner, `GRANT USAGE ON ALL SEQUENCES IN SCHEMA archive TO hasala_runtime`)
	seeders["archive.op_log_2026"] = func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO archive.op_log_2026 (user_id, blob) VALUES ($1, $2)`, u, []byte("archived"))
	}
	t.Cleanup(func() { delete(seeders, "archive.op_log_2026") })

	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	archived := Relation{Schema: "archive", Name: "op_log_2026", Kind: 'r'}
	rep, err := Purge(bg, pool, u)
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	if n := rowsFor(t, pool, archived, u); n != 0 {
		t.Fatalf("archive.op_log_2026 still holds %d rows of the purged user", n)
	}
	if !slices.Contains(rep.SweptWithoutCascade, "archive.op_log_2026") {
		t.Fatalf("report does not flag the out-of-schema table: %+v", rep.SweptWithoutCascade)
	}
	if _, ok := rep.Rows["archive.op_log_2026"]; !ok {
		t.Fatalf("report keys are not schema-qualified: %+v", rep.Rows)
	}
}

// information_schema shows only what the current role has privileges on, and
// the purge runs as the non-owner hasala_runtime. A relation that role cannot
// read must be DISCOVERED, and the count against it must fail loudly.
func TestPurgeSeesARelationTheRoleCannotRead(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	exec(t, owner, `CREATE TABLE hidden_user_notes (
	                 id bigserial PRIMARY KEY,
	                 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	                 note text NOT NULL)`)
	exec(t, owner, `INSERT INTO hidden_user_notes (user_id, note) VALUES ($1, 'x')`, u)
	exec(t, owner, `REVOKE ALL ON hidden_user_notes FROM hasala_runtime`)

	rels, err := UserScopedTables(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(rels, func(r Relation) bool { return r.String() == "public.hidden_user_notes" }) {
		t.Fatalf("the runtime role's discovery cannot see a relation it lacks privileges on: %v", rels)
	}
	_, err = Purge(bg, pool, u)
	if err == nil {
		t.Fatal("purge succeeded as a role that cannot read one of the user's tables")
	}
	if !strings.Contains(err.Error(), "hidden_user_notes") {
		t.Fatalf("error does not name the unreadable relation: %v", err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("a refused purge must leave the account intact")
	}
}

// A user_id column with no foreign key at all: nothing cascades into it. The
// sweep catches it, and says so in the report.
func TestPurgeSweepsAUserScopedTableWithNoForeignKey(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	exec(t, owner, `CREATE TABLE later_task_rows (id bigserial PRIMARY KEY, user_id uuid NOT NULL, note text NOT NULL)`)
	seeders["public.later_task_rows"] = func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
		exec(t, pool, `INSERT INTO later_task_rows (user_id, note) VALUES ($1, 'x')`, u)
	}
	t.Cleanup(func() { delete(seeders, "public.later_task_rows") })

	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	rep, err := Purge(bg, pool, u)
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	if n := rowsFor(t, pool, rel("later_task_rows"), u); n != 0 {
		t.Fatalf("later_task_rows still holds %d rows", n)
	}
	if !slices.Contains(rep.SweptWithoutCascade, "public.later_task_rows") {
		t.Fatalf("report does not flag the missing cascade: %+v", rep.SweptWithoutCascade)
	}
}

// The other shapes of a user_id foreign key that is not ON DELETE CASCADE. SET
// NULL is the dangerous one: the rows survive with a blanked user_id, so every
// count-by-user_id here reads zero. All are refused BEFORE anything is touched.
func TestPurgeRefusesAUserIDForeignKeyThatDoesNotCascade(t *testing.T) {
	for _, tc := range []struct{ name, action, wants string }{
		{name: "set null", action: "ON DELETE SET NULL", wants: "SET NULL"},
		{name: "no action", action: "", wants: "NO ACTION"},
		{name: "restrict", action: "ON DELETE RESTRICT", wants: "RESTRICT"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pool, owner := pgtest.NewWithOwner(t)
			exec(t, owner, `CREATE TABLE later_task_rows (
			                 id bigserial PRIMARY KEY,
			                 user_id uuid REFERENCES users(id) `+tc.action+`,
			                 note text NOT NULL)`)
			seeders["public.later_task_rows"] = func(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) {
				exec(t, pool, `INSERT INTO later_task_rows (user_id, note) VALUES ($1, 'x')`, u)
			}
			t.Cleanup(func() { delete(seeders, "public.later_task_rows") })

			u := seedAFullyPopulatedUser(t, pool, "purge-me")
			_, err := Purge(bg, pool, u)
			if err == nil {
				t.Fatal("purge succeeded against a foreign key that does not cascade")
			}
			if !errors.Is(err, ErrIncomplete) {
				t.Fatalf("error is not ErrIncomplete: %v", err)
			}
			if !strings.Contains(err.Error(), "later_task_rows") || !strings.Contains(err.Error(), tc.wants) {
				t.Fatalf("error does not name the table and its action: %v", err)
			}
			if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
				t.Fatal("a refused purge must leave the account intact")
			}
		})
	}
}

func TestPurgeDoesNotTouchOtherUsers(t *testing.T) {
	pool := pgtest.New(t)
	victim := seedAFullyPopulatedUser(t, pool, "purge-me")
	bystander := seedAFullyPopulatedUser(t, pool, "leave-me")

	if _, err := Purge(bg, pool, victim); err != nil {
		t.Fatalf("purge: %v", err)
	}
	rels, err := UserScopedTables(bg, pool)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rels {
		if n := rowsFor(t, pool, r, bystander); n == 0 {
			t.Fatalf("%s lost the bystander's rows", r)
		}
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, bystander); n != 1 {
		t.Fatal("the bystander's account is gone")
	}
}

// op_log and key_history are append-only and writers revoke-once: the runtime
// role holds no DELETE on them and the triggers refuse even the owner while
// the account exists. The purge therefore has to arrive through the cascade.
func TestPurgeSatisfiesTheAppendOnlyTriggers(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	for _, table := range []string{"op_log", "key_history", "writers"} {
		if _, err := pool.Exec(bg, `DELETE FROM `+table+` WHERE user_id = $1`, u); err == nil {
			t.Fatalf("precondition: the runtime role deleted from %s", table)
		}
		if _, err := owner.Exec(bg, `DELETE FROM `+table+` WHERE user_id = $1`, u); err == nil {
			t.Fatalf("precondition: %s let the owner delete a live account's rows", table)
		}
	}
	if _, err := Purge(bg, pool, u); err != nil {
		t.Fatalf("purge: %v", err)
	}
	for _, table := range []string{"op_log", "key_history", "writers"} {
		if n := rowsFor(t, pool, rel(table), u); n != 0 {
			t.Fatalf("%s still holds %d rows", table, n)
		}
	}
}

func TestPurgeIsIdempotentAndReportsAnUnknownUserAsNothingToDo(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "purge-me")
	if _, err := Purge(bg, pool, u); err != nil {
		t.Fatalf("first purge: %v", err)
	}
	rep, err := Purge(bg, pool, u)
	if err != nil {
		t.Fatalf("second purge: %v", err)
	}
	if len(rep.Users) != 0 {
		t.Fatalf("second purge claims to have deleted %v", rep.Users)
	}
}

// ---------------------------------------------------------------------------
// The deletion challenge (spec §3.4's key-possession factor)
// ---------------------------------------------------------------------------

func TestChallengeAuthorizesOnlyAnEnrolledLiveKey(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "delete-me")
	c := &Challenges{Pool: pool}

	// The seeded roster key: writers + key_history share it.
	priv := deviceKey(t, u)

	nonce, err := c.Issue(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, DeletionMessage(nonce, u))
	if err := c.Authorize(bg, u, nonce, sig); err != nil {
		t.Fatalf("authorize with an enrolled key: %v", err)
	}

	// Replay: the nonce is single use.
	if err := c.Authorize(bg, u, nonce, sig); !errors.Is(err, ErrDeletionRejected) {
		t.Fatalf("replay = %v, want ErrDeletionRejected", err)
	}
}

func TestChallengeRefusesAnUnenrolledKey(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "delete-me")
	c := &Challenges{Pool: pool}

	_, stranger, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	nonce, err := c.Issue(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(stranger, DeletionMessage(nonce, u))
	if err := c.Authorize(bg, u, nonce, sig); !errors.Is(err, ErrDeletionRejected) {
		t.Fatalf("authorize with an unenrolled key = %v, want ErrDeletionRejected", err)
	}
}

func TestChallengeRefusesARevokedKey(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "delete-me")
	exec(t, pool, `UPDATE writers SET revoked_at = now() WHERE user_id = $1`, u)
	c := &Challenges{Pool: pool}

	priv := deviceKey(t, u)
	nonce, err := c.Issue(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, DeletionMessage(nonce, u))
	if err := c.Authorize(bg, u, nonce, sig); !errors.Is(err, ErrDeletionRejected) {
		t.Fatalf("authorize with a revoked key = %v, want ErrDeletionRejected", err)
	}
}

func TestChallengeRefusesAnotherAccountsNonce(t *testing.T) {
	pool := pgtest.New(t)
	mine := seedAFullyPopulatedUser(t, pool, "mine")
	theirs := seedAFullyPopulatedUser(t, pool, "theirs")
	c := &Challenges{Pool: pool}

	nonce, err := c.Issue(bg, theirs)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(deviceKey(t, mine), DeletionMessage(nonce, mine))
	if err := c.Authorize(bg, mine, nonce, sig); !errors.Is(err, ErrDeletionRejected) {
		t.Fatalf("authorize with another account's nonce = %v, want ErrDeletionRejected", err)
	}
}

func TestChallengeRefusesAnExpiredNonce(t *testing.T) {
	pool := pgtest.New(t)
	u := seedAFullyPopulatedUser(t, pool, "delete-me")
	now := time.Now()
	c := &Challenges{Pool: pool, Now: func() time.Time { return now }}

	nonce, err := c.Issue(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	c.Now = func() time.Time { return now.Add(ChallengeTTL + time.Second) }
	sig := ed25519.Sign(deviceKey(t, u), DeletionMessage(nonce, u))
	if err := c.Authorize(bg, u, nonce, sig); !errors.Is(err, ErrDeletionRejected) {
		t.Fatalf("authorize with an expired nonce = %v, want ErrDeletionRejected", err)
	}
}

// A signature made for a writer registration must not delete the account
// (spec 01 D16). Two independent rails: the nonce comes from a different
// table, and the message carries its own domain prefix.
func TestDeletionMessageIsDomainSeparated(t *testing.T) {
	u := uuid.New()
	nonce := make([]byte, ChallengeNonceBytes)
	msg := DeletionMessage(nonce, u)
	if !strings.HasPrefix(string(msg), "ledger/v2 account-delete\x00") {
		t.Fatalf("DeletionMessage has no domain prefix: %q", msg[:32])
	}
	other := DeletionMessage(nonce, uuid.New())
	if string(msg) == string(other) {
		t.Fatal("DeletionMessage does not bind the user id")
	}
}

// Spec 02 §15.2 step 3, AT-DEL-2 (review 2 F-14), spec 07 §6.6: the purge
// erases the account's address from email-log rows that never carried its
// user_id, deletes its joined waitlist entry and any signup ceremony holding
// the address, and leaves other addresses alone.
func TestPurgeErasesTheAddressFromTheEmailLog(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "erase-address")
	exec(t, pool, `UPDATE users SET email_norm = 'gone@example.com' WHERE id = $1`, u)
	tag := randBytes(t, 32)
	exec(t, pool, `INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, params, status, next_attempt_at, created_at)
	               VALUES ('test', 'transactional', 'gone@example.com', $1, 'g•••@example.com', '{}', 'queued', now(), now())`, tag)
	exec(t, pool, `INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, params, status, lease_until, created_at)
	               VALUES ('code', 'transactional', 'gone@example.com', $1, 'g•••@example.com', '{}', 'sending', now() + interval '1 minute', now())`, tag)
	exec(t, pool, `INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, params, status, sent_at, final_at, created_at)
	               VALUES ('code', 'transactional', 'gone@example.com', $1, 'g•••@example.com', '{}', 'sent', now(), now(), now())`, tag)
	exec(t, pool, `INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, params, status, sent_at, final_at, created_at)
	               VALUES ('test', 'transactional', 'stays@example.com', $1, 's•••@example.com', '{}', 'sent', now(), now(), now())`, randBytes(t, 32))
	var entry uuid.UUID
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, state, source, created_at, updated_at, confirmed_at,
	    invited_at, joined_at) VALUES ($1, 'joined', 'web', now(), now(), now(), now(), now()) RETURNING id`, tag).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	exec(t, pool, `INSERT INTO invite_codes (code_hash, waitlist_entry_id, origin, state, created_at, minted_at, expires_at,
	               mint_count, redeemed_at, redeemed_by, closed_at)
	               VALUES ($1, $2, 'cli', 'redeemed', now(), now(), now() + interval '1 day', 1, now(), $3, now())`,
		randBytes(t, 32), entry, u)
	exec(t, pool, `INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name, email_proven,
	               signup_nonce, created_at, expires_at)
	               VALUES ('another-signup', gen_random_uuid(), $1, 'gone@example.com', $2, 'Someone', true, $3, now(), now() + interval '10 minutes')`,
		randBytes(t, 32), tag, randBytes(t, 32))

	if _, err := Purge(bg, pool, u); err != nil {
		t.Fatal(err)
	}
	var withAddr, rows, suppressed, entries, signups int
	if err := pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE recipient = 'gone@example.com'), count(*),
	    count(*) FILTER (WHERE status = 'suppressed' AND recipient IS NULL AND error = 'purged') FROM mail_log`).
		Scan(&withAddr, &rows, &suppressed); err != nil {
		t.Fatal(err)
	}
	_ = pool.QueryRow(bg, `SELECT count(*) FROM waitlist_entries`).Scan(&entries)
	_ = pool.QueryRow(bg, `SELECT count(*) FROM signup_ceremonies`).Scan(&signups)
	if withAddr != 0 || rows != 3 || suppressed != 1 || entries != 0 || signups != 0 {
		t.Fatalf("after the purge: %d rows with the address, %d rows, %d suppressed, %d entries, %d signups",
			withAddr, rows, suppressed, entries, signups)
	}
}
