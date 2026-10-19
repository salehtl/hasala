package pg_test

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pg"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

func mustExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(bg, sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

// sqlState returns the SQLSTATE and constraint name of a Postgres error.
func sqlState(err error) (code, constraint string) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code, pgErr.ConstraintName
	}
	return "", ""
}

func wantsError(t *testing.T, pool *pgxpool.Pool, what, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(bg, sql, args...); err == nil {
		t.Fatalf("%s was accepted", what)
	}
}

// ---------------------------------------------------------------------------
// The baseline
// ---------------------------------------------------------------------------

// TestTheBaselineHoldsExactlyTheKeptTables is the surgery's schema pin (spec 02
// §2.5): the retired tables are absent, and nothing appears that nobody
// classified.
func TestTheBaselineHoldsExactlyTheKeptTables(t *testing.T) {
	pool := pgtest.New(t)
	rows, err := pool.Query(bg, `SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename`)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		got = append(got, n)
	}
	want := []string{
		"account_key_wraps", "account_keys", "account_limits", "account_refusals",
		"account_usage", "admin_audit", "apns_tokens", "auth_events", "bank_requests", "banks",
		"deleted_account_sessions", "device_freeze_challenges", "email_change_ceremonies", "email_code_pauses",
		"email_codes", "freeze_tokens", "goose_db_version", "invite_codes", "key_history", "mail_log",
		"mailbox_link_challenges", "mailbox_links", "op_log", "oplog_seq", "password_login_ceremonies",
		"password_reset_ceremonies", "rate_counters", "recovery_ceremonies", "server_meta", "sessions",
		"signup_ceremonies", "step_up_challenges", "users", "waitlist_entries", "waitlist_tokens",
		"webauthn_ceremonies", "webauthn_credentials", "writer_challenges", "writers",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("public tables are %v, want %v", got, want)
	}
}

