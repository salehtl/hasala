package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestAccountUnfreezeLiftsAHolderFreezeAndRecordsIt(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	freeze := func() {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE users SET frozen_at = now() - interval '1 hour',
		    freeze_trigger_at = now() - interval '1 hour', frozen_by = 'holder', holder_also_froze = false WHERE id = $1`, user); err != nil {
			t.Fatal(err)
		}
	}
	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	freeze()
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}

	unknown := uuid.NewString()
	if code, _, msg := hasalad(t, env, "account", "unfreeze", unknown, "--confirm", unknown); code != 2 ||
		!strings.Contains(msg, "no account") {
		t.Fatalf("account unfreeze of an unknown account exited %d (%s)", code, msg)
	}
	if code, _, msg := hasalad(t, env, "account", "unfreeze", id); code != 2 {
		t.Fatalf("account unfreeze without --confirm exited %d (%s)", code, msg)
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, user) != 1 {
		t.Fatal("a refused unfreeze lifted the freeze")
	}

	code, out, msg := hasalad(t, env, "account", "unfreeze", id, "--confirm", id)
	if code != 0 || !strings.Contains(out, "unfrozen (was frozen by the holder)") {
		t.Fatalf("account unfreeze exited %d with %q (%s)", code, out, msg)
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL AND frozen_by IS NULL`, user) != 1 {
		t.Fatal("the account is still frozen")
	}
	if count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'account_unfrozen'`, user) != 1 {
		t.Fatal("the unfreeze was not recorded as an auth event")
	}
	if count(`SELECT count(*) FROM mail_log WHERE user_id = $1 AND kind = 'alert' AND subkind = 'account_unfrozen'`, user) != 1 {
		t.Fatal("the unfreeze alert was not queued")
	}
	if count(`SELECT count(*) FROM admin_audit WHERE action = 'cli.account_unfreeze' AND target_id = $1`, id) != 1 {
		t.Fatal("no audit row")
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].ID != user || entries[0].Kind != purgeledger.KindUnfreeze {
		t.Fatalf("ledger %+v %v, want one unfreeze of the account", entries, err)
	}

	if code, out, msg := hasalad(t, env, "account", "unfreeze", id, "--confirm", id); code != 0 ||
		!strings.Contains(out, "was not frozen") {
		t.Fatalf("a second account unfreeze exited %d with %q (%s)", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a second unfreeze, want one entry", entries, err)
	}

	freeze()
	if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 || !strings.Contains(out, "1 unfreeze(s)") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL`, user) != 1 {
		t.Fatal("a restore brought back the freeze the operator lifted")
	}
	if code, out, _ := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 || !strings.Contains(out, "0 unfreeze(s)") {
		t.Fatalf("a second replay exited %d with %q", code, out)
	}
}

func TestAccountUnfreezeWithoutALedgerWarns(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	if _, err := pool.Exec(context.Background(), `UPDATE users SET frozen_at = now(), freeze_trigger_at = now(), frozen_by = 'holder'
	    WHERE id = $1`, user); err != nil {
		t.Fatal(err)
	}
	id := user.String()
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString()}
	code, out, msg := hasalad(t, env, "account", "unfreeze", id, "--confirm", id)
	if code != 0 || !strings.Contains(out, "unfrozen") || !strings.Contains(msg, "HASALA_PURGE_LEDGER_PATH is not set") {
		t.Fatalf("account unfreeze without a ledger exited %d with %q (%s)", code, out, msg)
	}
}

