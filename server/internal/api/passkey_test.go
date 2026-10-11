package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// passkeys attaches a relying party to this harness and rebuilds the router, so
// the six routes are mounted. It is opt-in for the same reason the server makes
// them conditional: a deployment with no rp_id does not serve them at all, and
// every other test in this package must keep exercising that server.
func (h *harness) passkeys() *harness {
	h.t.Helper()
	p, err := auth.NewPasskeys(h.pool, authtest.RPID, authtest.RPDisplayName, []string{authtest.RPOrigin})
	if err != nil {
		h.t.Fatal(err)
	}
	h.srv.Passkeys = p
	h.h = h.srv.Handler()
	return h
}

// beginCreate runs a begin step that answers with creation options.
func (h *harness) beginCreate(path, token string, body any) (string, *protocol.CredentialCreation) {
	h.t.Helper()
	w := h.req("POST", path, token, body)
	wantStatus(h.t, w, http.StatusOK)
	out := decodeJSON[PasskeyBeginResponse](h.t, w)
	if out.CeremonyID == "" {
		h.t.Fatalf("%s returned no ceremony id: %s", path, w.Body.String())
	}
	var opts protocol.CredentialCreation
	if err := json.Unmarshal(out.Options, &opts); err != nil {
		h.t.Fatalf("creation options from %s: %v (%s)", path, err, out.Options)
	}
	return out.CeremonyID, &opts
}

func (h *harness) beginAssert(path, token string) (string, *protocol.CredentialAssertion) {
	h.t.Helper()
	w := h.req("POST", path, token, map[string]any{})
	wantStatus(h.t, w, http.StatusOK)
	out := decodeJSON[PasskeyBeginResponse](h.t, w)
	var opts protocol.CredentialAssertion
	if err := json.Unmarshal(out.Options, &opts); err != nil {
		h.t.Fatalf("assertion options from %s: %v (%s)", path, err, out.Options)
	}
	return out.CeremonyID, &opts
}

// register runs a whole sign-up over HTTP and returns the session it minted.
func (h *harness) register(code string) (*authtest.Authenticator, SessionResponse) {
	h.t.Helper()
	id, opts := h.beginCreate("/api/v1/auth/passkey/register/begin", "",
		PasskeyRegisterBeginRequest{SignupID: code, AuthorityPubkey: b64(authtest.AuthorityPub(h.t))})
	a := authtest.New(h.t)
	w := h.req("POST", "/api/v1/auth/passkey/register/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: a.Create(h.t, opts),
	})
	wantStatus(h.t, w, http.StatusCreated)
	return a, decodeJSON[SessionResponse](h.t, w)
}

// ---------------------------------------------------------------------------
// Mounting
// ---------------------------------------------------------------------------

func TestPasskeyRoutesAreNotMountedWithoutARelyingParty(t *testing.T) {
	h := newHarness(t)
	for _, path := range []string{
		"/api/v1/auth/passkey/register/begin",
		"/api/v1/auth/passkey/register/finish",
		"/api/v1/auth/passkey/login/begin",
		"/api/v1/auth/passkey/login/finish",
		"/api/v1/auth/passkey/add/begin",
		"/api/v1/auth/passkey/add/finish",
	} {
		w := h.req("POST", path, "", map[string]any{})
		wantStatus(t, w, http.StatusNotFound)
		if got := w.Body.String(); got != `{"error":"not_found","detail":"no such endpoint"}` {
			t.Fatalf("%s answered %s, want the API 404 rather than an HTML fallthrough", path, got)
		}
	}
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

func TestPasskeyRegistrationOverHTTPMintsASessionForANewAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	_, out := h.register(h.invite("passkey beta"))

	if out.SessionToken == "" || out.UserID == "" {
		t.Fatalf("register/finish returned %+v", out)
	}
	if _, err := uuid.Parse(out.UserID); err != nil {
		t.Fatalf("user_id %q is not a uuid", out.UserID)
	}
	if n := h.countUsers(t); n != 1 {
		t.Fatalf("%d accounts, want 1", n)
	}
	// The session is a real one and the account is whole (counter row, ingest
	// writer), which is the same thing the ID-token exchange's test asserts.
	wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", out.SessionToken, nil), http.StatusOK)
}

// register/begin needs a signup that an invite opened and an address proved
// (spec 02 #3): an unknown one is the uniform code_rejected.
func TestPasskeyRegistrationWithoutASignupIsRefused(t *testing.T) {
	h := newHarness(t).passkeys()
	w := h.req("POST", "/api/v1/auth/passkey/register/begin", "",
		PasskeyRegisterBeginRequest{SignupID: "NOTASIGNUP", AuthorityPubkey: b64(authtest.AuthorityPub(h.t))})
	wantStatus(t, w, http.StatusForbidden)
	if got := w.Body.String(); got != `{"error":"code_rejected"}` {
		t.Fatalf("body = %s, want the uniform code_rejected answer", got)
	}
	if n := h.countUsers(t); n != 0 {
		t.Fatalf("%d accounts created without an invite", n)
	}
}

