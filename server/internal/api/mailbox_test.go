package api

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/mailbox"
	"github.com/salehtl/hasala/server/internal/mailbox/fakegoogle"
)

// The mailbox harness: the shared harness plus a broker pointed at a
// fakegoogle instance. The routes are only mounted once Server.Mailbox is set,
// so it builds its own handler — the addrHarness pattern.
type mailboxHarness struct {
	*harness
	google *fakegoogle.Server
	broker *MailboxBroker
}

const testRedirectURI = "https://app.example.test" + mailboxCallbackPath

func newMailboxHarness(t *testing.T) *mailboxHarness {
	t.Helper()
	h := newHarness(t)
	fg := fakegoogle.New()
	ts := httptest.NewServer(fg)
	t.Cleanup(ts.Close)

	mh := &mailboxHarness{harness: h, google: fg}
	mh.broker = &MailboxBroker{
		States: &mailbox.States{DB: h.pool},
		Google: &mailbox.Google{
			ClientID:     "client-id.apps.googleusercontent.com",
			ClientSecret: "client-secret",
			AuthURL:      ts.URL + "/auth",
			TokenURL:     ts.URL + "/token",
			RevokeURL:    ts.URL + "/revoke",
		},
		Grants:      &mailbox.Grants{DB: h.pool},
		RedirectURI: testRedirectURI,
	}
	h.srv.Mailbox = mh.broker
	// Budgets no test trips by accident; the two tests that are ABOUT the
	// limiter install their own.
	h.srv.MailboxPerIP = NewLimiter(0, 1<<20, 16, h.srv.now)
	h.srv.MailboxGlobal = NewLimiter(0, 1<<20, 1, h.srv.now)
	h.h = h.srv.Handler()
	return mh
}

// begin runs POST /oauth/begin and returns the `state` from the auth URL.
func (h *mailboxHarness) begin(t *testing.T, session string) string {
	t.Helper()
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/begin", session, nil)
	wantStatus(t, rec, http.StatusOK)
	u, err := url.Parse(decodeJSON[MailboxBeginResponse](t, rec).AuthURL)
	if err != nil {
		t.Fatalf("auth_url is not a URL: %v", err)
	}
	state := u.Query().Get("state")
	if state == "" {
		t.Fatalf("auth_url carries no state: %s", u)
	}
	return state
}

// callback runs the Google redirect and returns the claim code out of the
// 303's Location.
func (h *mailboxHarness) callback(t *testing.T, state string) string {
	t.Helper()
	rec := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=auth-code&state="+
		url.QueryEscape(state), "", nil)
	wantStatus(t, rec, http.StatusSeeOther)
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location is not a URL: %v", err)
	}
	if loc.Path != "/mailbox-callback.html" {
		t.Fatalf("Location path = %q, want /mailbox-callback.html", loc.Path)
	}
	claim := loc.Query().Get("claim")
	if claim == "" {
		t.Fatalf("Location carries no claim code: %s", loc)
	}
	return claim
}

// connect walks the whole ceremony and returns the refresh token the client
// keeps.
func (h *mailboxHarness) connect(t *testing.T, session string) string {
	t.Helper()
	claim := h.callback(t, h.begin(t, session))
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantStatus(t, rec, http.StatusOK)
	out := decodeJSON[MailboxClaimResponse](t, rec)
	if out.RefreshToken == "" {
		t.Fatal("the claim returned no refresh token")
	}
	return out.RefreshToken
}

func (h *mailboxHarness) storedDigest(t *testing.T, u uuid.UUID) []byte {
	t.Helper()
	var digest []byte
	err := h.pool.QueryRow(bg,
		`SELECT refresh_token_hash FROM mailbox_grants WHERE user_id = $1`, u).Scan(&digest)
	if err != nil {
		t.Fatalf("no grant row for %s: %v", u, err)
	}
	return digest
}

