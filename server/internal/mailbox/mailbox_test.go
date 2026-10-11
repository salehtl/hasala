package mailbox

import (
	"context"
	"crypto/sha256"
	"errors"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/mailbox/fakegoogle"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

func newUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	u, err := auth.UpsertUser(bg, pool, auth.Identity{IdP: auth.IdPApple, Subject: "sub-" + uuid.NewString()})
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// clock is a settable clock for tests that need to advance time
// deterministically (state TTL expiry) rather than sleeping.
type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newStates(pool *pgxpool.Pool, c *clock) *States {
	return &States{DB: pool, Now: c.now}
}

func hashOf(s string) []byte {
	sum := sha256.Sum256([]byte(s))
	return sum[:]
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

func TestStateBeginThenClaimReturnsUserAndVerifier(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	state, verifier, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if state == "" || verifier == "" {
		t.Fatalf("Begin returned empty state/verifier: %q %q", state, verifier)
	}
	if len(verifier) < 43 {
		t.Fatalf("pkce verifier is %d chars, want RFC 7636's 43-char minimum", len(verifier))
	}

	gotUser, gotVerifier, err := s.Claim(bg, state)
	if err != nil {
		t.Fatal(err)
	}
	if gotUser != u {
		t.Fatalf("Claim user = %s, want %s", gotUser, u)
	}
	if gotVerifier != verifier {
		t.Fatalf("Claim verifier = %q, want %q", gotVerifier, verifier)
	}
}

func TestStateClaimTwiceSecondFails(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	state, _, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Claim(bg, state); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	if _, _, err := s.Claim(bg, state); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("second claim: err = %v, want ErrStateUnknown", err)
	}
}

func TestStateClaimUnknownFails(t *testing.T) {
	pool := pgtest.New(t)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	if _, _, err := s.Claim(bg, "never-begun"); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("err = %v, want ErrStateUnknown", err)
	}
	if _, _, err := s.Claim(bg, ""); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("empty state: err = %v, want ErrStateUnknown", err)
	}
}

func TestStateClaimAfterTTLExpiryFails(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	state, _, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	c.advance(StateTTL + time.Second)

	if _, _, err := s.Claim(bg, state); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("err = %v, want ErrStateUnknown", err)
	}
	// The row is spent even though it expired: a second claim attempt at
	// the (still expired) clock finds nothing rather than the same "expired"
	// detail twice, proving the DELETE really consumed it.
	if _, _, err := s.Claim(bg, state); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("replay after expiry: err = %v, want ErrStateUnknown", err)
	}
}

// The sweep: a ceremony nobody finished is a row nothing else removes, since
// only Claim deletes one. It takes the expired rows and leaves the live ones.
func TestReapExpiredStatesTakesOnlyTheAbandonedOnes(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	abandoned, _, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Begin(bg, u); err != nil {
		t.Fatal(err)
	}
	// Nothing has expired yet, so a sweep now must take nothing at all — a
	// reaper that ignored expires_at would pass every other assertion here.
	if n, err := s.ReapExpired(bg); err != nil || n != 0 {
		t.Fatalf("ReapExpired before any expiry = (%d, %v), want (0, nil)", n, err)
	}

	c.advance(StateTTL + time.Second)
	// A third ceremony, begun after the clock moved: it is live at the moment
	// of the sweep and must survive it.
	live, _, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}

	n, err := s.ReapExpired(bg)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("ReapExpired = %d, want the 2 abandoned rows", n)
	}
	var left int
	if err := pool.QueryRow(bg,
		`SELECT count(*) FROM mailbox_oauth_states WHERE user_id = $1`, u).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 1 {
		t.Fatalf("%d rows left, want the 1 live ceremony", left)
	}
	if _, _, err := s.Claim(bg, live); err != nil {
		t.Fatalf("the sweep took a live ceremony: %v", err)
	}
	if _, _, err := s.Claim(bg, abandoned); !errors.Is(err, ErrStateUnknown) {
		t.Fatalf("an abandoned ceremony survived the sweep: %v", err)
	}
}

func TestReapExpiredStatesRefusesWithNoPool(t *testing.T) {
	if _, err := (&States{}).ReapExpired(bg); err == nil {
		t.Fatal("want an error with no pool")
	}
}

func TestStateBeginRefusesZeroUser(t *testing.T) {
	pool := pgtest.New(t)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)
	if _, _, err := s.Begin(bg, uuid.Nil); err == nil {
		t.Fatal("want an error for a zero user id")
	}
}