func TestPasskeyRegistrationFinishWithAMismatchedCeremonyIsRefused(t *testing.T) {
	h := newHarness(t).passkeys()
	// Two ceremonies begun against two codes; the credential built for one is
	// presented against the other's id.
	idA, optsA := h.beginCreate("/api/v1/auth/passkey/register/begin", "",
		PasskeyRegisterBeginRequest{SignupID: h.invite("a"), AuthorityPubkey: b64(authtest.AuthorityPub(h.t))})
	idB, _ := h.beginCreate("/api/v1/auth/passkey/register/begin", "",
		PasskeyRegisterBeginRequest{SignupID: h.invite("b"), AuthorityPubkey: b64(authtest.AuthorityPub(h.t))})
	if idA == idB {
		t.Fatal("two ceremonies share an id")
	}
	a := authtest.New(t)
	w := h.req("POST", "/api/v1/auth/passkey/register/finish", "", PasskeyFinishRequest{
		CeremonyID: idB, Credential: a.Create(t, optsA),
	})
	// The challenge in ceremony B is not the one the authenticator signed.
	wantStatus(t, w, http.StatusForbidden)
	if n := h.countUsers(t); n != 0 {
		t.Fatalf("%d accounts, want 0", n)
	}
}

func TestPasskeyFinishWithAnUnknownCeremonyIsRefused(t *testing.T) {
	h := newHarness(t).passkeys()
	w := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: "not-a-ceremony", Credential: json.RawMessage(`{}`),
	})
	wantStatus(t, w, http.StatusForbidden)
	if got := w.Body.String(); got != `{"error":"passkey_rejected"}` {
		t.Fatalf("body = %s, want the uniform passkey_rejected (spec 02 §6.3)", got)
	}
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------

func TestPasskeyLoginOverHTTPReturnsASessionForTheSameAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	a, registered := h.register(h.invite("returning"))

	id, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	w := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: a.Assert(t, opts, 5),
	})
	wantStatus(t, w, http.StatusOK)
	out := decodeJSON[SessionResponse](t, w)
	if out.UserID != registered.UserID {
		t.Fatalf("login user_id = %s, registration created %s", out.UserID, registered.UserID)
	}
	if out.SessionToken == registered.SessionToken {
		t.Fatal("login returned the registration's session token instead of a new one")
	}
	wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", out.SessionToken, nil), http.StatusOK)
	if n := h.countUsers(t); n != 1 {
		t.Fatalf("%d accounts, want 1: signing in created one", n)
	}
}

func TestPasskeyLoginBeginNeedsNoSessionAndNamesNobody(t *testing.T) {
	h := newHarness(t).passkeys()
	_, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	if len(opts.Response.AllowedCredentials) != 0 {
		t.Fatal("the login challenge lists credentials; that is an account-enumeration oracle")
	}
	if opts.Response.RelyingPartyID != authtest.RPID {
		t.Fatalf("rpId = %q, want %q", opts.Response.RelyingPartyID, authtest.RPID)
	}
}

// ---------------------------------------------------------------------------
// Adding a passkey
// ---------------------------------------------------------------------------

func TestAddPasskeyNeedsASession(t *testing.T) {
	h := newHarness(t).passkeys()
	for _, path := range []string{
		"/api/v1/auth/passkey/add/begin",
		"/api/v1/auth/passkey/add/finish",
	} {
		w := h.req("POST", path, "", map[string]any{})
		wantStatus(t, w, http.StatusUnauthorized)
		if got := w.Body.String(); got != `{"error":"unauthorized"}` {
			t.Fatalf("%s answered %s", path, got)
		}
	}
}