// schemaShape lists every column (type, nullability, default), constraint,
// index, trigger and function of the public schema, sorted, so two databases
// can be compared object by object.
func schemaShape(t *testing.T, pool *pgxpool.Pool) []string {
	t.Helper()
	rows, err := pool.Query(bg, `
		SELECT 'column ' || table_name || '.' || column_name || ' ' || data_type || ' null=' || is_nullable
		       || ' default=' || coalesce(column_default, '')
		  FROM information_schema.columns WHERE table_schema = 'public'
		UNION ALL
		SELECT 'constraint ' || conrelid::regclass::text || '.' || conname || ' ' || pg_get_constraintdef(oid)
		  FROM pg_constraint WHERE connamespace = 'public'::regnamespace
		UNION ALL
		SELECT 'index ' || indexdef FROM pg_indexes WHERE schemaname = 'public'
		UNION ALL
		SELECT 'trigger ' || tgrelid::regclass::text || '.' || tgname FROM pg_trigger
		 WHERE NOT tgisinternal AND tgrelid::regclass::text NOT LIKE 'pg_%'
		UNION ALL
		SELECT 'function ' || proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace
		ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// 00022's Down is pgtest-only, but it must give back exactly what 00021 left,
// or a Down to 21 followed by work at 21 tests a schema no deploy ever had.
func TestDownTo21IsWhat00021Left(t *testing.T) { downIsWhatUpLeft(t, 21) }

// 00023's Down is pgtest-only too, and gives back exactly what 00022 left.
func TestDownTo22IsWhat00022Left(t *testing.T) { downIsWhatUpLeft(t, 22) }

func TestDownTo23IsWhat00023Left(t *testing.T) { downIsWhatUpLeft(t, 23) }

// downIsWhatUpLeft compares a database migrated up to version with one
// migrated all the way up and then down to version.
func downIsWhatUpLeft(t *testing.T, version int64) {
	t.Helper()
	open := func() *pgxpool.Pool {
		t.Helper()
		dsn, _ := pgtest.NewEmpty(t)
		p, err := pg.Open(bg, dsn)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(p.Close)
		return p
	}
	up, down := open(), open()
	if err := pg.MigrateTo(bg, up, version); err != nil {
		t.Fatalf("up to %d: %v", version, err)
	}
	if err := pg.Migrate(bg, down); err != nil {
		t.Fatalf("up: %v", err)
	}
	if err := pg.MigrateDownTo(bg, down, version); err != nil {
		t.Fatalf("down to %d: %v", version, err)
	}
	want, got := schemaShape(t, up), schemaShape(t, down)
	for _, s := range want {
		if !slices.Contains(got, s) {
			t.Errorf("after the Down to %d, missing: %s", version, s)
		}
	}
	for _, s := range got {
		if !slices.Contains(want, s) {
			t.Errorf("after the Down to %d, extra: %s", version, s)
		}
	}
}

func TestEachTestGetsAnIsolatedDatabase(t *testing.T) {
	a, b := pgtest.New(t), pgtest.New(t)
	oplogtest.NewUser(t, a)
	var n int
	if err := b.QueryRow(bg, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("databases are not isolated: second pool sees %d users", n)
	}
}

func TestTheBaselineRefusesToRunAsAnyoneButTheSchemaOwner(t *testing.T) {
	_, owner := pgtest.NewWithOwner(t)
	su := pgtest.Superuser(t, owner)
	if err := pg.MigrateDown(bg, owner); err != nil {
		t.Fatalf("down: %v", err)
	}
	// As the superuser, the baseline's own guard refuses.
	err := pg.Migrate(bg, su)
	if err == nil || !strings.Contains(err.Error(), "must be applied as hasala_migrate") {
		t.Fatalf("the baseline ran as a superuser: %v", err)
	}
	if err := pg.Migrate(bg, owner); err != nil {
		t.Fatalf("re-up as the owner: %v", err)
	}
}

func TestMigrationsAreReversible(t *testing.T) {
	_, owner := pgtest.NewWithOwner(t)
	if err := pg.MigrateDown(bg, owner); err != nil {
		t.Fatalf("down: %v", err)
	}
	var n int
	if err := owner.QueryRow(bg, `SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'goose_db_version'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("Down left %d tables behind", n)
	}
	if err := pg.Migrate(bg, owner); err != nil {
		t.Fatalf("re-up: %v", err)
	}
}

