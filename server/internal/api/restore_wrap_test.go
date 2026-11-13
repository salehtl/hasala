package api

import (
	"bytes"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestAWrapDeletionOverHTTPIsInTheLedgerWhenTheRequestEnds(t *testing.T) {
	h := newHarness(t).passkeys()
	h.srv.PurgeLedger = filepath.Join(t.TempDir(), "purged")
	k := h.onboard(true)
	cred := k.authn.CredID
	su := k.stepUp(k.token, keyproto.ActionKeysWrapDelete, cred)
	wantStatus(t, h.req("DELETE", "/api/v1/keys/wraps", k.token, DeleteKeyWrapRequest{CredentialID: b64url(cred), StepUp: su}),
		http.StatusNoContent)
	entries, err := purgeledger.Read(h.srv.PurgeLedger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindWrap || entries[0].ID != k.user ||
		!bytes.Equal(entries[0].Credential, cred) {
		t.Fatalf("ledger %+v %v, want the deleted wrap", entries, err)
	}
	if n := countIn(t, h, `SELECT count(*) FROM restore_ledger_held`); n != 0 {
		t.Fatalf("%d lines still held", n)
	}
}