func TestAddPasskeyStoresASecondCredentialForTheSameAccount(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)

	second, w := k.addFinish(k.token, prfWrap(4))
	wantStatus(t, w, http.StatusCreated)
	out := decodeJSON[PasskeyAddResponse](t, w)
	raw, err := base64.RawURLEncoding.DecodeString(out.CredentialID)
	if err != nil {
		t.Fatalf("credential_id %q is not b64url: %v", out.CredentialID, err)
	}
	if string(raw) != string(second.CredID) {
		t.Fatal("add/finish named a different credential")
	}

	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM webauthn_credentials`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("credentials = %d, want 2", n)
	}
	// The PRF wrap came in the same transaction.
	if got := h.countWraps(k.user); got != 2 {
		t.Fatalf("wraps = %d, want the bootstrap's and the new credential's", got)
	}
	// And it signs in as the same account.
	lid, lopts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	lw := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: lid, Credential: second.Assert(t, lopts, k.counter.Add(1)),
	})
	wantStatus(t, lw, http.StatusOK)
	if got := decodeJSON[SessionResponse](t, lw).UserID; got != k.user.String() {
		t.Fatalf("the added credential signed in as %s, want %s", got, k.user)
	}
}

// TestAddPasskeyNeedsMoreThanASession is the review's blocker over HTTP: a
// stolen session, bound or not, cannot enrol a passkey of its own.
func TestAddPasskeyNeedsMoreThanASession(t *testing.T) {
	h := newHarness(t).passkeys()
	h.srv.PasskeyPerIP = NewLimiter(passkeyPerIPRate, 64, passkeyMaxKeys, h.srv.now)

	// Before bootstrap the session has no writer: 403 writer_unbound, even
	// with a genuine passkey.add step-up.
	pre := h.onboard(false)
	w := h.req("POST", "/api/v1/auth/passkey/add/begin", pre.token,
		PasskeyAddBeginRequest{StepUp: pre.stepUp(pre.token, keyproto.ActionPasskeyAdd)})
	wantStatus(t, w, http.StatusForbidden)
	if got := decodeJSON[errorBody](t, w).Error; got != "writer_unbound" {
		t.Fatalf("add/begin on an unbound session: %q, want writer_unbound", got)
	}

	k := h.onboard(true)
	// A bound session with no step-up.
	w = h.req("POST", "/api/v1/auth/passkey/add/begin", k.token, map[string]any{})
	wantStatus(t, w, http.StatusForbidden)
	if got := decodeJSON[errorBody](t, w).Error; got != "step_up_required" {
		t.Fatalf("add/begin with no step-up: %q, want step_up_required", got)
	}
	// A step-up proved by a passkey that is not the account's.
	su := k.stepUpWith(k.token, authtest.New(t), keyproto.ActionPasskeyAdd)
	w = h.req("POST", "/api/v1/auth/passkey/add/begin", k.token, PasskeyAddBeginRequest{StepUp: su})
	wantStatus(t, w, http.StatusForbidden)
	if got := decodeJSON[errorBody](t, w).Error; got != "step_up_failed" {
		t.Fatalf("add/begin proved by a stranger's passkey: %q, want step_up_failed", got)
	}

	// A good step-up, but add/finish signed by a DWK the account never
	// registered: 400 bad_signature, nothing stored (R-01).
	su = k.stepUp(k.token, keyproto.ActionPasskeyAdd)
	id, opts := h.beginCreate("/api/v1/auth/passkey/add/begin", k.token, PasskeyAddBeginRequest{StepUp: su})
	a := authtest.New(t)
	resp := a.Create(t, opts)
	nonce, _ := base64.RawURLEncoding.DecodeString(su.Nonce)
	m, _ := keyproto.PasskeyAddMessage(nonce, a.LastClientDataJSON, a.LastAttestationObject, nil)
	w = h.req("POST", "/api/v1/auth/passkey/add/finish", k.token, PasskeyAddFinishRequest{
		CeremonyID: id, Credential: resp, DWKSig: b64(ed25519.Sign(authtest.NewDevice(t).DWK, m)),
	})
	wantStatus(t, w, http.StatusBadRequest)
	if got := decodeJSON[errorBody](t, w).Error; got != "bad_signature" {
		t.Fatalf("add/finish under a stranger's DWK: %q, want bad_signature", got)
	}
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, k.user).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("credentials = %d after refused adds, want 1", n)
	}
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

func TestEveryPasskeyRouteIsRateLimited(t *testing.T) {
	h := newHarness(t).passkeys()
	// A limiter with no refill, so the budget is exactly the burst.
	h.srv.PasskeyPerIP = NewLimiter(0, 1, 16, h.srv.now)
	h.srv.PasskeyGlobal = NewLimiter(0, 1000, 1, h.srv.now)
	h.h = h.srv.Handler()
	tok := h.session(h.user("limited"))

	for _, path := range []string{
		"/api/v1/auth/passkey/register/begin",
		"/api/v1/auth/passkey/register/finish",
		"/api/v1/auth/passkey/login/begin",
		"/api/v1/auth/passkey/login/finish",
		"/api/v1/auth/passkey/add/begin",
		"/api/v1/auth/passkey/add/finish",
	} {
		h.srv.PasskeyPerIP = NewLimiter(0, 1, 16, h.srv.now)
		h.h = h.srv.Handler()
		// The first call spends the only token; whether it succeeds or is
		// refused for some other reason is irrelevant.
		h.req("POST", path, tok, map[string]any{})
		w := h.req("POST", path, tok, map[string]any{})
		wantStatus(t, w, http.StatusTooManyRequests)
		if got := decodeJSON[errorBody](t, w).Error; got != "rate_limited" {
			t.Fatalf("%s: error = %q, want rate_limited", path, got)
		}
	}
}

func TestThePasskeyLimiterIsCheckedBeforeTheSession(t *testing.T) {
	// Same ordering argument handleExchange makes: a limiter that runs after
	// authentication does not bound what an unauthenticated caller can spend.
	h := newHarness(t).passkeys()
	// NewLimiter floors burst at 1, so the budget is one request.
	h.srv.PasskeyPerIP = NewLimiter(0, 1, 16, h.srv.now)
	h.h = h.srv.Handler()
	// Both calls carry NO session at all. The first spends the only token and is
	// refused as unauthorized; the second must be refused as rate limited, which
	// is only true if the limiter ran first.
	wantStatus(t, h.req("POST", "/api/v1/auth/passkey/add/begin", "", map[string]any{}),
		http.StatusUnauthorized)
	wantStatus(t, h.req("POST", "/api/v1/auth/passkey/add/begin", "", map[string]any{}),
		http.StatusTooManyRequests)
}