// TestStateBeginStoresSHA256OfTheStateTokenNotTheRawToken reads the row
// Begin wrote DIRECTLY off the database — bypassing Claim entirely, since
// Claim's DELETE...RETURNING would only prove the two are symmetric (any
// encoding round-trips through a paired encode/decode) and not that the
// column actually holds a digest. "state_hash = sha256, never the token"
// (00035_mailbox.sql's header) is the property under test here, not a
// round-trip.
func TestStateBeginStoresSHA256OfTheStateTokenNotTheRawToken(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	c := &clock{t: time.Now()}
	s := newStates(pool, c)

	state, _, err := s.Begin(bg, u)
	if err != nil {
		t.Fatal(err)
	}

	var stored []byte
	if err := pool.QueryRow(bg,
		`SELECT state_hash FROM mailbox_oauth_states WHERE user_id = $1`, u).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256([]byte(state))
	if string(stored) != string(want[:]) {
		t.Fatalf("stored state_hash = %x, want sha256(state token) = %x", stored, want)
	}
	if string(stored) == state {
		t.Fatal("stored state_hash equals the raw state token verbatim — it must be a digest, never the live token")
	}
}

// ---------------------------------------------------------------------------
// Google
// ---------------------------------------------------------------------------

func newGoogleAgainst(fg *fakegoogle.Server) (*Google, *httptest.Server) {
	srv := httptest.NewServer(fg)
	g := &Google{
		ClientID:     "test-client-id",
		ClientSecret: "test-client-secret",
		AuthURL:      srv.URL + "/auth",
		TokenURL:     srv.URL + "/token",
		RevokeURL:    srv.URL + "/revoke",
	}
	return g, srv
}

func TestGoogleAuthURLForBuildsExpectedQuery(t *testing.T) {
	g := &Google{
		ClientID: "cid-123",
		AuthURL:  "https://accounts.example/o/oauth2/v2/auth",
	}
	raw := g.AuthURLFor("state-1", "challenge-1", "https://app.example/cb")
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	cases := map[string]string{
		"client_id":             "cid-123",
		"redirect_uri":          "https://app.example/cb",
		"response_type":         "code",
		"access_type":           "offline",
		"prompt":                "consent",
		"state":                 "state-1",
		"code_challenge":        "challenge-1",
		"code_challenge_method": "S256",
	}
	for k, want := range cases {
		if got := q.Get(k); got != want {
			t.Errorf("query[%q] = %q, want %q", k, got, want)
		}
	}
	// Exact equality, not strings.Contains: this is the guard against silent
	// grant widening. A Contains check cannot detect an ADDITION (e.g. a
	// broader scope like https://mail.google.com/ appended alongside the
	// intended three) — only a pinned exact value can, and a scope this
	// server requests is exactly as much mailbox access as it is entitled
	// to ask a user for, never a superset "while we're at it."
	const wantScope = "openid email https://www.googleapis.com/auth/gmail.readonly"
	if scope := q.Get("scope"); scope != wantScope {
		t.Errorf("scope = %q, want exactly %q", scope, wantScope)
	}
}

func TestPKCEChallengeS256MatchesRFC7636Vector(t *testing.T) {
	// RFC 7636 Appendix B's worked example.
	const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	const want = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	if got := PKCEChallengeS256(verifier); got != want {
		t.Fatalf("PKCEChallengeS256 = %q, want %q", got, want)
	}
}

func TestGoogleExchangePostsSecretAndPKCEVerifierAndParsesTokens(t *testing.T) {
	fg := fakegoogle.New()
	fg.RefreshToken = "rt-exchange"
	fg.AccessToken = "at-exchange"
	fg.IDToken = "idt-exchange"
	fg.ExpiresIn = 1234
	g, srv := newGoogleAgainst(fg)
	defer srv.Close()

	toks, err := g.Exchange(bg, "auth-code-1", "verifier-abc", "https://app.example/cb")
	if err != nil {
		t.Fatal(err)
	}
	if toks.RefreshToken != "rt-exchange" || toks.AccessToken != "at-exchange" ||
		toks.IDToken != "idt-exchange" || toks.ExpiresIn != 1234 {
		t.Fatalf("Exchange tokens = %+v", toks)
	}
	if len(fg.TokenRequests) != 1 {
		t.Fatalf("fake received %d /token requests, want 1", len(fg.TokenRequests))
	}
	form := fg.TokenRequests[0]
	if form.Get("client_secret") != "test-client-secret" {
		t.Errorf("posted client_secret = %q, want the configured secret", form.Get("client_secret"))
	}
	if form.Get("code_verifier") != "verifier-abc" {
		t.Errorf("posted code_verifier = %q, want %q", form.Get("code_verifier"), "verifier-abc")
	}
	if form.Get("grant_type") != "authorization_code" {
		t.Errorf("posted grant_type = %q, want authorization_code", form.Get("grant_type"))
	}
	if form.Get("code") != "auth-code-1" {
		t.Errorf("posted code = %q, want auth-code-1", form.Get("code"))
	}
	if form.Get("redirect_uri") != "https://app.example/cb" {
		t.Errorf("posted redirect_uri = %q", form.Get("redirect_uri"))
	}
}

