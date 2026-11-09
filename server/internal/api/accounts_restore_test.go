package api

import (
	"net/http"
	"path/filepath"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestLogoutAllWithoutServerKeysIsInTheRestoreLedger(t *testing.T) {
	h := newHarness(t).passkeys()
	h.srv.PurgeLedger = filepath.Join(t.TempDir(), "purged")
	k := h.onboard(true)
	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionSessionLogoutAll)}), http.StatusNoContent)
	entries, err := purgeledger.Read(h.srv.PurgeLedger)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindSessions || entries[0].ID != k.user {
		t.Fatalf("ledger %+v, want one sessions line for the account", entries)
	}
}
