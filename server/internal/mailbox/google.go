package mailbox

// The only code in this package (in this repo — see the package doc's D2
// note) that talks to Google. It knows exactly three endpoints — auth,
// token, revoke — configured, not hard-coded (config.MailboxConfig), so a
// test or the harness's --gmail-fixtures can point it at a local fake
// (internal/mailbox/fakegoogle) instead of the real
// oauth2.googleapis.com. There is deliberately no Gmail API base URL, no
// messages.get, no history.list: this package brokers the OAuth exchange
// and nothing past it (D2).
//
// The HTTP client follows internal/pushv2/webpush.go's house style: a
// per-package client with a timeout and no retries. A retry here would
// resend a code or a refresh token to Google a second time on a timeout
// whose first attempt may already have succeeded — Google's token endpoint
// is not documented as idempotent under retry, so the safer failure is
// "the caller sees an error and may ask again," not a silent double-spend
// of a single-use authorization code.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// googleTimeout bounds one request to Google. Long enough for a normal
// round trip to accounts.google.com/oauth2.googleapis.com; short enough that
// a stalled request does not hold an HTTP handler goroutine (and, on the
// callback path, a browser waiting on a redirect) open indefinitely.
const googleTimeout = 10 * time.Second

// oauthScopes is exactly what D3's ceremony diagram and the brief specify:
// identity (so the callback can show the connected burner's address from
// the id_token, D11) plus read-only Gmail. No broader Gmail scope is ever
// requested — D10 notes gmail.metadata cannot feed the parser, and nothing
// broader than .readonly is needed because this server never reads a
// message itself.
const oauthScopes = "openid email https://www.googleapis.com/auth/gmail.readonly"

// ErrInvalidGrant is Google's invalid_grant answer, surfaced as a sentinel
// so a caller (Task 4's /token route) can tell "this specific refresh token
// is dead at Google" apart from an ordinary infrastructure failure and flip
// the grant to reconnect_required (D10: Testing-status refresh tokens
// expire after 7 days; the same error covers an explicit revocation at
// Google).
var ErrInvalidGrant = errors.New("mailbox: google refused the credential (invalid_grant)")

// Google is the OAuth client for the Gmail transaction-mailbox broker. Every
// field is configuration (config.MailboxConfig), not a secret this package
// invents: ClientSecret is the one exception, and it never appears in a log
// line or an error this package returns.
type Google struct {
	ClientID     string
	ClientSecret string
	AuthURL      string
	TokenURL     string
	RevokeURL    string
	// HTTP defaults to a client with googleTimeout and no retries.
	HTTP *http.Client
}

// Tokens is what Google's token endpoint hands back, held only in memory
// for the span of one call — see the package doc's D3 section for why
// nothing here is ever written to disk by this package.
type Tokens struct {
	RefreshToken string
	AccessToken  string
	IDToken      string
	ExpiresIn    int
}

func (g *Google) client() *http.Client {
	if g.HTTP != nil {
		return g.HTTP
	}
	return &http.Client{Timeout: googleTimeout}
}

// AuthURLFor builds the URL the browser is sent to for Google's consent
// screen. access_type=offline and prompt=consent are both required for
// Google to hand back a refresh token on every connect, not only the
// first — without prompt=consent a returning user who already granted this
// scope gets no refresh_token at all on a second consent, which would leave
// the broker with nothing to store.
func (g *Google) AuthURLFor(state, pkceChallenge, redirectURI string) string {
	v := url.Values{}
	v.Set("client_id", g.ClientID)
	v.Set("redirect_uri", redirectURI)
	v.Set("response_type", "code")
	v.Set("scope", oauthScopes)
	v.Set("access_type", "offline")
	v.Set("prompt", "consent")
	v.Set("state", state)
	v.Set("code_challenge", pkceChallenge)
	v.Set("code_challenge_method", "S256")
	return g.AuthURL + "?" + v.Encode()
}

