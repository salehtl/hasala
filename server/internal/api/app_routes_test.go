package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// appRoutes is every route the iOS app calls in the TestFlight build (the
// client API the PR lists), as serve mounts them with the server keys and a
// relying party. Each must exist: an absent one answers the API's 404, and a
// wrong method 405.
var appRoutes = []struct{ method, path string }{
	{"GET", "/api/v1/meta"},
	{"POST", "/api/v1/auth/signup/begin"},
	{"POST", "/api/v1/auth/signup/verify"},
	{"POST", "/api/v1/auth/password/register"},
	{"POST", "/api/v1/auth/password/login/begin"},
	{"POST", "/api/v1/auth/password/login/finish"},
	{"POST", "/api/v1/auth/passkey/register/begin"},
	{"POST", "/api/v1/auth/passkey/register/finish"},
	{"POST", "/api/v1/auth/passkey/login/begin"},
	{"POST", "/api/v1/auth/passkey/login/finish"},
	{"GET", "/api/v1/auth/session"},
	{"POST", "/api/v1/auth/logout"},
	{"POST", "/api/v1/auth/step-up/begin"},
	{"GET", "/api/v1/account"},
	{"PUT", "/api/v1/account/display-name"},
	{"DELETE", "/api/v1/account"},
	{"POST", "/api/v1/writers/challenge"},
	{"POST", "/api/v1/writers/register"},
	{"POST", "/api/v1/account/bootstrap"},
	{"GET", "/api/v1/keys"},
	{"GET", "/api/v1/key-history"},
	{"POST", "/api/v1/keys/phrase/seen"},
	{"POST", "/api/v1/sync"},
	{"GET", "/api/v1/sync"},
	{"PUT", "/api/v1/push/apns"},
	{"DELETE", "/api/v1/push/apns"},
	{"POST", "/api/v1/bank-requests"},
	{"GET", "/api/v1/bank-requests"},
}

func TestTheAppsRoutesAreMounted(t *testing.T) {
	h := newHarness(t).passkeys()
	h.accounts()
	for _, rt := range appRoutes {
		w := h.req(rt.method, rt.path, "", map[string]any{})
		if rt.path == "/api/v1/bank-requests" {
			// Without the website group only the signed-in request exists.
			wantStatus(t, w, http.StatusNotFound)
			continue
		}
		if w.Code == http.StatusNotFound || w.Code == http.StatusMethodNotAllowed {
			t.Errorf("%s %s answered %d %s", rt.method, rt.path, w.Code, w.Body)
		}
	}
}