func TestGoogleRefreshReturnsNewAccessTokenAndEchoesRefreshToken(t *testing.T) {
	fg := fakegoogle.New()
	fg.AccessToken = "at-refreshed"
	fg.ExpiresIn = 3600
	g, srv := newGoogleAgainst(fg)
	defer srv.Close()

	toks, err := g.Refresh(bg, "held-refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	if toks.AccessToken != "at-refreshed" {
		t.Errorf("AccessToken = %q, want at-refreshed", toks.AccessToken)
	}
	if toks.RefreshToken != "held-refresh-token" {
		t.Errorf("RefreshToken = %q, want the input echoed back", toks.RefreshToken)
	}
	form := fg.TokenRequests[0]
	if form.Get("grant_type") != "refresh_token" {
		t.Errorf("posted grant_type = %q, want refresh_token", form.Get("grant_type"))
	}
	if form.Get("refresh_token") != "held-refresh-token" {
		t.Errorf("posted refresh_token = %q", form.Get("refresh_token"))
	}
	if form.Get("client_secret") != "test-client-secret" {
		t.Errorf("posted client_secret = %q, want the configured secret", form.Get("client_secret"))
	}
}

func TestGoogleRefreshInvalidGrantIsASentinel(t *testing.T) {
	fg := fakegoogle.New()
	fg.InvalidGrant = true
	g, srv := newGoogleAgainst(fg)
	defer srv.Close()

	_, err := g.Refresh(bg, "dead-refresh-token")
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("err = %v, want ErrInvalidGrant", err)
	}
}

func TestGoogleExchangeInvalidGrantIsASentinel(t *testing.T) {
	fg := fakegoogle.New()
	fg.InvalidGrant = true
	g, srv := newGoogleAgainst(fg)
	defer srv.Close()

	_, err := g.Exchange(bg, "stale-code", "verifier", "https://app.example/cb")
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("err = %v, want ErrInvalidGrant", err)
	}
}

func TestGoogleRevokePostsToken(t *testing.T) {
	fg := fakegoogle.New()
	g, srv := newGoogleAgainst(fg)
	defer srv.Close()

	if err := g.Revoke(bg, "token-to-kill"); err != nil {
		t.Fatal(err)
	}
	if len(fg.RevokeRequests) != 1 {
		t.Fatalf("fake received %d /revoke requests, want 1", len(fg.RevokeRequests))
	}
	if got := fg.RevokeRequests[0].Get("token"); got != "token-to-kill" {
		t.Errorf("posted token = %q, want token-to-kill", got)
	}
}

// ---------------------------------------------------------------------------
// Grants
// ---------------------------------------------------------------------------

func newGrants(pool *pgxpool.Pool) *Grants { return &Grants{DB: pool} }

func TestGrantsUpsertThenGetRoundTrips(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)

	if err := g.Upsert(bg, u, ProviderGmail, hashOf("refresh-token-1")); err != nil {
		t.Fatal(err)
	}
	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("Get returned nil, want a grant")
	}
	if got.Provider != ProviderGmail {
		t.Errorf("Provider = %q, want %q", got.Provider, ProviderGmail)
	}
	if got.Status != GrantStatusActive {
		t.Errorf("Status = %q, want %q", got.Status, GrantStatusActive)
	}
	if got.CreatedAt.IsZero() {
		t.Error("CreatedAt is zero")
	}
	if got.LastBrokerAt != nil {
		t.Errorf("LastBrokerAt = %v, want nil before any VerifyAndTouch", got.LastBrokerAt)
	}
}

func TestGrantsGetReturnsNilForNoGrant(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)

	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("Get = %+v, want nil", got)
	}
}