func (h *mailboxHarness) grantCount(t *testing.T, u uuid.UUID) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_grants WHERE user_id = $1`, u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// ---------------------------------------------------------------------------
// The ceremony
// ---------------------------------------------------------------------------

// The whole connect ceremony, end to end: begin mints a state, the callback
// exchanges the code and hands back a single-use claim code, the claim binds
// the grant to the DIGEST of the refresh token, and the resulting token
// refreshes.
func TestTheMailboxConnectCeremonyEndToEnd(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-happy")
	session := h.session(u)

	state := h.begin(t, session)

	// The state row exists and is bound to this user before the callback.
	var states int
	if err := h.pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_oauth_states WHERE user_id = $1`, u).Scan(&states); err != nil {
		t.Fatal(err)
	}
	if states != 1 {
		t.Fatalf("begin wrote %d state rows, want 1", states)
	}

	claim := h.callback(t, state)

	// Google saw an authorization_code exchange carrying the client secret,
	// the PKCE verifier and the SAME redirect URI the auth URL was built with.
	if len(h.google.TokenRequests) != 1 {
		t.Fatalf("google saw %d token requests, want 1", len(h.google.TokenRequests))
	}
	form := h.google.TokenRequests[0]
	if got := form.Get("grant_type"); got != "authorization_code" {
		t.Fatalf("grant_type = %q", got)
	}
	if got := form.Get("redirect_uri"); got != testRedirectURI {
		t.Fatalf("redirect_uri = %q, want %q", got, testRedirectURI)
	}
	if form.Get("code_verifier") == "" {
		t.Fatal("the exchange carried no PKCE verifier")
	}
	if got := form.Get("client_secret"); got != "client-secret" {
		t.Fatalf("client_secret = %q", got)
	}

	// The state row is spent by the callback: it is single-use.
	if err := h.pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_oauth_states WHERE user_id = $1`, u).Scan(&states); err != nil {
		t.Fatal(err)
	}
	if states != 0 {
		t.Fatalf("the callback left %d state rows behind, want 0", states)
	}

	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantStatus(t, rec, http.StatusOK)
	claimed := decodeJSON[MailboxClaimResponse](t, rec)
	if claimed.RefreshToken != fakegoogle.DefaultRefreshToken ||
		claimed.AccessToken != fakegoogle.DefaultAccessToken ||
		claimed.IDToken != fakegoogle.DefaultIDToken {
		t.Fatalf("the claim did not hand back Google's tokens: %+v", claimed)
	}

	// The grant row holds the DIGEST and never the token.
	digest := h.storedDigest(t, u)
	want := sha256.Sum256([]byte(claimed.RefreshToken))
	if string(digest) != string(want[:]) {
		t.Fatalf("stored digest %x, want sha256(refresh) %x", digest, want)
	}
	if strings.Contains(string(digest), claimed.RefreshToken) {
		t.Fatal("the stored value contains the refresh token itself")
	}

	// GET /grant reports it.
	rec = h.req(http.MethodGet, "/api/v1/mailbox/grant", session, nil)
	wantStatus(t, rec, http.StatusOK)
	grant := decodeJSON[MailboxGrantResponse](t, rec)
	if grant.Provider != mailbox.ProviderGmail || grant.Status != mailbox.GrantStatusActive {
		t.Fatalf("grant = %+v", grant)
	}
	if grant.CreatedAt.IsZero() {
		t.Fatal("grant.created_at is zero")
	}

	// And the token the client kept refreshes.
	rec = h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: claimed.RefreshToken})
	wantStatus(t, rec, http.StatusOK)
	tok := decodeJSON[MailboxTokenResponse](t, rec)
	if tok.AccessToken != fakegoogle.DefaultAccessToken || tok.ExpiresIn != fakegoogle.DefaultExpiresIn {
		t.Fatalf("token = %+v", tok)
	}
}

// The auth URL is Google's consent URL for THIS ceremony: the challenge in it
// is the S256 of the verifier the callback later replays, which is the only
// thing that proves begin and callback are talking about one state row.
func TestTheAuthURLCarriesThisCeremonysPKCEChallenge(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-pkce"))

	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/begin", session, nil)
	wantStatus(t, rec, http.StatusOK)
	u, err := url.Parse(decodeJSON[MailboxBeginResponse](t, rec).AuthURL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if got := q.Get("code_challenge_method"); got != "S256" {
		t.Fatalf("code_challenge_method = %q", got)
	}
	if got := q.Get("redirect_uri"); got != testRedirectURI {
		t.Fatalf("redirect_uri = %q, want %q", got, testRedirectURI)
	}
	challenge := q.Get("code_challenge")

	h.callback(t, q.Get("state"))
	verifier := h.google.TokenRequests[0].Get("code_verifier")
	if got := mailbox.PKCEChallengeS256(verifier); got != challenge {
		t.Fatalf("the exchanged verifier hashes to %q, but the auth URL offered %q", got, challenge)
	}
}

// Two ceremonies never share a state token or a claim code.
func TestEachCeremonyGetsFreshSecrets(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-fresh"))

	s1, s2 := h.begin(t, session), h.begin(t, session)
	if s1 == s2 {
		t.Fatal("two begins minted the same state token")
	}
	if c1, c2 := h.callback(t, s1), h.callback(t, s2); c1 == c2 {
		t.Fatal("two callbacks minted the same claim code")
	}
}

// The poll path: the opener collects its OWN ceremony's tokens with an empty
// claim code — the resilient path when the popup could not hand the code back
// (a COOP-severed BroadcastChannel, a stale worker mis-serving the callback
// page). Before the callback completes there is nothing to collect (204); after
// it, exactly one poll returns the tokens and records the grant; another account
// never collects it; and it is single-use.
func TestTheClaimPollCollectsBySession(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-poll")
	session := h.session(u)

	// Nothing in flight: a poll is 204 (poll on), never a refusal.
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session, MailboxClaimRequest{})
	wantStatus(t, rec, http.StatusNoContent)

	// Begin + callback, but never use the claim code the popup was handed.
	h.callback(t, h.begin(t, session))

	// A different account's poll collects nothing.
	other := h.user("mailbox-poll-other")
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", h.session(other), MailboxClaimRequest{})
	wantStatus(t, rec, http.StatusNoContent)

	// The account that began the ceremony collects its tokens by session.
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session, MailboxClaimRequest{})
	wantStatus(t, rec, http.StatusOK)
	claimed := decodeJSON[MailboxClaimResponse](t, rec)
	if claimed.RefreshToken != fakegoogle.DefaultRefreshToken {
		t.Fatalf("the poll did not hand back the refresh token: %+v", claimed)
	}
	if h.grantCount(t, u) != 1 {
		t.Fatal("the poll did not record the grant")
	}

	// Single-use: a second poll finds nothing.
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session, MailboxClaimRequest{})
	wantStatus(t, rec, http.StatusNoContent)
}

// §2.1: the claim POST binds the SESSION user to the state row's user. A
// second account holding the claim code gets the one refusal and no tokens.
func TestAClaimIsBoundToTheSessionThatBeganIt(t *testing.T) {
	h := newMailboxHarness(t)
	alice, bob := h.user("mailbox-alice"), h.user("mailbox-bob")
	aliceSession, bobSession := h.session(alice), h.session(bob)

	claim := h.callback(t, h.begin(t, aliceSession))

	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", bobSession,
		MailboxClaimRequest{ClaimCode: claim})
	wantMailboxRefusal(t, rec)
	if n := h.grantCount(t, bob); n != 0 {
		t.Fatalf("bob got %d grant rows out of alice's ceremony", n)
	}
	if n := h.grantCount(t, alice); n != 0 {
		t.Fatalf("alice got %d grant rows from a claim she never made", n)
	}

	// And the right session succeeds — the check is a binding, not a wall.
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", aliceSession,
		MailboxClaimRequest{ClaimCode: claim})
	if rec.Code == http.StatusOK {
		t.Fatal("a claim code spent by the wrong session must not still be claimable")
	}

	// A fresh ceremony by alice does complete.
	if got := h.connect(t, aliceSession); got != fakegoogle.DefaultRefreshToken {
		t.Fatalf("alice's own ceremony returned %q", got)
	}
	if n := h.grantCount(t, alice); n != 1 {
		t.Fatalf("alice has %d grant rows after connecting, want 1", n)
	}
}

// A claim code is spent by the first POST that presents it, and dies with its
// TTL. Both collapse to the one refusal.
func TestAClaimCodeIsSingleUseAndExpires(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-single-use"))

	claim := h.callback(t, h.begin(t, session))
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantStatus(t, rec, http.StatusOK)
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantMailboxRefusal(t, rec)

	// TTL: a claim code five minutes and a second old is gone.
	now := time.Now()
	h.srv.Now = func() time.Time { return now }
	h.h = h.srv.Handler()
	claim = h.callback(t, h.begin(t, session))
	now = now.Add(mailboxClaimTTL + time.Second)
	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantMailboxRefusal(t, rec)
}

// The in-memory claim map is BOUNDED. An attacker driving begin/callback
// cycles must not grow this server's memory without limit, and the entries
// that are already in flight must survive the pressure.
func TestTheClaimMapIsBounded(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-bounded"))
	h.broker.MaxClaims = 2

	first := h.callback(t, h.begin(t, session))
	second := h.callback(t, h.begin(t, session))

	// The third callback finds the map full. It is refused as infrastructure
	// trouble — never the credential refusal, and never by evicting a ceremony
	// already in flight.
	state := h.begin(t, session)
	rec := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=auth-code&state="+
		url.QueryEscape(state), "", nil)
	wantStatus(t, rec, http.StatusServiceUnavailable)

	for _, claim := range []string{first, second} {
		rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
			MailboxClaimRequest{ClaimCode: claim})
		wantStatus(t, rec, http.StatusOK)
	}
}

// Carry-forward B (Task 3 review, Minor 6): Google answering the exchange
// with NO refresh token must never reach Grants.Upsert, or the grant pins to
// sha256("") — a globally known digest — and the account reads as connected
// while holding nothing.
func TestAClaimWithNoRefreshTokenFromGoogleIsRefused(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-no-refresh")
	session := h.session(u)
	h.google.RefreshToken = ""

	claim := h.callback(t, h.begin(t, session))
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantMailboxRefusal(t, rec)

	if n := h.grantCount(t, u); n != 0 {
		t.Fatalf("a grant row was written for an empty refresh token (%d rows)", n)
	}
	// The specific shape that would have been written.
	empty := sha256.Sum256(nil)
	var found int
	if err := h.pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_grants WHERE refresh_token_hash = $1`, empty[:]).Scan(&found); err != nil {
		t.Fatal(err)
	}
	if found != 0 {
		t.Fatalf("%d grant(s) pinned to sha256(\"\")", found)
	}
}