// The reviewer's path on the server (integration plan §2.5; spec 02 §14.2):
// a review invite, a password signup, #40 reporting the review flag, the
// calls the app makes while setting up, a second iPhone signing in with the
// password, and the account deleting itself with the DAK and the password
// (the only factor a password account has), after which every device gets
// 410 account_deleted.
func TestTheReviewAccountPathOverHTTP(t *testing.T) {
	h := newHarness(t).passkeys()
	keys, fake, q := h.accounts()
	code, err := auth.MintInvite(bg, h.pool, auth.MintOptions{Review: true, Note: "demo", Now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	a := h.passwordSignupWith(keys, fake, "review@example.com", code)

	// #40 and #14.
	w := h.req("GET", "/api/v1/account", a.token, nil)
	wantStatus(t, w, http.StatusOK)
	acct := decodeJSON[AccountResponse](t, w)
	if !acct.ReviewAccount || !acct.HasPassword || acct.HasPasskey || !acct.HasKeys || acct.Frozen || acct.Restricted ||
		acct.DisplayName != "Maya Rahman" || acct.PasswordSalt != b64(keys.PasswordSalt(a.addr)) {
		t.Fatalf("GET /account %+v", acct)
	}
	if !strings.Contains(w.Body.String(), `"review_account":true`) {
		t.Fatalf("the wire carries no review_account: %s", w.Body)
	}
	w = h.req("GET", "/api/v1/auth/session", a.token, nil)
	wantStatus(t, w, http.StatusOK)
	if s := decodeJSON[SessionWire](t, w); s.WriterID == nil || *s.WriterID != a.device.WriterID || s.Restricted {
		t.Fatalf("session %+v", s)
	}
	// An account from an ordinary invite is not a review account.
	plain := h.passwordSignup(keys, fake, "plain@example.com")
	if decodeJSON[AccountResponse](t, h.req("GET", "/api/v1/account", plain.token, nil)).ReviewAccount {
		t.Fatal("a printed invite made a review account")
	}

	// Setup: the display name (#76), the meta document, keys, the writers'
	// challenge, the APNs token, and the app's bank request (#74, source app).
	wantStatus(t, h.req("PUT", "/api/v1/account/display-name", a.token, DisplayNameRequest{DisplayName: "Maya"}),
		http.StatusNoContent)
	w = h.req("GET", "/api/v1/meta", "", nil)
	wantStatus(t, w, http.StatusOK)
	if m := decodeJSON[MetaResponse](t, w); m.LogGeneration < 1 || m.GmailWatchTopic != nil || m.ServerTime == "" {
		t.Fatalf("meta %+v", m)
	}
	wantStatus(t, h.req("GET", "/api/v1/keys", a.token, nil), http.StatusOK)
	wantStatus(t, h.req("POST", "/api/v1/writers/challenge", a.token, map[string]any{}), http.StatusOK)
	tokenHex := strings.Repeat("ab", 32)
	wantStatus(t, h.req("PUT", "/api/v1/push/apns", a.token, PutAPNsRequest{TokenHex: tokenHex, Environment: "sandbox"}),
		http.StatusNoContent)
	if h.countAPNs(mustUUID(t, a.user)) != 1 {
		t.Fatal("the APNs token was not stored")
	}
	for range 2 {
		w = h.req("POST", "/api/v1/bank-requests", a.token, map[string]any{"bank": "adcb", "source": "app"})
		wantStatus(t, w, http.StatusAccepted)
		if w.Body.String() != `{"status":"counted"}` {
			t.Fatalf("bank request %s", w.Body)
		}
	}
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token,
		map[string]any{"bank": "other", "otherBank": "Some Bank", "source": "app"}), http.StatusAccepted)
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token, map[string]any{"bank": "adcb", "source": "web"}),
		http.StatusBadRequest)
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", "", map[string]any{"bank": "adcb", "source": "web"}),
		http.StatusNotFound)
	var n int
	_ = h.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE user_id = $1 AND source = 'app'`, a.user).Scan(&n)
	if n != 2 {
		t.Fatalf("%d app bank requests, want 2 (once per bank)", n)
	}

	// A second iPhone (C2-P): the password alone, no device yet.
	w = h.passwordLogin(a, a.s)
	wantStatus(t, w, http.StatusOK)
	second := decodeJSON[SignInResponse](t, w)
	if second.WriterID != nil || !second.HasKeys || second.Restricted {
		t.Fatalf("second sign-in %+v", second)
	}
	wantStatus(t, h.req("GET", "/api/v1/account", second.SessionToken, nil), http.StatusOK)

	// Delete the account: account.delete step-up with the DAK and the
	// password, and the writer's signature over the same nonce.
	deviceStepUp := func() (*StepUpWire, []byte) {
		t.Helper()
		ph, _ := keyproto.ParamsHash(keyproto.ActionAccountDelete, []byte(a.user))
		w := h.req("POST", "/api/v1/auth/step-up/begin", a.token, StepUpBeginRequest{Action: "account.delete",
			ParamsHash: hex.EncodeToString(ph[:]), ProofKind: "device"})
		wantStatus(t, w, http.StatusOK)
		b := decodeJSON[StepUpBeginResponse](t, w)
		nonce, _ := base64.RawURLEncoding.DecodeString(b.Nonce)
		raw, _ := base64.RawURLEncoding.DecodeString(b.Challenge)
		var c [32]byte
		copy(c[:], raw)
		msg, err := keyproto.DeviceStepUpMessage(c, a.device.WriterID)
		if err != nil {
			t.Fatal(err)
		}
		return &StepUpWire{Nonce: b.Nonce, Proof: StepUpProofWire{Kind: "device", WriterID: a.device.WriterID,
			Sig: b64(a.device.SignDAK(t, msg)), Verifier: b64(a.s)}}, nonce
	}
	deletion := func(nonce []byte) string {
		msg, err := keyproto.DeletionMessage(nonce, mustUUID(t, a.user))
		if err != nil {
			t.Fatal(err)
		}
		return b64(ed25519.Sign(a.device.DWK, msg))
	}
	// Without a step-up, and with a signature over another nonce: refused, and
	// the account stays.
	wantStatus(t, h.req("DELETE", "/api/v1/account", a.token, DeleteAccountRequest{StepUp: nil, WriterID: a.device.WriterID,
		Sig: deletion(make([]byte, 32))}), http.StatusForbidden)
	su, _ := deviceStepUp()
	w = h.req("DELETE", "/api/v1/account", a.token, DeleteAccountRequest{StepUp: su, WriterID: a.device.WriterID,
		Sig: deletion(make([]byte, 32))})
	wantStatus(t, w, http.StatusForbidden)
	if w.Body.String() != `{"error":"step_up_failed"}` {
		t.Fatalf("a wrong deletion signature answered %s", w.Body)
	}
	if !h.accountExists(t, mustUUID(t, a.user)) {
		t.Fatal("a refused deletion deleted the account")
	}
	su, nonce := deviceStepUp()
	wantStatus(t, h.req("DELETE", "/api/v1/account", a.token, DeleteAccountRequest{StepUp: su, WriterID: a.device.WriterID,
		Sig: deletion(nonce)}), http.StatusNoContent)
	if h.accountExists(t, mustUUID(t, a.user)) {
		t.Fatal("the account survived its deletion")
	}
	for _, tok := range []string{a.token, second.SessionToken} {
		w = h.req("GET", "/api/v1/account", tok, nil)
		wantStatus(t, w, http.StatusGone)
		if w.Body.String() != `{"error":"account_deleted"}` {
			t.Fatalf("after deletion: %s", w.Body)
		}
	}
	if h.countAPNs(mustUUID(t, a.user)) != 0 {
		t.Fatal("the APNs token outlived the account")
	}
	// The goodbye (spec 02 §15.2 step 4) is queued in the purge, sent, and
	// then nothing in the email log holds the address any more.
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(mailTexts(fake.To(a.addr)), "Your Hasala account and its data were deleted") {
		t.Fatal("no goodbye email was sent")
	}
	var left int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE recipient = $1`, a.addr).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatalf("%d email log rows still hold the deleted account's address", left)
	}
}