// TestTheSealedPredicateIsTheSpecsByteForByte pins hasala_frame_is_sealed: the
// md5 of its body as installed equals the constant serve compares at startup
// (O7) and spec 01 §8.2's V-F value, and the migration file carries the body
// verbatim (AT-IDX-4).
func TestTheSealedPredicateIsTheSpecsByteForByte(t *testing.T) {
	pool := pgtest.New(t)
	var sum string
	if err := pool.QueryRow(bg, `SELECT md5(prosrc) FROM pg_proc
		WHERE proname = 'hasala_frame_is_sealed' AND pronamespace = 'public'::regnamespace`).Scan(&sum); err != nil {
		t.Fatal(err)
	}
	if pg.SealedFunctionMD5 != "cecad4a55664c960ee9e1e301a76c30d" {
		t.Fatalf("pg.SealedFunctionMD5 = %s, want spec 01 §8.2's value", pg.SealedFunctionMD5)
	}
	if sum != pg.SealedFunctionMD5 {
		t.Fatalf("md5(prosrc) = %s, want spec 01 §8.2's cecad4a55664c960ee9e1e301a76c30d", sum)
	}
	raw, err := os.ReadFile("migrations/00001_baseline.sql")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)AS \$fn\$(.*?)\$fn\$`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("the baseline has no $fn$ body")
	}
	if got := md5.Sum(m[1]); hex.EncodeToString(got[:]) != pg.SealedFunctionMD5 {
		t.Fatalf("the migration file's body hashes to %x, not the pinned constant", got)
	}
}

// TestTheSQLPredicateAgreesWithLooksSealed is spec 01 AT-P1 for the database:
// every case of the V-F set, accepted or refused, the same way by Go and SQL.
// A NULL is NULL (N-02: only NOT NULL refuses it).
func TestTheSQLPredicateAgreesWithLooksSealed(t *testing.T) {
	pool := pgtest.New(t)
	for _, c := range blobtest.LooksSealedCases() {
		var ok bool
		if err := pool.QueryRow(bg, `SELECT hasala_frame_is_sealed($1)`, c.Frame).Scan(&ok); err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		goOK := blob.LooksSealed(c.Frame) == nil
		if ok != goOK || ok != (c.Want == "") {
			t.Errorf("%s: SQL %v, Go %v, want %q", c.Name, ok, goOK, c.Want)
		}
	}
	var null *bool
	if err := pool.QueryRow(bg, `SELECT hasala_frame_is_sealed(NULL)`).Scan(&null); err != nil {
		t.Fatal(err)
	}
	if null != nil {
		t.Fatalf("hasala_frame_is_sealed(NULL) = %v, want NULL", *null)
	}
}

// TestADirectInsertOfARefusedFrameFailsTheCheck is AT-P3 and AT-DB-1: no
// write path, the application's or a hand-written INSERT, stores a frame the
// predicate refuses, and the constraint that refuses it is
// op_log_blob_is_sealed by name.
//
// PostgreSQL evaluates CHECK constraints in name order, so
// op_log_aad_matches_position runs first: a refused frame carrying someone
// else's AAD would be caught there and prove nothing about the sealed CHECK.
// Every named-constraint case below is therefore a real frame sealed for the
// very row it is inserted as, with exactly one predicate check broken and the
// AAD bytes left untouched.
func TestADirectInsertOfARefusedFrameFailsTheCheck(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	oplogtest.NewWriter(t, pool, u, "ios-00000000-0000-4000-8000-00000000000a")
	insert := func(frame []byte, size int) error {
		_, err := pool.Exec(bg, `INSERT INTO op_log (user_id, seq, stream, writer_id, writer_counter, type_flag,
			blob, size_bucket, blob_hash, prev_hash) VALUES ($1, 1, 'hot', 'ios-00000000-0000-4000-8000-00000000000a', 1, 'edit', $2, $3, $4, $4)`,
			u, frame, size, make([]byte, 32))
		return err
	}
	here := blob.Envelope{UserID: u, Stream: blob.StreamHot, WriterID: "ios-00000000-0000-4000-8000-00000000000a", WriterCounter: 1}
	aad := here.AAD()
	l := len(aad)
	positioned := func(mutate func(f []byte)) []byte {
		f := blobtest.MustSeal3(here, blob.ZeroHash, []byte(`{}`)).Bytes
		mutate(f)
		return f
	}
	zero := func(from, to int) func(f []byte) {
		return func(f []byte) {
			for i := from; i < to; i++ {
				f[i] = 0
			}
		}
	}
	type sealedCase struct {
		name, check string
		mutate      func(f []byte)
	}
	var cases []sealedCase
	for _, v := range []byte{0x00, 0x01, 0x02, 0x04, 0xff} {
		cases = append(cases, sealedCase{fmt.Sprintf("version %#02x", v), blob.CheckVersion, func(f []byte) { f[0] = v }})
	}
	for _, e := range []uint32{0, 0x80000000, 0x80000001, 0xffffffff} {
		cases = append(cases, sealedCase{fmt.Sprintf("epoch %08x", e), blob.CheckEpoch, func(f []byte) {
			f[1], f[2], f[3], f[4] = byte(e>>24), byte(e>>16), byte(e>>8), byte(e)
		}})
	}
	cases = append(cases,
		sealedCase{"zero nonce", blob.CheckNonce, func(f []byte) { zero(7+l, 19+l)(f) }},
		sealedCase{"zero tag", blob.CheckTag, func(f []byte) { zero(len(f)-16, len(f))(f) }},
		sealedCase{"zero tail", blob.CheckTail, func(f []byte) { zero(len(f)-48, len(f)-16)(f) }},
		sealedCase{"gzip magic in the window", blob.CheckGzip, func(f []byte) { copy(f[23+l:], []byte{0x1f, 0x8b, 0x08}) }},
	)
	for _, c := range cases {
		f := positioned(c.mutate)
		// Premises: the predicate refuses it on exactly this check, and the
		// AAD the position CHECK compares is still this row's.
		var refusal *blob.RefusalError
		if err := blob.LooksSealed(f); !errors.As(err, &refusal) || refusal.Check != c.check {
			t.Fatalf("%s: premise broken: LooksSealed = %v, want check %q", c.name, err, c.check)
		}
		if got := f[7 : 7+l]; string(got) != string(aad) || int(f[5])<<8|int(f[6]) != l {
			t.Fatalf("%s: premise broken: the frame no longer carries this row's AAD", c.name)
		}
		err := insert(f, len(f))
		if code, name := sqlState(err); code != "23514" || name != "op_log_blob_is_sealed" {
			t.Errorf("%s: insert answered %v (constraint %q), want op_log_blob_is_sealed", c.name, err, name)
		}
	}
	// The rest of spec 01's V-F refusals (empty, 1 byte, off-ladder sizes,
	// aad_len past the end, a ledgerd v1 frame) cannot carry this row's AAD in
	// a frame the bucket CHECKs accept, so some other CHECK may name itself
	// first; what AT-P3 requires of them is a CHECK violation, never a stored
	// row and never a get_byte range error.
	for _, c := range blobtest.LooksSealedCases() {
		if c.Want == "" {
			continue
		}
		size := len(c.Frame)
		if !blob.IsBucket(size) {
			size = 1024
		}
		err := insert(c.Frame, size)
		code, _ := sqlState(err)
		if code != "23514" {
			t.Errorf("%s: insert answered %v, want a CHECK violation", c.Name, err)
		}
	}
	// A frame that passes the predicate but names another position.
	other := blob.Envelope{UserID: u, Stream: blob.StreamHot, WriterID: "ios-00000000-0000-4000-8000-00000000000a", WriterCounter: 2}
	s := blobtest.MustSeal3(other, blob.ZeroHash, []byte(`{}`))
	err := insert(s.Bytes, s.SizeBucket)
	if _, name := sqlState(err); name != "op_log_aad_matches_position" {
		t.Fatalf("a frame sealed for counter 2 stored at counter 1: %v", err)
	}
	// And the honest one goes in.
	s = blobtest.MustSeal3(here, blob.ZeroHash, []byte(`{}`))
	if err := insert(s.Bytes, s.SizeBucket); err != nil {
		t.Fatalf("an honest frame was refused: %v", err)
	}
}

// TestTheLogIsAppendOnlyForEveryRoleButTheCascade is spec 02 D-5/D-6 and
// AT-DB-7: the runtime role holds no UPDATE or DELETE on op_log and
// key_history and no DELETE on writers; the trigger refuses the owner too;
// and deleting the account still removes every row through the cascade.
func TestTheLogIsAppendOnlyForEveryRoleButTheCascade(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := oplogtest.NewUser(t, pool)
	oplogtest.NewWriter(t, pool, u, "ios-00000000-0000-4000-8000-00000000000a")
	oplogtest.Append(t, pool, u, "ios-00000000-0000-4000-8000-00000000000a", 3)
	mustExec(t, pool, `INSERT INTO key_history (user_id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, nonce, signature, at)
		SELECT user_id, writer_id, alg, pubkey, dak_pubkey, 'registered', 'authority', $2, $3, now() FROM writers WHERE user_id = $1`,
		u, make([]byte, 32), make([]byte, 64))

	for _, sql := range []string{
		`UPDATE op_log SET created_at = now() WHERE user_id = $1`,
		`DELETE FROM op_log WHERE user_id = $1`,
		`UPDATE key_history SET at = now() WHERE user_id = $1`,
		`DELETE FROM key_history WHERE user_id = $1`,
		`DELETE FROM writers WHERE user_id = $1`,
	} {
		_, err := pool.Exec(bg, sql, u)
		if code, _ := sqlState(err); code != "42501" {
			t.Errorf("runtime: %s answered %v, want permission denied", sql, err)
		}
		_, err = owner.Exec(bg, sql, u)
		if code, _ := sqlState(err); code != "23514" {
			t.Errorf("owner: %s answered %v, want the append-only trigger's refusal", sql, err)
		}
	}
	// Revoke once, and only once.
	mustExec(t, pool, `UPDATE writers SET revoked_at = now() WHERE user_id = $1`, u)
	if _, err := pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1`, u); err == nil {
		t.Fatal("a writer was revoked twice")
	}
	// The account goes, and everything with it.
	mustExec(t, pool, `DELETE FROM users WHERE id = $1`, u)
	for _, table := range []string{"op_log", "key_history", "writers", "oplog_seq", "account_usage"} {
		var n int
		if err := owner.QueryRow(bg, `SELECT count(*) FROM `+table+` WHERE user_id = $1`, u).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("%s still holds %d rows of a deleted account", table, n)
		}
	}
}

