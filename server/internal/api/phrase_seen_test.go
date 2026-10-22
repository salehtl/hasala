package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestTheFirstViewOfTheWordsCountsThemSeen(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	k := h.onboard(false)
	req := k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)
	req.PhraseUnseen = true
	wantStatus(t, h.req("POST", "/api/v1/account/bootstrap", k.token, req), http.StatusCreated)

	acct := decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", k.token, nil))
	if acct.PhraseUnseenSince == nil {
		t.Fatal("GET /account does not say the words are not yet seen")
	}
	if w := h.req("POST", "/api/v1/keys/phrase/seen", k.token, map[string]any{}); w.Code != http.StatusNotFound && w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /keys/phrase/seen answered %d; the route is gone", w.Code)
	}
	if decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", k.token, nil)).PhraseUnseenSince == nil {
		t.Fatal("the words count as seen without a view")
	}

	shown := func() int {
		var n int
		if err := h.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE user_id = $1 AND kind = 'alert' AND subkind = 'phrase_viewed'`,
			k.user).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for i := 1; i <= 2; i++ {
		w := h.req("POST", "/api/v1/keys/phrase/view", k.token,
			StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionPhraseView)})
		wantStatus(t, w, http.StatusOK)
		if n := shown(); n != i {
			t.Fatalf("after view %d, %d security emails, want %d", i, n, i)
		}
		w = h.req("GET", "/api/v1/account", k.token, nil)
		if decodeJSON[AccountResponse](t, w).PhraseUnseenSince != nil || !strings.Contains(w.Body.String(), `"phrase_unseen_since":null`) {
			t.Fatalf("after view %d GET /account says %s", i, w.Body)
		}
	}
}

func TestAPasskeyThatAloneOpensUnseenWordsStays(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	h.srv.AccountPerUser = NewLimiter(100, 100, 16, nil)
	k := h.onboard(false)
	req := k.bootstrapRequest(k.device, keyproto.AuthKindPasskey, k.attestation(), true)
	req.PhraseUnseen = true
	wantStatus(t, h.req("POST", "/api/v1/account/bootstrap", k.token, req), http.StatusCreated)
	plain := k.addPasskey(k.token)

	wantError(t, k.deletePasskey(k.token, k.authn, k.authn.CredID), "phrase_unseen")
	su := k.stepUp(k.token, keyproto.ActionKeysWrapDelete, k.authn.CredID)
	wantError(t, h.req("DELETE", "/api/v1/keys/wraps", k.token,
		DeleteKeyWrapRequest{CredentialID: b64url(k.authn.CredID), StepUp: su}), "phrase_unseen")
	if n := len(h.listPasskeys(k.token).Passkeys); n != 2 {
		t.Fatalf("%d passkeys after the refusals, want 2", n)
	}
	wantStatus(t, k.deletePasskey(k.token, k.authn, plain.CredID), http.StatusNoContent)

	second, w := k.addFinish(k.token, prfWrap(4))
	wantStatus(t, w, http.StatusCreated)
	su = k.stepUp(k.token, keyproto.ActionKeysWrapDelete, k.authn.CredID)
	wantStatus(t, h.req("DELETE", "/api/v1/keys/wraps", k.token,
		DeleteKeyWrapRequest{CredentialID: b64url(k.authn.CredID), StepUp: su}), http.StatusNoContent)
	wantError(t, k.deletePasskey(k.token, second, second.CredID), "phrase_unseen")

	wantStatus(t, h.req("POST", "/api/v1/keys/phrase/view", k.token,
		StepUpOnlyRequest{StepUp: k.stepUpWith(k.token, second, keyproto.ActionPhraseView)}), http.StatusOK)
	wantStatus(t, k.deletePasskey(k.token, second, second.CredID), http.StatusNoContent)
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
