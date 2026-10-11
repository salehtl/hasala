package api

// The Gmail transaction-mailbox broker's HTTP surface (spec
// 2026-08-11-gmail-transaction-mailbox-design (ledgerd design archive) §2.1,
// decisions D2/D3/D3a/D9/D10). It mounts internal/mailbox — a package that
// trades codes and tokens with Google and stores nothing but a digest — and
// adds the two things an HTTP boundary owes it: session binding, and a
// failure taxonomy that says as little as possible.
//
//	POST   /api/v1/mailbox/oauth/begin                    -> {auth_url}
//	GET    /api/v1/mailbox/oauth/callback?code&state      -> 303 /mailbox-callback.html?claim=<code>
//	POST   /api/v1/mailbox/oauth/claim  {claim_code}      -> {refresh_token, access_token, id_token}
//	POST   /api/v1/mailbox/token        {refresh_token}   -> {access_token, expires_in}
//	POST   /api/v1/mailbox/revoke       {refresh_token}   -> 204
//	GET    /api/v1/mailbox/grant                          -> {provider, status, created_at} | 404 no_grant
//	DELETE /api/v1/mailbox/grant                          -> 204
//	GET    /api/v1/mailbox/senders                        -> {domains:[...]}
//	POST   /api/v1/mailbox/senders      {domain}          -> 204
//	DELETE /api/v1/mailbox/senders      {domain}          -> 204
//
// # The server still reads no mail, and still holds no live token
//
// Nothing here fetches a message: the client does that itself (D2), and this
// package imports no Gmail API surface for the same reason internal/mailbox
// does not. A refresh token exists in this process only for the span of one
// request — the claim hand-off below is the single exception, and it is
// bounded in time, in count and to one read.
//
// # ONE refusal
//
// Every credential-shaped refusal — an unknown or spent claim code, a claim
// presented by a session that did not begin the ceremony, a digest that does
// not match, no grant at all, a token Google has stopped honouring — is
// writeMailboxRefused, which takes no arguments precisely so no caller can
// vary it. That is writeUnauthorized's discipline, applied to a second
// credential: mailbox.Grants.VerifyAndTouch already collapses its three
// mismatch shapes into one sentinel because distinguishing them would be an
// oracle over who holds a grant (D3a), and a response that took them apart
// again would undo that at the last possible moment.
//
// It is a 403 rather than a 401 on purpose. A 401 is this API's answer for
// "your SESSION is not good", and a client keys re-authentication on it; the
// caller here holds a perfectly good session and is being told about a
// different credential entirely. Answering 401 would sign a user out of the
// whole app because their Gmail token expired.
//
// Two things are deliberately NOT the refusal:
//
//   - Infrastructure trouble (Google unreachable, a timeout, a 5xx) is 503.
//     Telling a user their credential is bad when the truth is that this
//     server could not reach Google sends them to redo a consent ceremony for
//     nothing.
//   - Grant state is 404 no_grant. "You have not connected a mailbox" is a
//     fact about the caller's own account, which they can read outright, and
//     it is the answer GET /api/v1/keys already gives with no_keys. It is
//     spelled distinctly from the mux's own not_found so a client can tell
//     "this deployment has no mailbox feature" from "you have not connected
//     one yet".

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/mailbox"
	"github.com/salehtl/hasala/server/internal/origin"
	"github.com/salehtl/hasala/server/internal/quarantine"
)