// ---------------------------------------------------------------------------
// The token and revoke routes
// ---------------------------------------------------------------------------

// D9's holdership rotation at the HTTP boundary: reconnecting rotates the
// digest, and the superseded device's token stops brokering — with the one
// refusal, which says nothing about why.
func TestASupersededRefreshTokenIsRefused(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-superseded")
	session := h.session(u)

	old := h.connect(t, session)
	h.google.RefreshToken = "second-refresh-token"
	fresh := h.connect(t, session)
	if old == fresh {
		t.Fatal("the second ceremony returned the same token; the test proves nothing")
	}

	rec := h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: old})
	wantMailboxRefusal(t, rec)

	rec = h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: fresh})
	wantStatus(t, rec, http.StatusOK)

	if n := h.grantCount(t, u); n != 1 {
		t.Fatalf("a reconnect left %d grant rows, want 1", n)
	}
}

// D10: a Testing-status refresh token dies after seven days. Google says
// invalid_grant, the grant flips to reconnect_required so the product can ask
// for a reconnect, and the caller gets the one refusal.
func TestGoogleInvalidGrantFlipsTheGrantToReconnectRequired(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-dead-token")
	session := h.session(u)
	refresh := h.connect(t, session)

	h.google.InvalidGrant = true
	rec := h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: refresh})
	wantMailboxRefusal(t, rec)

	rec = h.req(http.MethodGet, "/api/v1/mailbox/grant", session, nil)
	wantStatus(t, rec, http.StatusOK)
	if got := decodeJSON[MailboxGrantResponse](t, rec).Status; got != mailbox.GrantStatusReconnectRequired {
		t.Fatalf("status = %q, want %q", got, mailbox.GrantStatusReconnectRequired)
	}
	// The row is kept, not deleted: mailbox_senders' allowlist survives a
	// reconnect.
	if n := h.grantCount(t, u); n != 1 {
		t.Fatalf("the grant row was deleted (%d rows); a reconnect must not lose the sender list", n)
	}
}

func TestRevokeTellsGoogleAndDeletesTheGrant(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-revoke")
	session := h.session(u)
	refresh := h.connect(t, session)

	rec := h.req(http.MethodPost, "/api/v1/mailbox/revoke", session,
		MailboxRevokeRequest{RefreshToken: refresh})
	wantStatus(t, rec, http.StatusNoContent)
	if len(h.google.RevokeRequests) != 1 {
		t.Fatalf("google saw %d revoke requests, want 1", len(h.google.RevokeRequests))
	}
	if got := h.google.RevokeRequests[0].Get("token"); got != refresh {
		t.Fatalf("revoked token = %q, want the presented one", got)
	}
	if n := h.grantCount(t, u); n != 0 {
		t.Fatalf("revoke left %d grant rows", n)
	}
}

// Carry-forward C (Task 3 review): a token Google no longer knows answers
// invalid_grant. That is a token that is already revoked, so the disconnect
// must still succeed and still delete the row — otherwise a user whose token
// expired can never disconnect.
func TestRevokingAnAlreadyDeadTokenStillDeletesTheGrant(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-dead-revoke")
	session := h.session(u)
	refresh := h.connect(t, session)

	h.google.InvalidGrant = true
	rec := h.req(http.MethodPost, "/api/v1/mailbox/revoke", session,
		MailboxRevokeRequest{RefreshToken: refresh})
	wantStatus(t, rec, http.StatusNoContent)
	if n := h.grantCount(t, u); n != 0 {
		t.Fatalf("a dead token could not be disconnected: %d grant rows remain", n)
	}
}

func TestGrantIsAbsentUntilConnectedAndDeletableAfterwards(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-grant-lifecycle")
	session := h.session(u)

	// Not connected is not an error, and it is NOT the credential refusal:
	// grant state is a fact about the caller's own account.
	rec := h.req(http.MethodGet, "/api/v1/mailbox/grant", session, nil)
	wantStatus(t, rec, http.StatusNotFound)
	if got := decodeJSON[errorBody](t, rec).Error; got != "no_grant" {
		t.Fatalf("error = %q, want no_grant", got)
	}

	h.connect(t, session)
	rec = h.req(http.MethodDelete, "/api/v1/mailbox/grant", session, nil)
	wantStatus(t, rec, http.StatusNoContent)
	if n := h.grantCount(t, u); n != 0 {
		t.Fatalf("DELETE /grant left %d rows", n)
	}
	// It says nothing to Google — that is POST /revoke's job, and it needs a
	// token this route is not given.
	if len(h.google.RevokeRequests) != 0 {
		t.Fatal("DELETE /grant talked to Google")
	}
}

