package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

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