func TestVerifyAndTouchAcceptsMatchingDigestAndTouchesLastBrokerAt(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	digest := hashOf("refresh-token-2")
	if err := g.Upsert(bg, u, ProviderGmail, digest); err != nil {
		t.Fatal(err)
	}

	if err := g.VerifyAndTouch(bg, u, digest); err != nil {
		t.Fatalf("VerifyAndTouch: %v", err)
	}
	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got.LastBrokerAt == nil {
		t.Fatal("LastBrokerAt is nil after a successful VerifyAndTouch")
	}
}

func TestVerifyAndTouchRejectsWrongDigest(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("refresh-token-3")); err != nil {
		t.Fatal(err)
	}

	err := g.VerifyAndTouch(bg, u, hashOf("wrong-token"))
	if !errors.Is(err, ErrGrantMismatch) {
		t.Fatalf("err = %v, want ErrGrantMismatch", err)
	}
}

func TestVerifyAndTouchRejectsWrongUserWithTheSameSentinel(t *testing.T) {
	pool := pgtest.New(t)
	userA := newUser(t, pool)
	userB := newUser(t, pool)
	g := newGrants(pool)
	digestA := hashOf("refresh-token-a")
	if err := g.Upsert(bg, userA, ProviderGmail, digestA); err != nil {
		t.Fatal(err)
	}

	// userB presents userA's digest under their own session — no grant row
	// exists for userB at all, and the answer must be identical to the
	// wrong-digest case above.
	errWrongUser := g.VerifyAndTouch(bg, userB, digestA)
	if !errors.Is(errWrongUser, ErrGrantMismatch) {
		t.Fatalf("wrong-user err = %v, want ErrGrantMismatch", errWrongUser)
	}

	errWrongDigest := g.VerifyAndTouch(bg, userA, hashOf("not-a"))
	if !errors.Is(errWrongDigest, ErrGrantMismatch) {
		t.Fatalf("wrong-digest err = %v, want ErrGrantMismatch", errWrongDigest)
	}
	if !errors.Is(errWrongUser, ErrGrantMismatch) || !errors.Is(errWrongDigest, ErrGrantMismatch) {
		t.Fatal("both cases must wrap the identical sentinel")
	}
}

func TestVerifyAndTouchRejectsNoGrantAtAll(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)

	if err := g.VerifyAndTouch(bg, u, hashOf("anything")); !errors.Is(err, ErrGrantMismatch) {
		t.Fatalf("err = %v, want ErrGrantMismatch", err)
	}
}

// TestSupersededTokenDigestFailsClosed is D9's fail-closed handoff: a
// reconnect (Upsert) rotates the stored digest, and the superseded device's
// old token must stop verifying in the same statement the new one starts
// working — no window where both are valid.
func TestSupersededTokenDigestFailsClosed(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	oldDigest := hashOf("device-1-refresh-token")
	if err := g.Upsert(bg, u, ProviderGmail, oldDigest); err != nil {
		t.Fatal(err)
	}
	if err := g.VerifyAndTouch(bg, u, oldDigest); err != nil {
		t.Fatalf("old digest should verify before rotation: %v", err)
	}

	newDigest := hashOf("device-2-refresh-token")
	if err := g.Upsert(bg, u, ProviderGmail, newDigest); err != nil {
		t.Fatal(err)
	}

	if err := g.VerifyAndTouch(bg, u, oldDigest); !errors.Is(err, ErrGrantMismatch) {
		t.Fatalf("superseded digest: err = %v, want ErrGrantMismatch", err)
	}
	if err := g.VerifyAndTouch(bg, u, newDigest); err != nil {
		t.Fatalf("new digest should verify after rotation: %v", err)
	}
}

func TestGrantsUpsertRotationResetsStatusToActive(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t1")); err != nil {
		t.Fatal(err)
	}
	if err := g.MarkReconnect(bg, u); err != nil {
		t.Fatal(err)
	}
	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != GrantStatusReconnectRequired {
		t.Fatalf("Status = %q after MarkReconnect, want %q", got.Status, GrantStatusReconnectRequired)
	}

	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t2")); err != nil {
		t.Fatal(err)
	}
	got, err = g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != GrantStatusActive {
		t.Fatalf("Status = %q after reconnect Upsert, want %q", got.Status, GrantStatusActive)
	}
}

