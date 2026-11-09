package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestARevocationTheLedgerMissedIsRecordedByRunningItAgain(t *testing.T) {
	pool := pgtest.New(t)
	dsn := "HASALA_PG_DSN=" + pool.Config().ConnString()
	if code, _, msg := hasalad(t, []string{dsn}, "invite", "mint"); code != 0 {
		t.Fatalf("mint exited %d (%s)", code, msg)
	}
	code, list, msg := hasalad(t, []string{dsn}, "invite", "list")
	if code != 0 {
		t.Fatalf("list exited %d (%s)", code, msg)
	}
	short := strings.Fields(list)[0]

	broken := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + t.TempDir()}
	code, out, msg := hasalad(t, broken, "invite", "revoke", short)
	if code != 1 || !strings.Contains(out, "revoked invite") || !strings.Contains(msg, "did not record it") {
		t.Fatalf("a revocation whose ledger write failed exited %d with %q (%s)", code, out, msg)
	}

	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{dsn, "HASALA_PURGE_LEDGER_PATH=" + ledger}
	code, out, msg = hasalad(t, env, "invite", "revoke", short)
	if code != 0 || !strings.Contains(out, "already revoked") {
		t.Fatalf("the second run exited %d with %q (%s)", code, out, msg)
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindInviteRevoked ||
		!strings.HasPrefix(strings.ReplaceAll(entries[0].ID.String(), "-", ""), short) {
		t.Fatalf("ledger %+v %v, want the revocation the first run missed", entries, err)
	}

	if code, out, msg := hasalad(t, env, "invite", "revoke", short); code != 2 || !strings.Contains(msg, "no open invite") {
		t.Fatalf("a third run exited %d with %q (%s), want the refusal it always gave", code, out, msg)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a third run, want one entry", entries, err)
	}

	id := entries[0].ID
	if _, err := pool.Exec(context.Background(), `UPDATE invite_codes SET state = 'active', closed_at = NULL WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 || !strings.Contains(out, "1 invite revocation(s)") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	var state string
	if err := pool.QueryRow(context.Background(), `SELECT state FROM invite_codes WHERE id = $1`, id).Scan(&state); err != nil || state != "revoked" {
		t.Fatalf("a restore brought the invite back: %q, %v", state, err)
	}
}