func TestAnUnfreezeTheLedgerMissedIsRecordedByRunningItAgain(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	freeze := func() {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE users SET frozen_at = now() - interval '1 hour',
		    freeze_trigger_at = now() - interval '1 hour', frozen_by = 'holder', holder_also_froze = false WHERE id = $1`, user); err != nil {
			t.Fatal(err)
		}
	}
	freeze()
	dsn := "HASALA_PG_DSN=" + pool.Config().ConnString()
	broken := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + t.TempDir()}
	code, out, msg := hasalad(t, broken, "account", "unfreeze", id, "--confirm", id)
	if code != 1 || !strings.Contains(out, "unfrozen") || !strings.Contains(msg, "did not record it") {
		t.Fatalf("an unfreeze whose ledger write failed exited %d with %q (%s)", code, out, msg)
	}

	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + ledger}
	code, out, msg = hasalad(t, env, "account", "unfreeze", id, "--confirm", id)
	if code != 0 || !strings.Contains(out, "was not frozen") {
		t.Fatalf("the second run exited %d with %q (%s)", code, out, msg)
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].ID != user || entries[0].Kind != purgeledger.KindUnfreeze {
		t.Fatalf("ledger %+v %v, want the unfreeze the first run missed", entries, err)
	}

	if code, out, msg := hasalad(t, env, "account", "unfreeze", id, "--confirm", id); code != 0 ||
		!strings.Contains(out, "nothing changed") {
		t.Fatalf("a third run exited %d with %q (%s)", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a third run, want one entry", entries, err)
	}

	freeze()
	if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 || !strings.Contains(out, "1 unfreeze(s)") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	var frozen bool
	if err := pool.QueryRow(ctx, `SELECT frozen_at IS NOT NULL FROM users WHERE id = $1`, user).Scan(&frozen); err != nil || frozen {
		t.Fatalf("a restore brought back the freeze: frozen %v, %v", frozen, err)
	}
}

func TestAnAccountNeverUnfrozenHasNothingToRecord(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}
	if code, out, msg := hasalad(t, env, "account", "unfreeze", id, "--confirm", id); code != 0 ||
		!strings.Contains(out, "nothing changed") {
		t.Fatalf("unfreeze of an unfrozen account exited %d with %q (%s)", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 0 {
		t.Fatalf("ledger %+v %v, want none", entries, err)
	}
}

func TestAccountSuspendAndUnsuspendRecordEachForARestore(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}

	for _, verb := range []string{"suspend", "unsuspend"} {
		unknown := uuid.NewString()
		if code, _, msg := hasalad(t, env, "account", verb, unknown, "--confirm", unknown); code != 2 ||
			!strings.Contains(msg, "no account") {
			t.Fatalf("account %s of an unknown account exited %d (%s)", verb, code, msg)
		}
		if code, _, msg := hasalad(t, env, "account", verb, id); code != 2 {
			t.Fatalf("account %s without --confirm exited %d (%s)", verb, code, msg)
		}
		if code, _, msg := hasalad(t, env, "account", verb, id, "--confirm", uuid.NewString()); code != 2 {
			t.Fatalf("account %s with another id in --confirm exited %d (%s)", verb, code, msg)
		}
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND status = 'active' AND suspended_at IS NULL`, user) != 1 {
		t.Fatal("a refused command changed the account")
	}

	code, out, msg := hasalad(t, env, "account", "suspend", id, "--confirm", id)
	if code != 0 || out != "account "+id+": suspended\n" {
		t.Fatalf("account suspend exited %d with %q (%s)", code, out, msg)
	}
	var since time.Time
	if err := pool.QueryRow(ctx, `SELECT suspended_at FROM users WHERE id = $1 AND status = 'suspended'`, user).Scan(&since); err != nil {
		t.Fatalf("the account is not suspended: %v", err)
	}
	if count(`SELECT count(*) FROM admin_audit WHERE action = 'cli.account_suspend' AND target_kind = 'account' AND target_id = $1`, id) != 1 {
		t.Fatal("no audit row for the suspension")
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].ID != user || entries[0].Kind != purgeledger.KindSuspend ||
		!entries[0].At.Equal(since.Truncate(time.Second)) {
		t.Fatalf("ledger %+v %v, want one suspension of the account at %v", entries, err, since)
	}

	code, out, msg = hasalad(t, env, "account", "suspend", id, "--confirm", id)
	if code != 0 || out != "account "+id+": was already suspended; nothing changed\n" {
		t.Fatalf("a second account suspend exited %d with %q (%s)", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a second suspend, want one entry", entries, err)
	}
	if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 ||
		!strings.Contains(out, "0 suspension(s) and 0 unsuspend(s) applied again") {
		t.Fatalf("a replay on the database that holds the suspension exited %d with %q (%s)", code, out, msg)
	}

	code, out, msg = hasalad(t, env, "account", "unsuspend", id, "--confirm", id)
	if code != 0 || out != "account "+id+": no longer suspended\n" {
		t.Fatalf("account unsuspend exited %d with %q (%s)", code, out, msg)
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND status = 'active' AND suspended_at IS NULL`, user) != 1 {
		t.Fatal("the account is still suspended")
	}
	var lifted time.Time
	if err := pool.QueryRow(ctx, `SELECT at FROM admin_audit WHERE action = 'cli.account_unsuspend' AND target_kind = 'account'
	    AND target_id = $1`, id).Scan(&lifted); err != nil {
		t.Fatalf("no audit row for the unsuspend: %v", err)
	}
	entries, err = purgeledger.Read(ledger)
	if err != nil || len(entries) != 2 || entries[1].ID != user || entries[1].Kind != purgeledger.KindUnsuspend ||
		!entries[1].At.Equal(lifted.Truncate(time.Second)) {
		t.Fatalf("ledger %+v %v, want the suspension and then its lift at %v", entries, err, lifted)
	}

	code, out, msg = hasalad(t, env, "account", "unsuspend", id, "--confirm", id)
	if code != 0 || out != "account "+id+": was not suspended; nothing changed\n" {
		t.Fatalf("a second account unsuspend exited %d with %q (%s)", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 2 {
		t.Fatalf("ledger %+v %v after a second unsuspend, want two entries", entries, err)
	}
	for range 2 {
		if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 ||
			!strings.Contains(out, "0 suspension(s) and 0 unsuspend(s) applied again") || strings.Contains(out, id) {
			t.Fatalf("a replay on the database that holds both changes exited %d with %q (%s)", code, out, msg)
		}
	}
	if count(`SELECT count(*) FROM users WHERE id = $1 AND status = 'active'`, user) != 1 {
		t.Fatal("a replay on a database that was not restored suspended the account again")
	}
}

func TestAReplayDoesNotUndoASuspensionTheDatabaseAlreadySaw(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}
	if code, out, msg := hasalad(t, env, "account", "suspend", id, "--confirm", id); code != 0 {
		t.Fatalf("account suspend exited %d with %q (%s)", code, out, msg)
	}
	if _, err := pool.Exec(ctx, `UPDATE users SET status = 'active', suspended_at = NULL WHERE id = $1`, user); err != nil {
		t.Fatal(err)
	}
	if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 ||
		!strings.Contains(out, "0 suspension(s) and 0 unsuspend(s) applied again") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	var status string
	if err := pool.QueryRow(ctx, `SELECT status FROM users WHERE id = $1`, user).Scan(&status); err != nil || status != "active" {
		t.Fatalf("status %q (%v): a replay changed a database that holds the audit row of its line", status, err)
	}
}

func TestAReplayAppliesEachAccountsLatestSuspensionToARestoredDatabase(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	suspended := oplogtest.NewUser(t, pool)
	lifted := oplogtest.NewUser(t, pool)
	again := oplogtest.NewUser(t, pool)
	cleared := oplogtest.NewUser(t, pool)
	later := oplogtest.NewUser(t, pool)
	gone := uuid.New()
	now := time.Now().UTC().Truncate(time.Second)
	at := now.Add(-time.Hour)
	laterAt := at.Add(time.Minute)
	stamp := func(t time.Time) string { return t.Format(time.RFC3339) }
	if _, err := pool.Exec(ctx, `UPDATE users SET status = 'suspended', suspended_at = $2 WHERE id = ANY($1)`,
		[]uuid.UUID{lifted, cleared}, at.Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE users SET status = 'suspended', suspended_at = $2 WHERE id = $1`,
		later, laterAt); err != nil {
		t.Fatal(err)
	}
	body := suspended.String() + " " + stamp(at) + " suspend\n" +
		lifted.String() + " " + stamp(at) + " unsuspend\n" +
		again.String() + " " + stamp(at.Add(-2*time.Hour)) + " suspend\n" +
		again.String() + " " + stamp(at.Add(-time.Hour)) + " unsuspend\n" +
		again.String() + " " + stamp(at) + " suspend\n" +
		cleared.String() + " " + stamp(at.Add(-2*time.Hour)) + " suspend\n" +
		cleared.String() + " " + stamp(at.Add(-time.Hour)) + " unsuspend\n" +
		later.String() + " " + stamp(at) + " unsuspend\n" +
		gone.String() + " " + stamp(at) + " suspend\n"
	ledger := filepath.Join(t.TempDir(), "purged")
	if err := os.WriteFile(ledger, []byte(body), 0o640); err != nil {
		t.Fatal(err)
	}
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}
	code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger")
	if code != 0 || !strings.Contains(out, "9 entries") || !strings.Contains(out, "2 suspension(s) and 2 unsuspend(s) applied again") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	for _, u := range []uuid.UUID{suspended, lifted, again, cleared, later, gone} {
		if strings.Contains(out, u.String()) {
			t.Fatalf("the replay printed an id: %q", out)
		}
	}
	for u, want := range map[uuid.UUID]*time.Time{
		suspended: &at,
		lifted:    nil,
		again:     &at,
		cleared:   nil,
		later:     &laterAt,
	} {
		var (
			status string
			since  *time.Time
		)
		if err := pool.QueryRow(ctx, `SELECT status, suspended_at FROM users WHERE id = $1`, u).Scan(&status, &since); err != nil {
			t.Fatal(err)
		}
		if (want == nil) != (since == nil) || (want != nil && !since.Equal(*want)) || (status == "suspended") != (want != nil) {
			t.Fatalf("account %s: %s since %v, want suspended since %v", u, status, since, want)
		}
	}
	if code, out, _ := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 ||
		!strings.Contains(out, "0 suspension(s) and 0 unsuspend(s) applied again") {
		t.Fatalf("a second replay exited %d with %q", code, out)
	}
}