const (
	// mailboxCallbackPath is Google's redirect target, and it is a constant
	// because the operator registers this exact string in the Google Cloud
	// console (spec §7) and Google refuses an exchange whose redirect_uri is
	// not byte-identical to the one the auth URL carried.
	mailboxCallbackPath = "/api/v1/mailbox/oauth/callback"

	// mailboxCallbackPage is the same-origin static page the callback hands
	// the claim code to. Its script broadcasts the code to the app that opened
	// the popup and closes the window — it exists because the public listener
	// serves Cross-Origin-Opener-Policy: same-origin, so a popup returning
	// from accounts.google.com has no window.opener to post to (§2.1). The
	// page is Task 9's; this file only redirects at it.
	mailboxCallbackPage = "/mailbox-callback.html"

	// mailboxCallbackErrorDenied is the single ?error= value the callback
	// redirects the popup to when a ceremony cannot complete (Task 9). The page
	// broadcasts it on the same channel a claim rides, so the app that opened the
	// popup stops waiting for a claim that is never coming instead of hanging
	// until its own popup-closed fallback fires.
	//
	// It is ONE fixed string for every ceremony-over branch — an unknown,
	// replayed or expired state, a consent the user cancelled, a dead
	// authorization code — for exactly the reason writeMailboxCeremonyOver used
	// one 400 body: varying it per branch would hand a popup-scripting attacker a
	// distinction each of those cases already told them only from what they
	// themselves supplied.
	mailboxCallbackErrorDenied = "denied"

	// mailboxClaimTTL bounds the in-memory hand-off between the callback and
	// the claim POST. It is mailbox.StateTTL's twin and for the same reason:
	// the legitimate gap between them is one page load.
	mailboxClaimTTL = 5 * time.Minute

	// mailboxClaimBytes is the entropy in a claim code — the 32 bytes
	// auth.Sessions.Issue mints a session bearer token from, because a claim
	// code plays the same role for one ceremony: the single secret that
	// authorizes collecting its tokens.
	mailboxClaimBytes = 32

	// maxMailboxClaims bounds the claim map. See mailboxClaims.
	maxMailboxClaims = 1024

	// maxMailboxSenders bounds one account's sender allowlist. A user's banks
	// are a handful of domains; a hundred is far more than any real list and
	// still bounds what a session can add to this table. It is not a security
	// invariant (two concurrent adds may exceed it by one), it is a growth
	// bound.
	maxMailboxSenders = 100

	// maxMailboxDomain is DNS's own limit on a fully qualified name.
	maxMailboxDomain = 253
)

// The broker's rate-limit budget, sized like the sign-in pair
// (signInPerIPRate/signInGlobalRate) because the traffic has the same shape: a
// person connecting a mailbox does it once, retries it when a browser prompt
// is dismissed, and then nothing for days. Every route it covers costs either
// a database row or an outbound request to Google.
const (
	mailboxPerIPRate   = 0.2 // 12/minute sustained
	mailboxPerIPBurst  = 10
	mailboxGlobalRate  = 20
	mailboxGlobalBurst = 100
	mailboxMaxKeys     = 4096
)

// MailboxBroker is the mailbox feature's whole server-side surface, in one
// value so that mounting it is one nil check — the Passkeys rule: a
// deployment with no OAuth client (config.MailboxConfig.Enabled() false)
// serves NO mailbox route at all, rather than routes that answer 500 forever
// and that an attacker can still find.
type MailboxBroker struct {
	// States mints and spends the single-use OAuth state rows.
	States *mailbox.States
	// Google is the OAuth client: auth URL, code exchange, refresh, revoke.
	// There is deliberately no Gmail API surface anywhere below it (D2).
	Google *mailbox.Google
	// Grants owns mailbox_grants: the digest of the refresh token, and its
	// health.
	Grants *mailbox.Grants

	// RedirectURI is the absolute URL Google redirects the consent popup back
	// to. It must be byte-identical at the auth URL and at the exchange, and
	// it must be the string the operator registered with Google (spec §7), so
	// it is one configured value rather than something derived per request
	// from a Host header a caller controls. NewServer builds it from
	// auth.rp_origins.
	RedirectURI string

	// MaxClaims bounds the in-memory claim map; 0 means maxMailboxClaims. A
	// field for the same reason MaxReingestPerConfirm is one: a test must be
	// able to reach the bounded path without driving a thousand ceremonies.
	MaxClaims int
	// MaxSenders bounds one account's allowlist; 0 means maxMailboxSenders.
	MaxSenders int

	claims mailboxClaims
}

// mailboxClaims is the hand-off between two requests that cannot authenticate
// each other: the OAuth callback is a browser navigation arriving from Google
// with no session, and the claim POST is a fetch from the app carrying one.
// The tokens live here, in memory, between them.
//
// # Why memory, and what a restart costs
//
// Writing them down would put a live Google refresh token at rest on this
// server, which is the whole thing D3 exists to prevent. So they are held in
// a map for at most mailboxClaimTTL, handed out exactly once, and lost on
// process restart — a restart mid-ceremony costs the user one retry, and the
// durable half (the state row) is in Postgres.
//
// # Why it is bounded
//
// Every entry is caused by a caller: begin, then a callback. That is enough
// to make an unbounded map a memory-growth primitive, the same shape
// Limiter's key space would be — so the map is swept of expired entries on
// every touch AND capped. At the cap the NEW ceremony is refused rather than
// an existing one evicted: eviction would let a flood delete a stranger's
// half-finished connect, whose tokens have already been fetched from Google
// and cannot be fetched again.
type mailboxClaims struct {
	mu      sync.Mutex
	entries map[string]mailboxClaim
}