func TestGrantsMarkReconnect(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t")); err != nil {
		t.Fatal(err)
	}
	if err := g.MarkReconnect(bg, u); err != nil {
		t.Fatal(err)
	}
	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != GrantStatusReconnectRequired {
		t.Fatalf("Status = %q, want %q", got.Status, GrantStatusReconnectRequired)
	}
}

func TestGrantsDelete(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t")); err != nil {
		t.Fatal(err)
	}
	if err := g.Delete(bg, u); err != nil {
		t.Fatal(err)
	}
	got, err := g.Get(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("Get after Delete = %+v, want nil", got)
	}
}

// seedSenders writes an allowlist for u, and returns nothing: every assertion
// below reads it back with senderDomains rather than trusting the write.
func seedSenders(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, domains ...string) {
	t.Helper()
	for _, d := range domains {
		if _, err := pool.Exec(bg,
			`INSERT INTO mailbox_senders (user_id, domain) VALUES ($1, $2)`, u, d); err != nil {
			t.Fatal(err)
		}
	}
	if got := senderDomains(t, pool, u); len(got) != len(domains) {
		t.Fatalf("seed wrote %d sender rows, want %d", len(got), len(domains))
	}
}

func senderDomains(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) []string {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT domain FROM mailbox_senders WHERE user_id = $1 ORDER BY domain`, u)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			t.Fatal(err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// Deletion hygiene: a full disconnect must not leave the user's bank domains
// behind. That list is mail metadata — which institutions this person banks
// with — and a user who disconnected their mailbox has asked for it to stop
// being here. See Delete's doc for why this is Delete's job and not the HTTP
// handler's.
func TestGrantsDeleteAlsoSweepsTheSenderAllowlist(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t")); err != nil {
		t.Fatal(err)
	}
	seedSenders(t, pool, u, "dib.ae", "emiratesnbd.com")

	if err := g.Delete(bg, u); err != nil {
		t.Fatal(err)
	}
	if got := senderDomains(t, pool, u); len(got) != 0 {
		t.Fatalf("disconnect left the sender allowlist behind: %v", got)
	}
}

// Delete with no grant row at all still sweeps: a device whose grant was
// already removed elsewhere (another device disconnected first) must still be
// able to clear the list, and the route is idempotent.
func TestGrantsDeleteSweepsSendersEvenWithNoGrantRow(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	seedSenders(t, pool, u, "dib.ae")

	if err := newGrants(pool).Delete(bg, u); err != nil {
		t.Fatal(err)
	}
	if got := senderDomains(t, pool, u); len(got) != 0 {
		t.Fatalf("sender allowlist survived a grantless disconnect: %v", got)
	}
}

// The sweep is scoped to one account. A shared statement that forgot its
// WHERE would pass every assertion above.
func TestGrantsDeleteLeavesAnotherAccountsSenders(t *testing.T) {
	pool := pgtest.New(t)
	victim, bystander := newUser(t, pool), newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, victim, ProviderGmail, hashOf("t")); err != nil {
		t.Fatal(err)
	}
	seedSenders(t, pool, victim, "dib.ae")
	seedSenders(t, pool, bystander, "adcb.com")

	if err := g.Delete(bg, victim); err != nil {
		t.Fatal(err)
	}
	if got := senderDomains(t, pool, bystander); len(got) != 1 || got[0] != "adcb.com" {
		t.Fatalf("another account's allowlist = %v, want [adcb.com]", got)
	}
}

// The other half of the ruling, and the one 00035_mailbox.sql's header states:
// a token that merely EXPIRED flips the status and keeps the list, so a weekly
// reconnect does not make the user re-add their banks. MarkReconnect is not a
// disconnect.
func TestMarkReconnectKeepsTheSenderAllowlist(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	g := newGrants(pool)
	if err := g.Upsert(bg, u, ProviderGmail, hashOf("t")); err != nil {
		t.Fatal(err)
	}
	seedSenders(t, pool, u, "dib.ae", "emiratesnbd.com")

	if err := g.MarkReconnect(bg, u); err != nil {
		t.Fatal(err)
	}
	if got := senderDomains(t, pool, u); len(got) != 2 {
		t.Fatalf("a reconnect flip lost the sender allowlist: %v", got)
	}
}

func TestTokenHashIsSHA256(t *testing.T) {
	want := hashOf("some-refresh-token")
	got := TokenHash("some-refresh-token")
	if string(got) != string(want) {
		t.Fatalf("TokenHash mismatch")
	}
}