func TestTheRuntimeRoleCannotWriteTheMigrationLedger(t *testing.T) {
	pool := pgtest.New(t)
	for _, sql := range []string{
		`INSERT INTO goose_db_version (version_id, is_applied) VALUES (999, true)`,
		`UPDATE goose_db_version SET is_applied = false`,
		`DELETE FROM goose_db_version`,
	} {
		if _, err := pool.Exec(bg, sql); err == nil {
			t.Errorf("runtime: %s was accepted", sql)
		}
	}
	if _, err := pg.AppliedVersion(bg, pool); err != nil {
		t.Fatalf("the runtime role cannot read the ledger: %v", err)
	}
}

// TestTheDefaultLimitPolicyIsPresentAndPermanent: the default row every
// account without an override depends on (spec 02 §5.4: 256 MiB).
func TestTheDefaultLimitPolicyIsPresentAndPermanent(t *testing.T) {
	pool := pgtest.New(t)
	var oplog int64
	if err := pool.QueryRow(bg, `SELECT oplog_bytes FROM account_limits WHERE user_id IS NULL`).Scan(&oplog); err != nil {
		t.Fatalf("read the default policy: %v", err)
	}
	if oplog != 256*1024*1024 {
		t.Errorf("default policy is %d, want %d", oplog, 256*1024*1024)
	}
	wantsError(t, pool, "deleting the default policy", `DELETE FROM account_limits WHERE user_id IS NULL`)
	wantsError(t, pool, "a second default policy", `INSERT INTO account_limits (user_id, oplog_bytes) VALUES (NULL, 1)`)
	u := oplogtest.NewUser(t, pool)
	mustExec(t, pool, `INSERT INTO account_limits (user_id, oplog_bytes) VALUES ($1, 1)`, u)
	wantsError(t, pool, "a second override for one account", `INSERT INTO account_limits (user_id, oplog_bytes) VALUES ($1, 4)`, u)
	var got int64
	if err := pool.QueryRow(bg, `SELECT oplog_bytes FROM account_limits
	                               WHERE user_id = $1 OR user_id IS NULL
	                               ORDER BY user_id NULLS LAST LIMIT 1`, u).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != 1 {
		t.Errorf("override lookup returned %d, want the account's own 1", got)
	}
}