type mailboxClaim struct {
	userID  uuid.UUID
	tokens  mailbox.Tokens
	expires time.Time
}

// errClaimsFull is the cap being reached, kept distinct from a random-source
// failure so the caller can log which happened. Neither reaches the client as
// anything but a 503.
var errClaimsFull = errors.New("api: the mailbox claim map is full")

// mint stores tokens under a fresh claim code. The code is returned exactly
// once and never logged: it authorizes collecting a live Google credential.
func (c *mailboxClaims) mint(userID uuid.UUID, toks mailbox.Tokens, now time.Time, limit int) (string, error) {
	raw := make([]byte, mailboxClaimBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("api: mint mailbox claim code: %w", err)
	}
	code := base64.RawURLEncoding.EncodeToString(raw)

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]mailboxClaim)
	}
	c.sweepLocked(now)
	if len(c.entries) >= limit {
		return "", errClaimsFull
	}
	c.entries[code] = mailboxClaim{userID: userID, tokens: toks, expires: now.Add(mailboxClaimTTL)}
	return code, nil
}

// spend reads an entry and removes it, whether or not the caller turns out to
// be entitled to it: presenting a claim code spends it, exactly as presenting
// a state token spends its row (mailbox.States.Claim). A client that loses the
// response retries the ceremony, not the claim.
func (c *mailboxClaims) spend(code string, now time.Time) (mailboxClaim, bool) {
	if code == "" {
		return mailboxClaim{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sweepLocked(now)
	entry, ok := c.entries[code]
	if !ok {
		return mailboxClaim{}, false
	}
	delete(c.entries, code)
	return entry, true
}

// spendByUser reads and removes the pending claim belonging to userID, if one
// exists. This is the POLL path: the opener that began the ceremony collects
// its tokens with its session alone, never needing the claim code the popup was
// handed. It makes the connect resilient to a browser that cannot deliver that
// code back to the opener — a BroadcastChannel severed by COOP, a stale service
// worker that mis-serves the callback page. Keyed on userID, so a session only
// ever collects its own ceremony's tokens; a user has at most one ceremony in
// flight, and any older duplicate is harmlessly reaped by expiry.
func (c *mailboxClaims) spendByUser(userID uuid.UUID, now time.Time) (mailboxClaim, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sweepLocked(now)
	for code, entry := range c.entries {
		if entry.userID == userID {
			delete(c.entries, code)
			return entry, true
		}
	}
	return mailboxClaim{}, false
}

// sweepLocked drops expired entries. There is no timer behind it: the map is
// touched only by the two calls above, and an entry nothing touches is bounded
// by the cap and dropped at the next mint. c.mu must be held.
func (c *mailboxClaims) sweepLocked(now time.Time) {
	for code, entry := range c.entries {
		if !entry.expires.After(now) {
			delete(c.entries, code)
		}
	}
}

func (b *MailboxBroker) maxClaims() int {
	if b.MaxClaims > 0 {
		return b.MaxClaims
	}
	return maxMailboxClaims
}

func (b *MailboxBroker) maxSenders() int {
	if b.MaxSenders > 0 {
		return b.MaxSenders
	}
	return maxMailboxSenders
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

// MailboxBeginResponse carries the URL the client opens Google's consent
// screen at. It is built by this server, not composed by the client, because
// it binds the state token and the PKCE challenge to a row only this server
// wrote.
type MailboxBeginResponse struct {
	AuthURL string `json:"auth_url"`
}

// MailboxClaimRequest collects one ceremony's tokens.
type MailboxClaimRequest struct {
	ClaimCode string `json:"claim_code"`
}

// MailboxClaimResponse is the ONE time this server hands a refresh token to
// anybody. The client seals it into its own vault (D3); this server keeps
// only sha256 of it.
type MailboxClaimResponse struct {
	RefreshToken string `json:"refresh_token"`
	AccessToken  string `json:"access_token"`
	// IDToken passes through unparsed: the burner address the app displays
	// comes out of it CLIENT-side. This server does not read the email claim,
	// and must not start — it would be a plaintext identity at rest for no
	// gain.
	IDToken string `json:"id_token"`
}

// MailboxTokenRequest presents the client's refresh token for an access
// token. The token is the credential: the server verifies its digest against
// the caller's own grant before spending the client secret on it (D3a).
type MailboxTokenRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// MailboxTokenResponse is a short-lived access token, held by the client.
type MailboxTokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
}

// MailboxRevokeRequest disconnects at Google.
type MailboxRevokeRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// MailboxGrantResponse is what the account knows about its own mailbox
// connection. There is deliberately no digest and no token in it.
type MailboxGrantResponse struct {
	Provider  string    `json:"provider"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// MailboxSendersResponse is the account's bank-domain allowlist, which the
// CLIENT applies while deciding whether a fetched message may be imported
// without review.
type MailboxSendersResponse struct {
	Domains []string `json:"domains"`
}

// MailboxSenderRequest adds or removes one domain.
type MailboxSenderRequest struct {
	Domain string `json:"domain"`
}

// writeMailboxRefused is the ONE credential refusal the mailbox routes emit.
// It takes no arguments precisely so no caller can vary it. See the file
// header for why it is a 403 and not a 401.
func writeMailboxRefused(w http.ResponseWriter) {
	writeJSON(w, http.StatusForbidden, errorBody{Error: "mailbox_refused"})
}

// writeMailboxUnavailable is what infrastructure trouble answers: this server
// could not complete the ceremony, and the caller's credential is not what is
// wrong. Retry-After matches headroomGate's, for the same reason.
func writeMailboxUnavailable(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "60")
	writeErr(w, http.StatusServiceUnavailable, "mailbox_unavailable",
		"the mailbox connection service is temporarily unavailable; nothing was changed")
}

// mailboxLimited wraps a handler in the two limiters, in the order that
// matters: per-IP first, and a global token is spent only by a request that
// already passed it. The other order lets one host drain the shared budget
// with requests the per-IP limiter was about to refuse anyway and hold every
// other client at 429 — see passkeyLimited and handleExchange, which make the
// same argument at greater length.
func (s *Server) mailboxLimited(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.MailboxPerIP.Allow(clientKey(r)) || !s.MailboxGlobal.Allow("") {
			writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many mailbox requests")
			return
		}
		h(w, r)
	}
}

// mailboxLimitedSession is mailboxLimited for the session-authenticated
// routes. The limiter runs BEFORE requireSession, so a caller with no session
// still spends a token: otherwise the cheapest way around the limit would be
// to omit the credential.
func (s *Server) mailboxLimitedSession(h authedHandler) http.HandlerFunc {
	return s.mailboxLimited(s.requireSession(h))
}

// ---------------------------------------------------------------------------
// The ceremony
// ---------------------------------------------------------------------------

// handleMailboxBegin mints a ceremony and returns Google's consent URL.
//
// The state row is written before the URL is handed out, so there is no
// window in which a callback could arrive for a ceremony this server has not
// recorded.
func (s *Server) handleMailboxBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	state, verifier, err := s.Mailbox.States.Begin(r.Context(), userID)
	if err != nil {
		s.logf("api: mailbox begin for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	// The challenge, never the verifier: the verifier stays in the row until
	// the callback replays it to Google.
	authURL := s.Mailbox.Google.AuthURLFor(state, mailbox.PKCEChallengeS256(verifier), s.Mailbox.RedirectURI)
	writeJSON(w, http.StatusOK, MailboxBeginResponse{AuthURL: authURL})
}

// handleMailboxCallback is where Google's consent redirect lands. It is the
// one route in this file with no session, because a top-level navigation
// arriving from accounts.google.com carries no Authorization header — the
// STATE token is what authenticates it, and it is single-use.
//
// It is also a GET, so guards.go's isRead exemption lets it through a tripped
// headroom fuse. Spec §2.1 ratifies that explicitly: the ceremony cannot
// complete without the claim POST, which is gated.
//
// Everything that means "this ceremony is over" REDIRECTS to the callback page
// with ?error= — an unknown, replayed or expired state, a consent the user
// cancelled, a dead authorization code. The browser is being told to start
// again, and no variation between those cases tells an attacker anything they
// did not already supply. It redirects at the same page a success does (with
// ?claim=) so the popup's script can broadcast the outcome to the app that
// opened it rather than leaving a raw error body in the window (Task 9).
func (s *Server) handleMailboxCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	state := q.Get("state")
	userID, verifier, err := s.Mailbox.States.Claim(r.Context(), state)
	switch {
	case err == nil:
	case errors.Is(err, mailbox.ErrStateUnknown):
		s.logf("api: mailbox callback: %v", err)
		writeMailboxCeremonyOver(w, r)
		return
	default:
		s.logf("api: mailbox callback: claim state: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	// The state row is spent by now, deliberately: a cancelled consent must
	// not leave a live state token behind for a replay. Google's own error
	// string goes to the log, never to the response.
	if oauthErr := q.Get("error"); oauthErr != "" {
		s.logf("api: mailbox callback for %s: google returned error=%q", userID, oauthErr)
		writeMailboxCeremonyOver(w, r)
		return
	}
	code := q.Get("code")
	if code == "" {
		s.logf("api: mailbox callback for %s: no authorization code", userID)
		writeMailboxCeremonyOver(w, r)
		return
	}
	toks, err := s.Mailbox.Google.Exchange(r.Context(), code, verifier, s.Mailbox.RedirectURI)
	switch {
	case err == nil:
	case errors.Is(err, mailbox.ErrInvalidGrant):
		// The authorization code is dead — expired, already spent, or minted
		// for another client. The ceremony is over; restarting is the fix.
		s.logf("api: mailbox callback for %s: google refused the code exchange", userID)
		writeMailboxCeremonyOver(w, r)
		return
	default:
		// Everything else is this server failing to reach or satisfy Google.
		// The error carries Google's own diagnostic text and never a token —
		// see internal/mailbox's googleError.
		s.logf("api: mailbox callback for %s: exchange: %v", userID, err)
		writeMailboxUnavailable(w)
		return
	}
	claim, err := s.Mailbox.claims.mint(userID, toks, s.now(), s.Mailbox.maxClaims())
	if err != nil {
		// Loud: at the cap this is a flood, and the operator cannot see it
		// anywhere else.
		s.logf("api: mailbox callback for %s: %v", userID, err)
		writeMailboxUnavailable(w)
		return
	}
	// The Location header carries a secret, so it must not be cached or
	// stored anywhere on the way. writeJSON sets this for every JSON answer;
	// a redirect does not go through it.
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, mailboxCallbackPage+"?claim="+url.QueryEscape(claim), http.StatusSeeOther)
}

// writeMailboxCeremonyOver ends a ceremony that cannot complete by redirecting
// the popup to the SAME callback page a success uses, carrying ?error= in place
// of ?claim=. The page's script broadcasts the outcome on the mailbox channel
// and closes the window, so the app that opened the popup learns the ceremony
// is over instead of waiting on a claim that will never arrive (Task 9, §2.1).
//
// It is not the credential refusal, and it is read by a BROWSER in a popup, not
// by the app; the single ?error= value it carries (mailboxCallbackErrorDenied)
// says nothing about any credential the caller holds and does not vary between
// the branches that reach here.
func writeMailboxCeremonyOver(w http.ResponseWriter, r *http.Request) {
	// The error value is not a secret, but no-store matches the claim redirect
	// and keeps the popup's one navigation out of any cache all the same.
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, mailboxCallbackPage+"?error="+mailboxCallbackErrorDenied, http.StatusSeeOther)
}

// handleMailboxClaim hands one ceremony's tokens to the session that began
// it, and records the grant.
//
// The session check is the ceremony's whole binding: mailbox.States.Claim
// happens in the callback, which has no session to compare against, so §2.1
// puts the check HERE — the caller must be the user the state row named.
func (s *Server) handleMailboxClaim(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	var req MailboxClaimRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}

	var entry mailboxClaim
	var ok bool
	if req.ClaimCode == "" {
		// Poll path: the opener collects its own ceremony's tokens by session,
		// so the connect completes even when the popup could not hand the claim
		// code back to it (a COOP-severed BroadcastChannel, a stale worker that
		// mis-serves the callback page). A miss means the callback has not
		// finished the exchange yet, or nothing is in flight: 204, poll on.
		entry, ok = s.Mailbox.claims.spendByUser(userID, s.now())
		if !ok {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		s.logf("api: mailbox claim by %s: collected by session poll", userID)
	} else {
		entry, ok = s.Mailbox.claims.spend(req.ClaimCode, s.now())
		if !ok {
			s.logf("api: mailbox claim by %s: unknown, spent or expired claim code", userID)
			writeMailboxRefused(w)
			return
		}
		if entry.userID != userID {
			s.logf("api: mailbox claim by %s: the ceremony belongs to another account", userID)
			writeMailboxRefused(w)
			return
		}
	}
	if entry.tokens.RefreshToken == "" {
		// Google answered the exchange with no refresh token — what happens
		// when a re-consent is suppressed, which is exactly what
		// access_type=offline&prompt=consent exists to prevent. Storing the
		// grant anyway would pin it to sha256(""), a globally known digest,
		// and leave the account reading as connected while holding nothing.
		s.logf("api: mailbox claim by %s: google returned no refresh token; refusing to record a grant", userID)
		writeMailboxRefused(w)
		return
	}
	// The grant is recorded BEFORE the tokens are handed out. The other order
	// leaves a client holding a token this server has no digest for, which
	// fails every later broker call with the same silence as a stolen one.
	if err := s.Mailbox.Grants.Upsert(r.Context(), userID, mailbox.ProviderGmail,
		mailbox.TokenHash(entry.tokens.RefreshToken)); err != nil {
		s.logf("api: mailbox claim by %s: upsert grant: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, MailboxClaimResponse{
		RefreshToken: entry.tokens.RefreshToken,
		AccessToken:  entry.tokens.AccessToken,
		IDToken:      entry.tokens.IDToken,
	})
}

// handleMailboxToken mints an access token for a refresh token the client
// holds.
//
// The digest check is what stops this route being an oracle (D3a): without
// it, any session could present any refresh token and have this server
// countersign it with the client secret.
func (s *Server) handleMailboxToken(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	var req MailboxTokenRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if !s.verifyMailboxToken(w, r, userID, req.RefreshToken) {
		return
	}
	toks, err := s.Mailbox.Google.Refresh(r.Context(), req.RefreshToken)
	switch {
	case err == nil:
	case errors.Is(err, mailbox.ErrInvalidGrant):
		// D10: a Testing-status refresh token expires after seven days, and
		// the same answer covers a revocation at Google. The row is FLIPPED,
		// not deleted, so the sender allowlist survives the reconnect.
		if mErr := s.Mailbox.Grants.MarkReconnect(r.Context(), userID); mErr != nil {
			s.logf("api: mailbox token for %s: mark reconnect: %v", userID, mErr)
		}
		s.logf("api: mailbox token for %s: google refused the refresh token", userID)
		writeMailboxRefused(w)
		return
	default:
		s.logf("api: mailbox token for %s: refresh: %v", userID, err)
		writeMailboxUnavailable(w)
		return
	}
	writeJSON(w, http.StatusOK, MailboxTokenResponse{
		AccessToken: toks.AccessToken,
		ExpiresIn:   toks.ExpiresIn,
	})
}

// handleMailboxRevoke disconnects at Google and removes the grant.
func (s *Server) handleMailboxRevoke(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	var req MailboxRevokeRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if !s.verifyMailboxToken(w, r, userID, req.RefreshToken) {
		return
	}
	switch err := s.Mailbox.Google.Revoke(r.Context(), req.RefreshToken); {
	case err == nil:
	case errors.Is(err, mailbox.ErrInvalidGrant):
		// Google does not know this token any more: it expired or was revoked
		// at Google. A dead token is a successfully revoked token, so the
		// disconnect CONTINUES — the alternative is a user whose token expired
		// being unable to disconnect at all.
		s.logf("api: mailbox revoke for %s: google no longer knows this token; treating it as revoked", userID)
	default:
		// The token may well still be live at Google, so the row stays and a
		// retry can finish the job. Deleting it here would leave a live grant
		// with nothing left that could reach it.
		s.logf("api: mailbox revoke for %s: %v", userID, err)
		writeMailboxUnavailable(w)
		return
	}
	if err := s.Mailbox.Grants.Delete(r.Context(), userID); err != nil {
		s.logf("api: mailbox revoke for %s: delete grant: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// verifyMailboxToken is the check both broker routes run before doing
// anything with a token a caller presented. It reports whether to continue and
// has already answered when it returns false.
func (s *Server) verifyMailboxToken(w http.ResponseWriter, r *http.Request, userID uuid.UUID, refresh string) bool {
	if refresh == "" {
		// Collapsed into the same refusal rather than a 400: "you sent no
		// token" and "you sent the wrong token" are both credential-shaped,
		// and one answer for both is one fewer thing to probe.
		s.logf("api: mailbox broker call by %s: no refresh token presented", userID)
		writeMailboxRefused(w)
		return false
	}
	switch err := s.Mailbox.Grants.VerifyAndTouch(r.Context(), userID, mailbox.TokenHash(refresh)); {
	case err == nil:
		return true
	case errors.Is(err, mailbox.ErrGrantMismatch):
		// ONE sentinel for "no grant", "wrong digest" and "someone else's
		// token", and one answer for all three. See the file header.
		s.logf("api: mailbox broker call by %s: grant verification failed", userID)
		writeMailboxRefused(w)
		return false
	default:
		s.logf("api: mailbox broker call by %s: verify grant: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return false
	}
}

// ---------------------------------------------------------------------------
// The grant
// ---------------------------------------------------------------------------

func (s *Server) handleMailboxGrant(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	grant, err := s.Mailbox.Grants.Get(r.Context(), userID)
	if err != nil {
		s.logf("api: mailbox grant for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if grant == nil {
		// Not connected is not an error, and not a credential refusal either.
		// See the file header for why it is spelled distinctly from the mux's
		// own not_found.
		writeErr(w, http.StatusNotFound, "no_grant", "")
		return
	}
	writeJSON(w, http.StatusOK, MailboxGrantResponse{
		Provider:  grant.Provider,
		Status:    grant.Status,
		CreatedAt: grant.CreatedAt,
	})
}

// handleMailboxDisconnect removes the grant row and nothing else.
//
// It says nothing to Google, deliberately: revoking needs the refresh token,
// which this server does not have and must not keep. The client calls POST
// /revoke when it still holds the token; this is the escape hatch for a
// device that has lost it, and what it leaves behind — a live grant at Google
// — is the user's to remove from their Google account page. The copy that
// says so lives client-side.
func (s *Server) handleMailboxDisconnect(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if err := s.Mailbox.Grants.Delete(r.Context(), userID); err != nil {
		s.logf("api: mailbox disconnect for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// Senders
// ---------------------------------------------------------------------------

// reMailboxDomain is the hostname grammar, the same one quarantine's
// reHostname holds for the allowlist it owns (unexported there, and the two
// lists are never compared against each other — this one is applied by the
// CLIENT to a fetched message's sender, and never by any SQL constraint).
//
// It is enforced because the alternative is silent: a user who types
// "https://dib.ae" or pastes "Bank <no-reply@dib.ae>" would get a row that
// simply never matches anything, with the product showing a trusted sender
// that trusts nothing.
var reMailboxDomain = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

func (s *Server) handleMailboxSenders(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	rows, err := s.Pool.Query(r.Context(),
		`SELECT domain FROM mailbox_senders WHERE user_id = $1 ORDER BY domain`, userID)
	if err != nil {
		s.logf("api: mailbox senders for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	defer rows.Close()
	// Never nil: an empty list must marshal as [] rather than null, or a
	// client's `for (const d of domains)` throws on a fresh account.
	out := MailboxSendersResponse{Domains: []string{}}
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			s.logf("api: mailbox senders for %s: scan: %v", userID, err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		out.Domains = append(out.Domains, d)
	}
	if err := rows.Err(); err != nil {
		s.logf("api: mailbox senders for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleMailboxAddSender adds one domain to the account's mailbox allowlist.
//
// # A forwarder is refused here, exactly as it is on the SMTP side
//
// The two lanes are separate scopes (see senders.ts's header), but the danger
// is identical and so is the answer. This list is consulted by fetch.ts's D4
// gate against the domain Gmail's own Authentication-Results VERIFIED — and for
// a message a human forwarded by hand, that domain is the forwarder itself
// (gmail.com), because the bank's signature did not survive the forward. A row
// saying "gmail.com" would therefore auto-import every Gmail-signed message in
// the mailbox: phishing, newsletters, anything. The op log is append-only, so
// each one of those is permanent on every device.
//
// origin.IsForwarderDomain is the single list, shared with origin.Decide and
// quarantine.Confirm rather than restated here, and it matches subdomains.
// The refusal is 409 forwarder_domain — the same status, code and shape
// quarantine's handleConfirmSender already answers with, for the same reason it
// gives there: the request is well formed and the domain is real; what is
// refused is the RELATIONSHIP being asserted.
//
// DELETE deliberately does NOT carry this check. A row that predates it — or
// arrives by any other route — must stay removable, and "this must not be
// trusted" is never the request to refuse.
func (s *Server) handleMailboxAddSender(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	domain, ok := decodeMailboxDomain(w, r)
	if !ok {
		return
	}
	if origin.IsForwarderDomain(domain) {
		writeErr(w, http.StatusConflict, "forwarder_domain",
			"that domain is a mail provider, not a bank. Trusting it would automatically import every message "+
				"that passes through your mailbox, not just your bank's. Trust the bank's own domain instead.")
		return
	}
	// The cap is enforced INSIDE the insert, so two concurrent adds cannot
	// both read a count below it and both write. ON CONFLICT DO NOTHING makes
	// re-adding a listed domain a success: a client retrying a request that
	// failed in transit must not see an error, and a retry must not be refused
	// at the cap for a row that is already there.
	limit := s.Mailbox.maxSenders()
	tag, err := s.Pool.Exec(r.Context(),
		`INSERT INTO mailbox_senders (user_id, domain)
		 SELECT $1, $2 WHERE (SELECT count(*) FROM mailbox_senders WHERE user_id = $1) < $3
		 ON CONFLICT DO NOTHING`,
		userID, domain, limit)
	if err != nil {
		s.logf("api: mailbox add sender for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if tag.RowsAffected() == 0 {
		// Nothing was written: either the domain was already listed, or the
		// cap refused it. Only the second is a failure.
		var listed bool
		if err := s.Pool.QueryRow(r.Context(),
			`SELECT EXISTS (SELECT 1 FROM mailbox_senders WHERE user_id = $1 AND domain = $2)`,
			userID, domain).Scan(&listed); err != nil {
			s.logf("api: mailbox add sender for %s: %v", userID, err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		if !listed {
			// A fact about the caller's own list, so it carries a detail.
			writeErr(w, http.StatusConflict, "too_many_senders",
				fmt.Sprintf("this account already lists %d sender domains, which is the limit", limit))
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMailboxRemoveSender(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	domain, ok := decodeMailboxDomain(w, r)
	if !ok {
		return
	}
	// A domain that was not on the list is still a 204: the caller's intent —
	// "this must not be trusted" — is satisfied either way, and answering 404
	// would make a double tap look like a failure.
	if _, err := s.Pool.Exec(r.Context(),
		`DELETE FROM mailbox_senders WHERE user_id = $1 AND domain = $2`, userID, domain); err != nil {
		s.logf("api: mailbox remove sender for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// decodeMailboxDomain reads and NORMALIZES the domain out of a request body.
// The stored spelling is the normalized one — quarantine.NormalizeDomain's
// rule, the one spelling rule this tree has for a stored hostname — so that a
// client comparing a fetched message's sender against this list is comparing
// against a string this server would also match.
func decodeMailboxDomain(w http.ResponseWriter, r *http.Request) (string, bool) {
	var req MailboxSenderRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return "", false
	}
	domain := quarantine.NormalizeDomain(req.Domain)
	if domain == "" || len(domain) > maxMailboxDomain || !reMailboxDomain.MatchString(domain) {
		writeErr(w, http.StatusBadRequest, "bad_request", "domain must be a plain hostname")
		return "", false
	}
	return domain, true
}

// mailboxRedirectURI builds the callback URL from the app's own origin.
//
// It is derived rather than configured separately because the two cannot come
// apart: the callback page has to be SAME-ORIGIN with the app for §2.1's
// BroadcastChannel hand-off to work at all, so the redirect origin is exactly
// the origin the PWA runs on — auth.rp_origins, which config has already
// validated as absolute origins and which the WebAuthn ceremony is bound to.
//
// The FIRST origin wins when several are configured. That is a deployment
// fact rather than a preference: Google redirects only to a URI registered in
// the Cloud console (spec §7), so a second origin needs its own registration
// there before it could ever be reached, and picking one here keeps the
// string this server signs its auth URLs with identical to the one an
// operator typed in.
func mailboxRedirectURI(origins []string) (string, error) {
	if len(origins) == 0 {
		return "", errors.New("mailbox.google_oauth_client_id is set but auth.rp_origins is empty; " +
			"the OAuth callback has no origin to return to, and the connect ceremony could never complete")
	}
	return strings.TrimSuffix(origins[0], "/") + mailboxCallbackPath, nil
}
