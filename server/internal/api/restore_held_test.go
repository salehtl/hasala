package api

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestAFreezeOverHTTPIsInTheLedgerWhenTheRequestEnds(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	h.srv.PurgeLedger = filepath.Join(t.TempDir(), "purged")
	k := h.onboard(true)
	wantStatus(t, h.req("POST", "/api/v1/account/freeze/now", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionAccountFreeze)}), http.StatusNoContent)
	entries, err := purgeledger.Read(h.srv.PurgeLedger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindFreeze {
		t.Fatalf("ledger %+v %v, want the freeze", entries, err)
	}
	if n := countIn(t, h, `SELECT count(*) FROM restore_ledger_held`); n != 0 {
		t.Fatalf("%d lines still held", n)
	}
}

func TestAFreezeIsKeptForTheLedgerWhileTheLedgerRefusesWrites(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	dir := filepath.Join(t.TempDir(), "missing")
	h.srv.PurgeLedger = filepath.Join(dir, "purged")
	k := h.onboard(true)
	wantStatus(t, h.req("POST", "/api/v1/account/freeze/now", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionAccountFreeze)}), http.StatusNoContent)
	if n := countIn(t, h, `SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, k.user); n != 1 {
		t.Fatal("a ledger that refused the write stopped the freeze")
	}
	if n := countIn(t, h, `SELECT count(*) FROM restore_ledger_held`); n != 1 {
		t.Fatalf("%d lines held, want the freeze's", n)
	}
	if err := os.Mkdir(dir, 0o770); err != nil {
		t.Fatal(err)
	}
	if n, err := purgeledger.Flush(bg, h.pool, h.srv.PurgeLedger); err != nil || n != 1 {
		t.Fatalf("the sweep's retry: %d %v", n, err)
	}
	entries, err := purgeledger.Read(h.srv.PurgeLedger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindFreeze {
		t.Fatalf("ledger %+v %v, want the freeze", entries, err)
	}
}

func TestNoLedgerPathHoldsNothing(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	k := h.onboard(true)
	wantStatus(t, h.req("POST", "/api/v1/account/freeze/now", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionAccountFreeze)}), http.StatusNoContent)
	if n := countIn(t, h, `SELECT count(*) FROM restore_ledger_held`); n != 0 {
		t.Fatalf("%d lines held with no ledger to take them", n)
	}
}