// TestTheResourceVocabularyIsClosed is spec 02 §5.4's vocabulary in SQL.
func TestTheResourceVocabularyIsClosed(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	for _, r := range []string{"oplog_hot_bytes", "upload_bytes", "headroom", "suspended"} {
		mustExec(t, pool, `INSERT INTO account_refusals (user_id, day, resource, count) VALUES ($1, current_date, $2, 1)`, u, r)
	}
	for _, r := range []string{"oplog_cold_bytes", "quarantine_bytes", "quarantine_count", "smtp_daily"} {
		wantsError(t, pool, "refusal "+r, `INSERT INTO account_refusals (user_id, day, resource, count) VALUES ($1, current_date, $2, 1)`, u, r)
		wantsError(t, pool, "usage "+r, `INSERT INTO account_usage (user_id, resource, amount) VALUES ($1, $2, 1)`, u, r)
	}
}

func TestAccountStatusIsActiveOrSuspended(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	var status string
	if err := pool.QueryRow(bg, `SELECT status FROM users WHERE id = $1`, u).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "active" {
		t.Fatalf("a new account is %q, want active", status)
	}
	mustExec(t, pool, `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`, u)
	wantsError(t, pool, "a suspension without its time", `UPDATE users SET status = 'active' WHERE id = $1`, u)
	wantsError(t, pool, "a third status", `UPDATE users SET status = 'deleted' WHERE id = $1`, u)
}