// PKCEChallengeS256 derives the RFC 7636 §4.2 S256 code_challenge for a
// verifier minted by [States.Begin]. It is a pure function of the verifier
// (no Google round trip), exported so the caller that builds the auth URL
// (Task 4's begin handler) and this package's own tests compute the
// identical value from one implementation rather than two.
func PKCEChallengeS256(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// Exchange trades an authorization code for tokens. redirectURI must be
// byte-identical to the one the auth URL was built with — Google refuses
// the exchange otherwise.
func (g *Google) Exchange(ctx context.Context, code, pkceVerifier, redirectURI string) (Tokens, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("client_id", g.ClientID)
	form.Set("client_secret", g.ClientSecret)
	form.Set("redirect_uri", redirectURI)
	form.Set("code_verifier", pkceVerifier)
	return g.postToken(ctx, form)
}

// Refresh trades a refresh token for a new access token. Google's refresh
// grant never echoes the refresh token back — the caller already holds the
// only copy — so the returned Tokens.RefreshToken is refreshToken itself,
// not anything read off the wire, which is what lets a caller treat every
// Tokens value the same way regardless of which method produced it.
func (g *Google) Refresh(ctx context.Context, refreshToken string) (Tokens, error) {
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", refreshToken)
	form.Set("client_id", g.ClientID)
	form.Set("client_secret", g.ClientSecret)
	toks, err := g.postToken(ctx, form)
	if err != nil {
		return Tokens{}, err
	}
	toks.RefreshToken = refreshToken
	return toks, nil
}

func (g *Google) postToken(ctx context.Context, form url.Values) (Tokens, error) {
	if g.TokenURL == "" {
		return Tokens{}, errors.New("mailbox: Google.TokenURL is empty")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return Tokens{}, fmt.Errorf("mailbox: build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := g.client().Do(req)
	if err != nil {
		return Tokens{}, fmt.Errorf("mailbox: token request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Tokens{}, fmt.Errorf("mailbox: read token response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return Tokens{}, googleError(resp.StatusCode, body)
	}
	var wire struct {
		RefreshToken string `json:"refresh_token"`
		AccessToken  string `json:"access_token"`
		IDToken      string `json:"id_token"`
		ExpiresIn    int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		return Tokens{}, fmt.Errorf("mailbox: decode token response: %w", err)
	}
	return Tokens{
		RefreshToken: wire.RefreshToken,
		AccessToken:  wire.AccessToken,
		IDToken:      wire.IDToken,
		ExpiresIn:    wire.ExpiresIn,
	}, nil
}

// Revoke tells Google to invalidate a refresh token (and every access token
// minted from it). It is called on disconnect; the grant row itself is
// removed separately by Grants.Delete.
func (g *Google) Revoke(ctx context.Context, refreshToken string) error {
	if g.RevokeURL == "" {
		return errors.New("mailbox: Google.RevokeURL is empty")
	}
	form := url.Values{}
	form.Set("token", refreshToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.RevokeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("mailbox: build revoke request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := g.client().Do(req)
	if err != nil {
		return fmt.Errorf("mailbox: revoke request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		return googleError(resp.StatusCode, body)
	}
	return nil
}

// googleError turns Google's {"error": "...", "error_description": "..."}
// error body into a Go error, recognizing invalid_grant as the one shape
// callers need to act on differently. The response body here is Google's
// own diagnostic text, never a token — nothing this function reads or
// returns can be a refresh or access token.
func googleError(status int, body []byte) error {
	var e struct {
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
	}
	_ = json.Unmarshal(body, &e) // best effort; a non-JSON body still gets a status-coded error below
	if e.Error == "invalid_grant" {
		return ErrInvalidGrant
	}
	if e.Error != "" {
		return fmt.Errorf("mailbox: google refused the request: %s (status %d)", e.Error, status)
	}
	return fmt.Errorf("mailbox: google token endpoint returned status %d", status)
}