// #41 with a passkey step-up: a UV assertion over the account.delete
// challenge and the writer's signature over the same nonce. A frozen account
// is refused (unfreeze first).
func TestAPasskeyAccountDeletesItselfWithAStepUp(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	su := k.stepUp(k.token, keyproto.ActionAccountDelete, []byte(k.user.String()))
	nonce, _ := base64.RawURLEncoding.DecodeString(su.Nonce)
	msg, err := keyproto.DeletionMessage(nonce, k.user)
	if err != nil {
		t.Fatal(err)
	}
	body := DeleteAccountRequest{StepUp: su, WriterID: k.device.WriterID, Sig: b64(ed25519.Sign(k.device.DWK, msg))}
	// Not mixed with ledgerd's form, which is gone.
	wantStatus(t, h.req("DELETE", "/api/v1/account", k.token, map[string]any{"step_up": su, "writer_id": k.device.WriterID,
		"sig": body.Sig, "nonce": b64(nonce)}), http.StatusBadRequest)
	if _, err := h.pool.Exec(bg, `UPDATE users SET frozen_at = now(), freeze_trigger_at = now(), frozen_by = 'holder'
		WHERE id = $1`, k.user); err != nil {
		t.Fatal(err)
	}
	wantError(t, h.req("DELETE", "/api/v1/account", k.token, body), "account_frozen")
	if _, err := h.pool.Exec(bg, `UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL
		WHERE id = $1`, k.user); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, h.req("DELETE", "/api/v1/account", k.token, body), http.StatusNoContent)
	if h.accountExists(t, k.user) {
		t.Fatal("the account survived its deletion")
	}
}