func TestParallelMigrationsDoNotRaceOnGooseGlobals(t *testing.T) {
	// goose's SetDialect/SetBaseFS mutate unsynchronized package-level state;
	// this is the t.Parallel() test that `go test -race` would catch it in.
	for i := 0; i < 8; i++ {
		t.Run(fmt.Sprintf("db%d", i), func(t *testing.T) {
			t.Parallel()
			pool := pgtest.New(t)
			var n int
			if err := pool.QueryRow(bg, `SELECT count(*) FROM pg_tables WHERE schemaname = 'public'`).Scan(&n); err != nil {
				t.Fatal(err)
			}
			if n == 0 {
				t.Fatal("no tables")
			}
		})
	}
}

// ---------------------------------------------------------------------------
// The startup refusals (spec 02 §5.6) and the migrate checks (§5.5)
// ---------------------------------------------------------------------------

func refusalCode(err error) string {
	var r *pg.RefusalError
	if errors.As(err, &r) {
		return r.Code
	}
	return ""
}

func TestServingAsTheRuntimeRolePassesEveryCheck(t *testing.T) {
	pool := pgtest.New(t)
	var warned []string
	if err := pg.CheckServing(bg, pool, func(s string) { warned = append(warned, s) }); err != nil {
		t.Fatalf("CheckServing as hasala_runtime: %v", err)
	}
	if len(warned) != 0 {
		t.Fatalf("unexpected warnings: %v", warned)
	}
}

func TestServingRefusesTheSchemaOwnerAndASuperuser(t *testing.T) {
	_, owner := pgtest.NewWithOwner(t)
	if got := refusalCode(pg.CheckServing(bg, owner, nil)); got != "O2" {
		t.Fatalf("serving as the schema owner: refusal %q, want O2", got)
	}
	if got := refusalCode(pg.CheckServing(bg, pgtest.Superuser(t, owner), nil)); got != "O1" {
		t.Fatalf("serving as a superuser: refusal %q, want O1", got)
	}
}