func (h *mailboxHarness) senderCount(t *testing.T, u uuid.UUID) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_senders WHERE user_id = $1`, u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func (h *mailboxHarness) addSender(t *testing.T, session, domain string) {
	t.Helper()
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/senders", session,
		MailboxSenderRequest{Domain: domain}), http.StatusNoContent)
}

// Deletion hygiene, both disconnect routes. The sender allowlist is the user's
// bank domains — mail metadata — and a DISCONNECT is not a reconnect: the list
// survives a status flip (TestGoogleRefusingTheRefreshTokenFlipsTheGrant) and
// must not survive this. The sweep is inside mailbox.Grants.Delete, so it is
// one transaction and a client that closes its tab mid-disconnect cannot leave
// it half done.
func TestDisconnectSweepsTheSenderAllowlist(t *testing.T) {
	for _, tc := range []struct {
		name   string
		method string
		path   string
	}{
		{"DELETE /grant", http.MethodDelete, "/api/v1/mailbox/grant"},
		{"POST /revoke", http.MethodPost, "/api/v1/mailbox/revoke"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newMailboxHarness(t)
			u := h.user("mailbox-disconnect-senders")
			session := h.session(u)
			refresh := h.connect(t, session)
			h.addSender(t, session, "dib.ae")
			h.addSender(t, session, "emiratesnbd.com")
			if n := h.senderCount(t, u); n != 2 {
				t.Fatalf("setup: %d sender rows, want 2", n)
			}

			var body any
			if tc.method == http.MethodPost {
				body = MailboxRevokeRequest{RefreshToken: refresh}
			}
			wantStatus(t, h.req(tc.method, tc.path, session, body), http.StatusNoContent)

			if n := h.grantCount(t, u); n != 0 {
				t.Fatalf("disconnect left %d grant rows", n)
			}
			if n := h.senderCount(t, u); n != 0 {
				t.Fatalf("disconnect left %d sender rows behind; the bank domains are mail metadata", n)
			}
		})
	}
}

// The complement: a failed revoke changes nothing at all. The grant already
// had to survive so a retry can finish the job (TestAFailedRevokeKeepsTheGrant
// covers that half); the allowlist must survive with it, or a transient Google
// outage silently costs the user their sender list.
func TestAFailedRevokeKeepsTheSenderAllowlist(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-failed-revoke-senders")
	session := h.session(u)
	refresh := h.connect(t, session)
	h.addSender(t, session, "dib.ae")

	h.broker.Google.RevokeURL = "http://127.0.0.1:1/revoke"
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/revoke", session,
		MailboxRevokeRequest{RefreshToken: refresh}), http.StatusServiceUnavailable)

	if n := h.senderCount(t, u); n != 1 {
		t.Fatalf("a failed revoke swept the sender allowlist (%d rows left)", n)
	}
}

// ---------------------------------------------------------------------------
// The one refusal
// ---------------------------------------------------------------------------

func wantMailboxRefusal(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, want %d (body %s)", rec.Code, http.StatusForbidden, rec.Body.String())
	}
	if got := decodeJSON[errorBody](t, rec).Error; got != "mailbox_refused" {
		t.Fatalf("error = %q, want mailbox_refused", got)
	}
}

// Every credential-shaped refusal is ONE answer, byte for byte. Telling "wrong
// digest" from "no grant" from "wrong user" from "unknown claim code" apart in
// a RESPONSE is D3a's oracle over who holds what.
//
// This is the test Step 3's mutation targets: give any one of these branches a
// body of its own and this fails.
func TestEveryMailboxCredentialRefusalIsByteIdentical(t *testing.T) {
	h := newMailboxHarness(t)
	alice := h.user("refusal-alice")
	aliceSession := h.session(alice)
	bobSession := h.session(h.user("refusal-bob"))

	// A live grant for alice, so "wrong digest" is reachable separately from
	// "no grant at all" (bob's).
	refresh := h.connect(t, aliceSession)

	// A claim code alice minted, presented by bob.
	foreignClaim := h.callback(t, h.begin(t, aliceSession))

	// A ceremony whose exchange yields no refresh token.
	h.google.RefreshToken = ""
	emptyClaim := h.callback(t, h.begin(t, bobSession))
	h.google.RefreshToken = fakegoogle.DefaultRefreshToken

	type call struct {
		name    string
		method  string
		path    string
		session string
		body    any
	}
	calls := []call{
		{"unknown claim code", http.MethodPost, "/api/v1/mailbox/oauth/claim", aliceSession,
			MailboxClaimRequest{ClaimCode: "not-a-claim-code"}},
		{"claim by the wrong session", http.MethodPost, "/api/v1/mailbox/oauth/claim", bobSession,
			MailboxClaimRequest{ClaimCode: foreignClaim}},
		{"claim of a tokenless exchange", http.MethodPost, "/api/v1/mailbox/oauth/claim", bobSession,
			MailboxClaimRequest{ClaimCode: emptyClaim}},
		{"token with a wrong digest", http.MethodPost, "/api/v1/mailbox/token", aliceSession,
			MailboxTokenRequest{RefreshToken: "some-other-token"}},
		{"token with no grant at all", http.MethodPost, "/api/v1/mailbox/token", bobSession,
			MailboxTokenRequest{RefreshToken: refresh}},
		{"token with an empty token", http.MethodPost, "/api/v1/mailbox/token", aliceSession,
			MailboxTokenRequest{RefreshToken: ""}},
		{"revoke with a wrong digest", http.MethodPost, "/api/v1/mailbox/revoke", aliceSession,
			MailboxRevokeRequest{RefreshToken: "some-other-token"}},
		{"revoke with no grant at all", http.MethodPost, "/api/v1/mailbox/revoke", bobSession,
			MailboxRevokeRequest{RefreshToken: refresh}},
	}

	var first *httptest.ResponseRecorder
	var firstName string
	for _, c := range calls {
		rec := h.req(c.method, c.path, c.session, c.body)
		wantMailboxRefusal(t, rec)
		if first == nil {
			first, firstName = rec, c.name
			continue
		}
		if rec.Code != first.Code {
			t.Fatalf("%s: status %d, but %s answered %d", c.name, rec.Code, firstName, first.Code)
		}
		if rec.Body.String() != first.Body.String() {
			t.Fatalf("%s: body %q, but %s answered %q", c.name, rec.Body.String(), firstName,
				first.Body.String())
		}
		if got, want := rec.Header().Get("Content-Type"), first.Header().Get("Content-Type"); got != want {
			t.Fatalf("%s: Content-Type %q, but %s answered %q", c.name, got, firstName, want)
		}
	}
	// And the shared body carries no detail at all: a detail is a place for a
	// reason to leak.
	if got := decodeJSON[errorBody](t, first).Detail; got != "" {
		t.Fatalf("the refusal carries a detail (%q); any variation at all is an oracle", got)
	}
}

// Infrastructure trouble is NOT the credential refusal. Google being
// unreachable must not tell a user their mailbox credential is bad.
func TestGoogleBeingUnreachableIs503AndNotTheRefusal(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-google-down"))
	refresh := h.connect(t, session)

	h.broker.Google.TokenURL = "http://127.0.0.1:1/token" // nothing listens
	rec := h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: refresh})
	wantStatus(t, rec, http.StatusServiceUnavailable)

	h.broker.Google.RevokeURL = "http://127.0.0.1:1/revoke"
	rec = h.req(http.MethodPost, "/api/v1/mailbox/revoke", session,
		MailboxRevokeRequest{RefreshToken: refresh})
	wantStatus(t, rec, http.StatusServiceUnavailable)
	// The grant survives, so a retry can actually revoke at Google rather than
	// leaving a live token nobody can reach.
	if n := h.grantCount(t, h.user("mailbox-google-down")); n != 1 {
		t.Fatalf("a failed revoke deleted the grant (%d rows left)", n)
	}
}

// callbackOver runs a callback that cannot complete and asserts it REDIRECTS to
// the callback page carrying ?error= and no claim — the shape Task 9's popup
// page reacts to. It is the ceremony-over twin of h.callback.
func (h *mailboxHarness) callbackOver(t *testing.T, rawQuery string) {
	t.Helper()
	rec := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?"+rawQuery, "", nil)
	wantStatus(t, rec, http.StatusSeeOther)
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location is not a URL: %v", err)
	}
	if loc.Path != "/mailbox-callback.html" {
		t.Fatalf("Location path = %q, want /mailbox-callback.html", loc.Path)
	}
	if got := loc.Query().Get("error"); got == "" {
		t.Fatalf("the ceremony-over redirect carries no ?error=: %s", loc)
	}
	if got := loc.Query().Get("claim"); got != "" {
		t.Fatalf("a ceremony-over redirect must not carry a claim code, got %q", got)
	}
}

// An unknown, replayed or expired state is not a credential rejection: the
// browser is told this ceremony is over by a redirect to the callback page with
// ?error=, so the popup script can broadcast the outcome to the app that opened
// it (Task 9).
func TestTheCallbackRefusesAnUnknownState(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-bad-state"))

	h.callbackOver(t, "code=x&state=never-minted")

	state := h.begin(t, session)
	h.callback(t, state)
	// Replayed: the row was spent by the first callback.
	h.callbackOver(t, "code=x&state="+url.QueryEscape(state))

	// A consent the user cancelled comes back with ?error= and no code.
	state = h.begin(t, session)
	h.callbackOver(t, "error=access_denied&state="+url.QueryEscape(state))
	// And it spends the state row rather than leaving it for a replay.
	h.callbackOver(t, "code=x&state="+url.QueryEscape(state))
}

// Carry-forward (Task 9 controller decision): a ceremony-over callback must
// redirect to the callback page with ONE fixed ?error= value, not a raw JSON
// body the popup would show and not a per-branch reason. The single value is
// what lets the page broadcast the failure to the opener, and the fixed-ness is
// the same no-oracle discipline the credential refusal keeps.
func TestACeremonyOverCallbackRedirectsWithASingleFixedError(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-error-redirect"))

	// Cancelled consent and a dead authorization code reach two different
	// branches; both must answer with the identical ?error= value.
	s1 := h.begin(t, session)
	rec1 := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?error=access_denied&state="+
		url.QueryEscape(s1), "", nil)
	wantStatus(t, rec1, http.StatusSeeOther)

	// A dead code: fakegoogle answers the exchange with invalid_grant.
	h.google.InvalidGrant = true
	s2 := h.begin(t, session)
	rec2 := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=dead&state="+
		url.QueryEscape(s2), "", nil)
	wantStatus(t, rec2, http.StatusSeeOther)

	e1 := mustLocationQuery(t, rec1).Get("error")
	e2 := mustLocationQuery(t, rec2).Get("error")
	if e1 == "" {
		t.Fatal("the cancelled-consent redirect carries no ?error=")
	}
	if e1 != e2 {
		t.Fatalf("two ceremony-over branches carry different errors: %q vs %q — that is an oracle", e1, e2)
	}
	// The header the claim redirect sets so a secret is never cached is set here
	// too, uniformly.
	if got := rec1.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
}

func mustLocationQuery(t *testing.T, rec *httptest.ResponseRecorder) url.Values {
	t.Helper()
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location is not a URL: %v", err)
	}
	return loc.Query()
}

// ---------------------------------------------------------------------------
// Senders
// ---------------------------------------------------------------------------

func TestMailboxSendersRoundTrip(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-senders"))
	other := h.session(h.user("mailbox-senders-other"))

	rec := h.req(http.MethodGet, "/api/v1/mailbox/senders", session, nil)
	wantStatus(t, rec, http.StatusOK)
	if got := decodeJSON[MailboxSendersResponse](t, rec).Domains; len(got) != 0 {
		t.Fatalf("a fresh account has senders: %v", got)
	}

	for _, d := range []string{"dib.ae", "  ENBD.AE  "} {
		rec = h.req(http.MethodPost, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: d})
		wantStatus(t, rec, http.StatusNoContent)
	}
	// Adding the same domain twice is not an error: a client retrying a
	// request that failed in transit must not see a failure.
	rec = h.req(http.MethodPost, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: "dib.ae"})
	wantStatus(t, rec, http.StatusNoContent)

	rec = h.req(http.MethodGet, "/api/v1/mailbox/senders", session, nil)
	wantStatus(t, rec, http.StatusOK)
	got := decodeJSON[MailboxSendersResponse](t, rec).Domains
	if len(got) != 2 || got[0] != "dib.ae" || got[1] != "enbd.ae" {
		t.Fatalf("domains = %v, want [dib.ae enbd.ae] — normalized and ordered", got)
	}

	// Another account sees none of it.
	rec = h.req(http.MethodGet, "/api/v1/mailbox/senders", other, nil)
	wantStatus(t, rec, http.StatusOK)
	if n := len(decodeJSON[MailboxSendersResponse](t, rec).Domains); n != 0 {
		t.Fatalf("another account sees %d of this user's senders", n)
	}

	// Removal takes the caller's spelling and removes the normalized row.
	rec = h.req(http.MethodDelete, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: "DIB.AE"})
	wantStatus(t, rec, http.StatusNoContent)
	rec = h.req(http.MethodGet, "/api/v1/mailbox/senders", session, nil)
	got = decodeJSON[MailboxSendersResponse](t, rec).Domains
	if len(got) != 1 || got[0] != "enbd.ae" {
		t.Fatalf("domains after the delete = %v", got)
	}
}

func TestMailboxSendersRefuseSomethingThatIsNotAHostname(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-bad-sender"))

	for _, d := range []string{
		"", "  ", "https://dib.ae", "Bank <no-reply@dib.ae>", "no-reply@dib.ae", "dib.ae/path",
		"dib", "-dib.ae", "dib..ae",
		strings.Repeat("a", 64) + ".ae",  // a label past DNS's 63
		strings.Repeat("ab.", 90) + "ae", // a name past DNS's 253
	} {
		rec := h.req(http.MethodPost, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: d})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("POST senders %q: %d, want 400", d, rec.Code)
		}
	}
}

// A forwarder domain is never addable to the mailbox allowlist.
//
// This is the mailbox lane's copy of the rule quarantine.Confirm holds for the
// SMTP allowlist. It bites hardest here: for a hand-forwarded message the
// domain Gmail's Authentication-Results verifies is gmail.com, so the review
// card would otherwise offer one tap that auto-imports every Gmail-signed
// message in the mailbox — permanently, because the op log is append-only.
func TestMailboxSendersRefuseAForwarderDomain(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-forwarder-sender"))

	for _, d := range []string{
		"gmail.com",
		"GMAIL.COM",  // the normalizer runs first, so case cannot slip past
		"google.com", // the SEALING spelling, not just the mailbox one
		"icloud.com", // already in production's table for one user
		"mail.gmail.com" /* a subdomain: the match is permissive */, "  yahoo.com  ",
	} {
		rec := h.req(http.MethodPost, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: d})
		if rec.Code != http.StatusConflict {
			t.Fatalf("POST senders %q: %d, want 409", d, rec.Code)
		}
		if code := decodeJSON[struct {
			Error string `json:"error"`
		}](t, rec).Error; code != "forwarder_domain" {
			t.Fatalf("POST senders %q: error = %q, want forwarder_domain", d, code)
		}
	}

	// Nothing was written by any of them.
	rec := h.req(http.MethodGet, "/api/v1/mailbox/senders", session, nil)
	wantStatus(t, rec, http.StatusOK)
	if got := decodeJSON[MailboxSendersResponse](t, rec).Domains; len(got) != 0 {
		t.Fatalf("a refused forwarder was stored anyway: %v", got)
	}

	// A bank is unaffected — the check must refuse forwarders, not everything.
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/senders", session,
		MailboxSenderRequest{Domain: "dib.ae"}), http.StatusNoContent)
}

// A forwarder row that predates the check — production holds two — must still
// be removable. DELETE carries no forwarder check for exactly this reason.
func TestMailboxSendersRemoveAForwarderRowThatPredatesTheCheck(t *testing.T) {
	h := newMailboxHarness(t)
	u := h.user("mailbox-forwarder-legacy")
	session := h.session(u)

	// Written the way a row from before the check exists: straight into the
	// table, past the handler.
	if _, err := h.srv.Pool.Exec(t.Context(),
		`INSERT INTO mailbox_senders (user_id, domain) VALUES ($1, $2)`, u, "icloud.com"); err != nil {
		t.Fatalf("seed the legacy row: %v", err)
	}
	wantStatus(t, h.req(http.MethodDelete, "/api/v1/mailbox/senders", session,
		MailboxSenderRequest{Domain: "icloud.com"}), http.StatusNoContent)

	rec := h.req(http.MethodGet, "/api/v1/mailbox/senders", session, nil)
	wantStatus(t, rec, http.StatusOK)
	if got := decodeJSON[MailboxSendersResponse](t, rec).Domains; len(got) != 0 {
		t.Fatalf("the legacy forwarder row survived its delete: %v", got)
	}
}

// The list is per-user and bounded: a session must not be able to grow this
// table without limit.
func TestMailboxSendersAreCapped(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-sender-cap"))
	h.broker.MaxSenders = 2

	for _, d := range []string{"a.ae", "b.ae"} {
		wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/senders", session,
			MailboxSenderRequest{Domain: d}), http.StatusNoContent)
	}
	rec := h.req(http.MethodPost, "/api/v1/mailbox/senders", session, MailboxSenderRequest{Domain: "c.ae"})
	wantStatus(t, rec, http.StatusConflict)
	// A domain already on the list is still accepted at the cap — the cap
	// bounds the table, it does not break a client's retry.
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/senders", session,
		MailboxSenderRequest{Domain: "a.ae"}), http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// Mounting, sessions, the fuse and the limiter
// ---------------------------------------------------------------------------

// Fail-closed mounting: a deployment with no OAuth client serves NO mailbox
// route at all, rather than routes that answer 500 forever.
func TestMailboxRoutesAreAbsentWhenUnconfigured(t *testing.T) {
	h := newHarness(t) // no Server.Mailbox
	session := h.session(h.user("mailbox-unconfigured"))

	for _, tc := range []struct{ method, path string }{
		{http.MethodPost, "/api/v1/mailbox/oauth/begin"},
		{http.MethodGet, "/api/v1/mailbox/oauth/callback?code=x&state=y"},
		{http.MethodPost, "/api/v1/mailbox/oauth/claim"},
		{http.MethodPost, "/api/v1/mailbox/token"},
		{http.MethodPost, "/api/v1/mailbox/revoke"},
		{http.MethodGet, "/api/v1/mailbox/grant"},
		{http.MethodDelete, "/api/v1/mailbox/grant"},
		{http.MethodGet, "/api/v1/mailbox/senders"},
		{http.MethodPost, "/api/v1/mailbox/senders"},
		{http.MethodDelete, "/api/v1/mailbox/senders"},
	} {
		rec := h.req(tc.method, tc.path, session, nil)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s %s: %d, want 404 on a server with no mailbox broker", tc.method, tc.path, rec.Code)
		}
		// The catch-all's answer, not a handler's: the route is not there.
		if got := decodeJSON[errorBody](t, rec).Error; got != "not_found" {
			t.Fatalf("%s %s: error = %q, want not_found", tc.method, tc.path, got)
		}
	}
}

// ---------------------------------------------------------------------------
// NewServer's own wiring
// ---------------------------------------------------------------------------
//
// Every test above hand-assigns Server.Mailbox, so none of them says anything
// about the production construction path. These two go through NewServer with
// a real config — the relay's TestNewServerRefusesRelayEnabledWithNoToken
// precedent — because that is the layer where the feature is switched on, and
// where a broker that silently came back nil would take the routes AND
// cmd/ledgerd's state sweep (which no-ops on a nil broker) with it.

// mailboxConfig is a config config.Load would accept: loopback Google
// endpoints are validateMailbox's own exemption for a local fake.
func mailboxConfig(googleURL string) config.Config {
	return config.Config{
		Mail: config.MailConfig{Domain: "example.test", MaxMessageBytes: 1 << 20},
		Auth: config.AuthConfig{
			SessionTTL:    time.Hour,
			RPID:          "app.example.test",
			RPDisplayName: "Ledger",
			// TWO origins, so "the first one wins" is a decision the test can
			// see rather than a coincidence of there being only one.
			RPOrigins: []string{"https://app.example.test", "https://staging.example.test"},
		},
		Mailbox: config.MailboxConfig{
			GoogleClientID:     "client-id.apps.googleusercontent.com",
			GoogleClientSecret: "client-secret",
			GoogleAuthURL:      googleURL + "/auth",
			GoogleTokenURL:     googleURL + "/token",
			GoogleRevokeURL:    googleURL + "/revoke",
		},
	}
}

func TestNewServerWiresTheMailboxBrokerAndItsRoutes(t *testing.T) {
	h := newHarness(t)
	ts := httptest.NewServer(fakegoogle.New())
	t.Cleanup(ts.Close)

	cfg := mailboxConfig(ts.URL)
	srv, err := NewServer(cfg, h.pool)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Mailbox == nil {
		t.Fatal("NewServer built no mailbox broker from a configured mailbox")
	}
	// The three stores the routes and the sweep need. States in particular:
	// cmd/ledgerd's startMailboxStateSweep no-ops on a nil broker or a nil
	// States, so a broker that arrived half-built would leave
	// mailbox_oauth_states growing forever with nothing to notice.
	if srv.Mailbox.States == nil || srv.Mailbox.States.DB == nil {
		t.Fatal("the broker has no state store: the oauth-state sweep would silently no-op")
	}
	if srv.Mailbox.Grants == nil || srv.Mailbox.Grants.DB == nil {
		t.Fatal("the broker has no grant store")
	}
	if srv.Mailbox.Google == nil {
		t.Fatal("the broker has no Google client")
	}
	if got := srv.Mailbox.Google.ClientSecret; got != "client-secret" {
		t.Fatalf("ClientSecret = %q; the env-only secret did not reach the client", got)
	}
	if want := "https://app.example.test" + mailboxCallbackPath; srv.Mailbox.RedirectURI != want {
		t.Fatalf("RedirectURI = %q, want %q", srv.Mailbox.RedirectURI, want)
	}

	// And the routes are LIVE on the handler this construction produces —
	// checked through the one route that exercises the whole wiring at once:
	// the auth URL is built from the configured endpoint and carries the
	// derived redirect URI.
	session := h.session(h.user("newserver-mailbox"))
	r := httptest.NewRequest(http.MethodPost, "/api/v1/mailbox/oauth/begin", nil)
	r.Header.Set("Authorization", "Bearer "+session)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusOK)
	authURL, err := url.Parse(decodeJSON[MailboxBeginResponse](t, rec).AuthURL)
	if err != nil {
		t.Fatal(err)
	}
	if got := authURL.Scheme + "://" + authURL.Host + authURL.Path; got != ts.URL+"/auth" {
		t.Fatalf("the auth URL points at %q, not the configured endpoint %q", got, ts.URL+"/auth")
	}
	if got, want := authURL.Query().Get("redirect_uri"),
		"https://app.example.test"+mailboxCallbackPath; got != want {
		t.Fatalf("redirect_uri = %q, want %q", got, want)
	}
	if got := authURL.Query().Get("client_id"); got != cfg.Mailbox.GoogleClientID {
		t.Fatalf("client_id = %q", got)
	}
}

// The inverse, at the same layer: an unconfigured mailbox builds no broker and
// mounts nothing. TestMailboxRoutesAreAbsentWhenUnconfigured proves the
// mounting rule with a hand-built Server; this proves that a real config is
// what decides it.
func TestNewServerBuildsNoMailboxBrokerWhenUnconfigured(t *testing.T) {
	h := newHarness(t)
	cfg := mailboxConfig("http://127.0.0.1:1")
	cfg.Mailbox.GoogleClientSecret = "" // the env-only half is absent
	if cfg.Mailbox.Enabled() {
		t.Fatal("the test's own premise is wrong: this config is still enabled")
	}
	srv, err := NewServer(cfg, h.pool)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Mailbox != nil {
		t.Fatal("NewServer built a mailbox broker for a config with no client secret")
	}
	session := h.session(h.user("newserver-no-mailbox"))
	r := httptest.NewRequest(http.MethodPost, "/api/v1/mailbox/oauth/begin", nil)
	r.Header.Set("Authorization", "Bearer "+session)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusNotFound)
}

// The redirect URI is the ONE string that has to be byte-identical to what the
// operator registered in the Google Cloud console (spec §7). Google answers
// redirect_uri_mismatch for anything else, so a derivation that drifted would
// break every connect with nothing in this repo noticing.
func TestTheRedirectURIIsTheFirstOriginPlusTheCallbackPath(t *testing.T) {
	for _, tc := range []struct {
		name    string
		origins []string
		want    string
	}{
		{"one origin", []string{"https://app.example.test"},
			"https://app.example.test/api/v1/mailbox/oauth/callback"},
		{"the FIRST of several", []string{"https://app.example.test", "https://staging.example.test"},
			"https://app.example.test/api/v1/mailbox/oauth/callback"},
		{"a trailing slash is not doubled", []string{"https://app.example.test/"},
			"https://app.example.test/api/v1/mailbox/oauth/callback"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := mailboxRedirectURI(tc.origins)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("mailboxRedirectURI(%v) = %q, want %q", tc.origins, got, tc.want)
			}
		})
	}
}

// A mailbox configured with no rp_origins is a STARTUP error, not a server
// that serves a connect flow whose callback has nowhere to return to. Without
// this test the whole branch never executed.
func TestNewServerRefusesAMailboxWithNoOrigin(t *testing.T) {
	h := newHarness(t)
	cfg := mailboxConfig("http://127.0.0.1:1")
	cfg.Auth.RPID, cfg.Auth.RPOrigins = "", nil

	_, err := NewServer(cfg, h.pool)
	if err == nil {
		t.Fatal("NewServer accepted a configured mailbox with no auth.rp_origins")
	}
	if !strings.Contains(err.Error(), "rp_origins") {
		t.Fatalf("the error does not name the missing setting: %v", err)
	}
	if _, dErr := mailboxRedirectURI(nil); dErr == nil {
		t.Fatal("mailboxRedirectURI accepted an empty origin list")
	}
}

func TestMailboxRoutesRequireASession(t *testing.T) {
	h := newMailboxHarness(t)
	for _, tc := range []struct{ method, path string }{
		{http.MethodPost, "/api/v1/mailbox/oauth/begin"},
		{http.MethodPost, "/api/v1/mailbox/oauth/claim"},
		{http.MethodPost, "/api/v1/mailbox/token"},
		{http.MethodPost, "/api/v1/mailbox/revoke"},
		{http.MethodGet, "/api/v1/mailbox/grant"},
		{http.MethodDelete, "/api/v1/mailbox/grant"},
		{http.MethodGet, "/api/v1/mailbox/senders"},
		{http.MethodPost, "/api/v1/mailbox/senders"},
		{http.MethodDelete, "/api/v1/mailbox/senders"},
	} {
		rec := h.req(tc.method, tc.path, "", nil)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s without a session: %d, want 401", tc.method, tc.path, rec.Code)
		}
	}
	// The callback is the one route with no session: it is a browser
	// navigation arriving from Google, and it authenticates the STATE instead.
	rec := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=x&state=y", "", nil)
	if rec.Code == http.StatusUnauthorized {
		t.Fatal("the OAuth callback demands a session; Google's redirect carries none")
	}
}

// guards.go's isRead exemption, asserted rather than assumed: the callback is
// a GET and rides the read exemption, while the claim POST behind it does not.
// Spec §2.1 ratifies exactly this — "the ceremony cannot complete without the
// gated claim POST".
func TestTheCallbackRidesTheHeadroomReadExemptionAndTheClaimDoesNot(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-fuse"))
	claim := h.callback(t, h.begin(t, session))

	fuse := &fakeFuse{tripped: true}
	h.srv.Headroom = fuse
	h.h = h.srv.Handler()

	rec := h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=x&state=unknown", "", nil)
	if rec.Code == http.StatusServiceUnavailable {
		t.Fatalf("the callback was refused by the fuse: %s", rec.Body.String())
	}
	rec = h.req(http.MethodGet, "/api/v1/mailbox/grant", session, nil)
	if rec.Code == http.StatusServiceUnavailable {
		t.Fatal("GET /grant was refused by the fuse; reads keep serving")
	}

	rec = h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantStatus(t, rec, http.StatusServiceUnavailable)
	if got := decodeJSON[errorBody](t, rec).Error; got != "no_headroom" {
		t.Fatalf("error = %q, want no_headroom", got)
	}
}

func TestEveryMailboxBrokerPOSTIsRateLimited(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-limited"))

	for _, path := range []string{
		"/api/v1/mailbox/oauth/begin",
		"/api/v1/mailbox/oauth/claim",
		"/api/v1/mailbox/token",
		"/api/v1/mailbox/revoke",
	} {
		// A limiter with no refill, so the budget is exactly the burst.
		h.srv.MailboxPerIP = NewLimiter(0, 1, 16, h.srv.now)
		h.srv.MailboxGlobal = NewLimiter(0, 1000, 1, h.srv.now)
		h.h = h.srv.Handler()
		h.req(http.MethodPost, path, session, map[string]any{})
		rec := h.req(http.MethodPost, path, session, map[string]any{})
		wantStatus(t, rec, http.StatusTooManyRequests)
		if got := decodeJSON[errorBody](t, rec).Error; got != "rate_limited" {
			t.Fatalf("%s: error = %q, want rate_limited", path, got)
		}
	}
}

// Per-IP FIRST, then global — the ordering ratelimit.go's header calls an
// outage primitive when it is reversed: one host draining the shared budget
// with requests the per-IP limiter was about to refuse anyway holds every
// other client at 429.
func TestTheMailboxLimiterIsPerIPBeforeGlobalAndBeforeTheSession(t *testing.T) {
	h := newMailboxHarness(t)
	h.srv.MailboxPerIP = NewLimiter(0, 1, 16, h.srv.now)
	h.srv.MailboxGlobal = NewLimiter(0, 4, 1, h.srv.now)
	h.h = h.srv.Handler()

	// Both calls carry NO session. The first spends the per-IP token and is
	// refused as unauthorized; the second must be rate limited, which is only
	// true if the limiter ran before the session was resolved.
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/token", "", map[string]any{}),
		http.StatusUnauthorized)
	wantStatus(t, h.req(http.MethodPost, "/api/v1/mailbox/token", "", map[string]any{}),
		http.StatusTooManyRequests)

	// Four requests were refused per-IP; if a global token had been spent by
	// each of them the global budget of 4 would be gone. It is not, because a
	// global token is only spent by a request that already passed per-IP.
	for i := 0; i < 6; i++ {
		h.req(http.MethodPost, "/api/v1/mailbox/token", "", map[string]any{})
	}
	if !h.srv.MailboxGlobal.Allow("") {
		t.Fatal("requests refused by the per-IP limiter still spent global tokens: " +
			"one host can now starve every other client")
	}
}

// No secret this ceremony handles may reach the operator log — not the state
// token, not the PKCE verifier, not the claim code, and none of the three
// tokens. The log is where the REASON for a refusal goes, and a reason is not
// a credential.
func TestNoMailboxSecretReachesTheLog(t *testing.T) {
	h := newMailboxHarness(t)
	var logged strings.Builder
	h.srv.Logf = func(format string, args ...any) {
		fmt.Fprintf(&logged, format+"\n", args...)
	}
	h.h = h.srv.Handler()
	session := h.session(h.user("mailbox-quiet-log"))

	// The happy path...
	state := h.begin(t, session)
	claim := h.callback(t, state)
	rec := h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	wantStatus(t, rec, http.StatusOK)
	tokens := decodeJSON[MailboxClaimResponse](t, rec)
	verifier := h.google.TokenRequests[0].Get("code_verifier")

	// ...and every path that LOGS. Each of these presents a REAL secret, which
	// is what makes the assertion below able to fail: a refusal logged with
	// the token that caused it is the leak this test is looking for, and a
	// probe carrying a made-up token could not detect it.
	//
	// A spent claim code:
	h.req(http.MethodPost, "/api/v1/mailbox/oauth/claim", session,
		MailboxClaimRequest{ClaimCode: claim})
	// A replayed state token:
	h.req(http.MethodGet, "/api/v1/mailbox/oauth/callback?code=x&state="+url.QueryEscape(state), "", nil)
	// A real refresh token whose digest is no longer current — the rotation
	// supersedes it, and the mismatch path then logs with the real thing in
	// hand:
	h.google.RefreshToken = "second-refresh-token"
	h.connect(t, session)
	h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: tokens.RefreshToken})
	h.req(http.MethodPost, "/api/v1/mailbox/revoke", session,
		MailboxRevokeRequest{RefreshToken: tokens.RefreshToken})
	// And a token Google itself refuses:
	h.google.InvalidGrant = true
	h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		MailboxTokenRequest{RefreshToken: "second-refresh-token"})

	if logged.Len() == 0 {
		t.Fatal("nothing was logged at all, so this test proves nothing")
	}
	for name, secret := range map[string]string{
		"the state token":          state,
		"the PKCE verifier":        verifier,
		"the claim code":           claim,
		"the refresh token":        tokens.RefreshToken,
		"the second refresh token": "second-refresh-token",
		"the access token":         tokens.AccessToken,
		"the id token":             tokens.IDToken,
	} {
		if secret == "" {
			t.Fatalf("%s is empty; the check would pass on nothing", name)
		}
		if strings.Contains(logged.String(), secret) {
			t.Fatalf("%s reached the log:\n%s", name, logged.String())
		}
	}
}

// The bodies are capped and typed like every other POST in this package.
func TestMailboxBodiesAreCappedAndRejectUnknownFields(t *testing.T) {
	h := newMailboxHarness(t)
	session := h.session(h.user("mailbox-bodies"))

	rec := h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		map[string]any{"refresh_token": "x", "user_id": "someone-else"})
	wantStatus(t, rec, http.StatusBadRequest)

	huge := make([]byte, maxSmallBodyBytes+1024)
	for i := range huge {
		huge[i] = 'a'
	}
	rec = h.req(http.MethodPost, "/api/v1/mailbox/token", session,
		[]byte(`{"refresh_token":"`+string(huge)+`"}`))
	wantStatus(t, rec, http.StatusRequestEntityTooLarge)
}
