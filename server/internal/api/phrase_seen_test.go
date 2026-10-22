package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestTheWordsNotYetSeenOverHTTP(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	k := h.onboard(false)
	wantError(t, h.req("POST", "/api/v1/keys/phrase/seen", k.token, map[string]any{}), "no_keys")
	req := k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)
	req.PhraseUnseen = true
	wantStatus(t, h.req("POST", "/api/v1/account/bootstrap", k.token, req), http.StatusCreated)

	acct := decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", k.token, nil))
	if acct.PhraseUnseenSince == nil {
		t.Fatal("GET /account does not say the words are not yet seen")
	}
	wantStatus(t, h.req("POST", "/api/v1/keys/phrase/seen", "", map[string]any{}), http.StatusUnauthorized)
	wantError(t, h.req("POST", "/api/v1/keys/phrase/seen", k.token, map[string]any{"words": "x"}), "bad_request")
	for range 2 {
		w := h.req("POST", "/api/v1/keys/phrase/seen", k.token, map[string]any{})
		wantStatus(t, w, http.StatusNoContent)
		if w.Body.Len() != 0 {
			t.Fatalf("the answer carries %q", w.Body)
		}
	}
	w := h.req("GET", "/api/v1/account", k.token, nil)
	if decodeJSON[AccountResponse](t, w).PhraseUnseenSince != nil || !strings.Contains(w.Body.String(), `"phrase_unseen_since":null`) {
		t.Fatalf("after the report GET /account says %s", w.Body)
	}
}

func TestAnOrdinaryBootstrapCountsTheWordsSeen(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	k := h.onboard(true)
	if decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", k.token, nil)).PhraseUnseenSince != nil {
		t.Fatal("a bootstrap after the words were shown left them unseen")
	}
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "pw@example.com")
	if decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", a.token, nil)).PhraseUnseenSince != nil {
		t.Fatal("a password signup left the words unseen")
	}
}

func TestPhraseUnseenNeedsTheSyncedPRFPasskey(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	k := h.onboard(false)
	req := k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), false)
	req.PhraseUnseen = true
	wantError(t, h.req("POST", "/api/v1/account/bootstrap", k.token, req), "bad_request")
	if _, err := h.pool.Exec(bg, `UPDATE webauthn_credentials SET backup_state = false WHERE user_id = $1`, k.user); err != nil {
		t.Fatal(err)
	}
	req = k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)
	req.PhraseUnseen = true
	wantError(t, h.req("POST", "/api/v1/account/bootstrap", k.token, req), "bad_request")
	wantStatus(t, h.req("POST", "/api/v1/account/bootstrap", k.token,
		k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)), http.StatusCreated)
	if decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", k.token, nil)).PhraseUnseenSince != nil {
		t.Fatal("the bootstrap without phrase_unseen left the words unseen")
	}
}