// Each refusal is reached by the one schema change it guards against, made as
// the owner (the only role that can make it).
func TestServingRefusesAWeakenedSchema(t *testing.T) {
	cases := []struct {
		code string
		sql  []string
	}{
		{"O4", []string{`DELETE FROM goose_db_version WHERE version_id > 0`}},
		{"O5", []string{`ALTER TABLE op_log DROP CONSTRAINT op_log_blob_is_sealed`}},
		{"O5", []string{`ALTER TABLE op_log DROP CONSTRAINT op_log_stream_is_hot`,
			`ALTER TABLE op_log ADD CONSTRAINT op_log_stream_is_hot CHECK (stream = 'hot') NOT VALID`}},
		{"O6", []string{`GRANT DELETE ON op_log TO hasala_runtime`}},
		{"O7", []string{`CREATE OR REPLACE FUNCTION hasala_frame_is_sealed(b bytea) RETURNS boolean
			LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$ SELECT true $fn$`}},
		{"O8", []string{`ALTER TABLE op_log ALTER COLUMN blob DROP NOT NULL`}},
	}
	for _, c := range cases {
		t.Run(c.code+"/"+strings.Fields(c.sql[0])[0], func(t *testing.T) {
			pool, owner := pgtest.NewWithOwner(t)
			for _, sql := range c.sql {
				mustExec(t, owner, sql)
			}
			if got := refusalCode(pg.CheckServing(bg, pool, nil)); got != c.code {
				t.Fatalf("refusal %q, want %s", got, c.code)
			}
		})
	}
}

// O3 on a role of its own: membership is cluster-wide, and granting it to the
// shared hasala_runtime would refuse every other package's tests running
// against the same cluster at that moment.
func TestServingRefusesAMemberOfTheOwnerRole(t *testing.T) {
	_, owner := pgtest.NewWithOwner(t)
	su := pgtest.Superuser(t, owner)
	role := fmt.Sprintf("o3_%d", os.Getpid())
	db := owner.Config().ConnConfig.Database
	mustExec(t, su, `CREATE ROLE `+role+` LOGIN NOSUPERUSER NOINHERIT IN ROLE hasala_migrate`)
	t.Cleanup(func() {
		_, _ = su.Exec(bg, `DROP OWNED BY `+role)
		_, _ = su.Exec(bg, `DROP ROLE IF EXISTS `+role)
	})
	mustExec(t, su, `GRANT CONNECT ON DATABASE `+db+` TO `+role)
	member := pgtest.OpenAs(t, owner, role)
	if got := refusalCode(pg.CheckServing(bg, member, nil)); got != "O3" {
		t.Fatalf("serving as a member of hasala_migrate: refusal %q, want O3", got)
	}
}

func TestADatabaseAheadOfTheBinaryOnlyWarns(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	latest, err := pg.LatestEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	mustExec(t, owner, `INSERT INTO goose_db_version (version_id, is_applied) VALUES ($1, true)`, latest+1)
	var warned []string
	if err := pg.CheckServing(bg, pool, func(s string) { warned = append(warned, s) }); err != nil {
		t.Fatalf("a database ahead of the binary refused: %v", err)
	}
	if len(warned) != 1 || !strings.Contains(warned[0], "ahead") {
		t.Fatalf("warnings %v, want one naming both versions", warned)
	}
}

func TestMigrateRunsOnlyAsTheSchemaOwner(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	if err := pg.CheckMigrator(bg, owner); err != nil {
		t.Fatalf("the owner was refused: %v", err)
	}
	if got := refusalCode(pg.CheckMigrator(bg, pool)); got != "M1" {
		t.Fatalf("migrate as the runtime role: refusal %q, want M1", got)
	}
	if err := pg.MigrateLocked(bg, owner, 0); err != nil {
		t.Fatalf("an up-to-date migrate is a no-op: %v", err)
	}
	n, err := pg.Pending(bg, pool)
	if err != nil || n != 0 {
		t.Fatalf("Pending = %d, %v; want 0", n, err)
	}
	// 00001 plus the pre-deploy migrations of 00002–00029 (squashed into the
	// baseline before the first QA deploy): today 00010_keys, 00020_mailbox_links,
	// 00021_waitlist_invites_mail, 00022_accounts, 00023_mailbox_outlook and
	// 00024_mailbox_one_account.
	latest, err := pg.LatestEmbedded()
	if err != nil || latest != 25 {
		t.Fatalf("LatestEmbedded = %d, %v; want 25", latest, err)
	}
}