func TestASuspensionChangeTheLedgerMissedIsRecordedByRunningItAgain(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	dsn := "HASALA_PG_DSN=" + pool.Config().ConnString()
	broken := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + t.TempDir()}
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + ledger}
	for i, c := range []struct {
		verb, done, missed, nothing string
		kind                        purgeledger.Kind
	}{
		{"suspend", ": suspended\n", "was already suspended; the restore ledger now records its suspension",
			"was already suspended; nothing changed", purgeledger.KindSuspend},
		{"unsuspend", ": no longer suspended\n", "was not suspended; the restore ledger now records its last unsuspend",
			"was not suspended; nothing changed", purgeledger.KindUnsuspend},
	} {
		code, out, msg := hasalad(t, broken, "account", c.verb, id, "--confirm", id)
		if code != 1 || !strings.HasSuffix(out, c.done) || !strings.Contains(msg, "did not record it") {
			t.Fatalf("an account %s whose ledger write failed exited %d with %q (%s)", c.verb, code, out, msg)
		}
		code, out, msg = hasalad(t, env, "account", c.verb, id, "--confirm", id)
		if code != 0 || !strings.Contains(out, c.missed) {
			t.Fatalf("the second account %s exited %d with %q (%s)", c.verb, code, out, msg)
		}
		entries, err := purgeledger.Read(ledger)
		if err != nil || len(entries) != i+1 || entries[i].ID != user || entries[i].Kind != c.kind {
			t.Fatalf("ledger %+v %v, want the %s the first run missed", entries, err, c.verb)
		}
		code, out, msg = hasalad(t, env, "account", c.verb, id, "--confirm", id)
		if code != 0 || !strings.Contains(out, c.nothing) {
			t.Fatalf("a third account %s exited %d with %q (%s)", c.verb, code, out, msg)
		}
		if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != i+1 {
			t.Fatalf("ledger %+v %v after a third %s", entries, err, c.verb)
		}
	}
}

func TestAccountSuspendWithoutALedgerWarns(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	id := user.String()
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString()}
	for _, verb := range []string{"suspend", "unsuspend"} {
		code, out, msg := hasalad(t, env, "account", verb, id, "--confirm", id)
		if code != 0 || !strings.Contains(out, "suspended") || !strings.Contains(msg, "HASALA_PURGE_LEDGER_PATH is not set") {
			t.Fatalf("account %s without a ledger exited %d with %q (%s)", verb, code, out, msg)
		}
	}
}
