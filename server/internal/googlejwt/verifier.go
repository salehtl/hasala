// Package googlejwt verifies Google-signed JWTs: the OIDC token Google Pub/Sub
// attaches to every push to POST /hooks/gmail/pubsub, and the Google ID token
// the app sends when it links a mailbox (spec 02 §13.6). It never signs anyone
// in and never holds a Google credential.
//
// It is ledgerd's auth/idp.go with the sign-in parts removed (spec 02 §2.3):
// the JWKS cache (keyset.go: a 1 minute refresh floor, a 1 hour stale ceiling,
// a single-flight fetch detached from the caller, a 256 KiB document cap and a
// 10 s fetch timeout), the forbidden-header list and the 16 KiB token cap are
// kept as they were reviewed. What changed: Google only, RS256 only, one exact
// audience per Verifier, and the claims a caller needs (azp, email,
// email_verified) are returned from the authenticated payload.
//
// # Verification: library, not hand-rolled
//
// Signature verification is delegated to github.com/coreos/go-oidc/v3 over
// go-jose. The checks this package performs on the parsed but not yet
// verified payload exist only to name a rejection and to refuse obvious junk
// without spending a JWKS fetch; every decision is re-made on the payload
// go-oidc authenticated.
package googlejwt

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Google's issuer and JWKS location. Google documents its `iss` as EITHER the
// URL form or the bare host, and issues both; go-oidc carries the same
// carve-out. A Verifier with no Issuers configured accepts exactly these two.
const (
	GoogleIssuer         = "https://accounts.google.com"
	GoogleIssuerNoScheme = "accounts.google.com"
	GoogleJWKSURL        = "https://www.googleapis.com/oauth2/v3/certs"
)

// DefaultLeeway is the clock-skew allowance for nbf and iat.
const DefaultLeeway = 5 * time.Minute

// Errors. Every rejection wraps ErrTokenRejected; ErrKeySetUnavailable is
// deliberately NOT one of them, so "Google's key set is down" stays
// distinguishable from "this token is forged".
var (
	ErrTokenRejected   = errors.New("googlejwt: token rejected")
	ErrMalformed       = fmt.Errorf("%w: malformed token", ErrTokenRejected)
	ErrAlgorithm       = fmt.Errorf("%w: unacceptable signing algorithm", ErrTokenRejected)
	ErrUntrustedHeader = fmt.Errorf("%w: unacceptable token header", ErrTokenRejected)
	ErrIssuer          = fmt.Errorf("%w: wrong issuer", ErrTokenRejected)
	ErrAudience        = fmt.Errorf("%w: wrong audience", ErrTokenRejected)
	ErrExpired         = fmt.Errorf("%w: expired", ErrTokenRejected)
	ErrNotYetValid     = fmt.Errorf("%w: not yet valid", ErrTokenRejected)
	ErrSignature       = fmt.Errorf("%w: signature not verified by the provider's JWKS", ErrTokenRejected)
	ErrNoSubject       = fmt.Errorf("%w: no subject", ErrTokenRejected)
	ErrNotConfigured   = fmt.Errorf("%w: verifier is not configured", ErrTokenRejected)

	ErrKeySetUnavailable = errors.New("googlejwt: provider key set is unavailable")
)

// Verifier checks one kind of Google-signed token. The zero value is not
// usable: Audience is required. Two instances exist in serve (spec 02 §13.6):
// one for Pub/Sub (audience = the push URL), one for link ID tokens (audience
// = the iOS client id). Fields must not change after the first Verify.
type Verifier struct {
	Issuers  []string      // default {GoogleIssuer, GoogleIssuerNoScheme}
	Audience string        // exact match against aud (a string, or an array containing it)
	JWKSURL  string        // default GoogleJWKSURL
	Leeway   time.Duration // for nbf and iat; default DefaultLeeway
	Now      func() time.Time

	// refresh overrides the JWKS refresh floor; tests only.
	refresh time.Duration

	once      sync.Once
	configErr error
	issuers   []string
	leeway    time.Duration
	now       func() time.Time
	keys      *cachingKeySet
	inner     *oidc.IDTokenVerifier
}

// Claims are the authenticated claims a caller may use.
type Claims struct {
	Iss, Sub, Azp, Email, Nonce string
	Aud                         []string
	EmailVerified               bool // accepts JSON true or "true"
	Iat, Exp                    time.Time
}

func (v *Verifier) init() {
	v.now = v.Now
	if v.now == nil {
		v.now = time.Now
	}
	v.leeway = v.Leeway
	if v.leeway <= 0 {
		v.leeway = DefaultLeeway
	}
	for _, iss := range v.Issuers {
		if iss = strings.TrimSpace(iss); iss != "" {
			v.issuers = append(v.issuers, iss)
		}
	}
	if len(v.Issuers) == 0 {
		v.issuers = []string{GoogleIssuer, GoogleIssuerNoScheme}
	}
	jwksURL := v.JWKSURL
	if jwksURL == "" {
		jwksURL = GoogleJWKSURL
	}
	switch {
	case strings.TrimSpace(v.Audience) == "":
		// The dangerous one: with go-oidc's client-id check skipped and no
		// audience of our own, "accept anything" would be one missing return
		// away. A misconfigured verifier rejects every token instead.
		v.configErr = fmt.Errorf("%w: no audience configured", ErrNotConfigured)
		return
	case len(v.issuers) == 0:
		v.configErr = fmt.Errorf("%w: no issuer configured", ErrNotConfigured)
		return
	}
	refresh := v.refresh
	if refresh <= 0 {
		refresh = jwksRefresh
	}
	v.keys = &cachingKeySet{jwksURL: jwksURL, refresh: refresh, staleMax: jwksStaleMax, now: v.now}
	// The issuer and the audience are checked by this package (several
	// accepted issuers, one exact audience), so go-oidc skips both; it stays
	// the authority for the signature, the algorithm allow-list, exp and nbf.
	v.inner = oidc.NewVerifier(v.issuers[0], v.keys, &oidc.Config{
		SkipClientIDCheck:    true,
		SkipIssuerCheck:      true,
		SupportedSigningAlgs: []string{oidc.RS256},
		Now:                  v.now,
	})
}

// Verify authenticates token and returns its claims, or an error wrapping
// ErrTokenRejected (or ErrKeySetUnavailable). It performs no network I/O
// except the rate-limited JWKS refresh.
func (v *Verifier) Verify(ctx context.Context, token string) (Claims, error) {
	v.once.Do(v.init)
	if v.configErr != nil {
		return Claims{}, v.configErr
	}
	hdr, pre, err := parseUnverified(token)
	if err != nil {
		return Claims{}, err
	}
	if err := checkHeader(hdr); err != nil {
		return Claims{}, err
	}
	if err := v.checkClaims(pre); err != nil {
		return Claims{}, err
	}
	// Obtain the keys first, so an unavailable key set is reported as itself
	// (go-oidc wraps KeySet errors with %v, which loses the chain).
	if _, err := v.keys.currentKeys(ctx); err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrKeySetUnavailable, err)
	}
	tok, err := v.inner.Verify(ctx, token)
	if err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrSignature, err)
	}
	var c idClaims
	if err := tok.Claims(&c); err != nil {
		return Claims{}, fmt.Errorf("%w: verified payload: %v", ErrMalformed, err)
	}
	// Every decision again, on the authenticated payload.
	if err := v.checkClaims(c); err != nil {
		return Claims{}, err
	}
	out := Claims{
		Iss: c.Issuer, Sub: c.Subject, Azp: c.Azp, Email: c.Email, Nonce: c.Nonce,
		Aud: append([]string(nil), c.Audience...), EmailVerified: bool(c.EmailVerified),
		Iat: iatOf(c.IssuedAt),
	}
	if c.Expiry != nil {
		out.Exp = c.Expiry.t
	}
	return out, nil
}

// forbiddenHeaders are the JOSE header parameters that either carry key
// material or point at it. A verifier that honours any of them is verifying
// the attacker's signature against the attacker's key.
var forbiddenHeaders = []string{"jwk", "jku", "x5u", "x5c", "crit"}

func checkHeader(hdr map[string]json.RawMessage) error {
	for _, h := range forbiddenHeaders {
		if _, ok := hdr[h]; ok {
			return fmt.Errorf("%w: header %q", ErrUntrustedHeader, h)
		}
	}
	// `typ` is optional but, when present, must say JWT (case-insensitive; the
	// "application/" prefix may be omitted, RFC 7519).
	if raw, ok := hdr["typ"]; ok {
		var typ string
		if err := json.Unmarshal(raw, &typ); err != nil {
			return fmt.Errorf("%w: typ header is not a string", ErrMalformed)
		}
		switch strings.ToLower(typ) {
		case "jwt", "application/jwt":
		default:
			return fmt.Errorf("%w: typ %q is not a JWT", ErrUntrustedHeader, typ)
		}
	}
	var alg string
	if raw, ok := hdr["alg"]; ok {
		if err := json.Unmarshal(raw, &alg); err != nil {
			return fmt.Errorf("%w: alg header is not a string", ErrMalformed)
		}
	}
	if alg != oidc.RS256 {
		return fmt.Errorf("%w: %q (want %s)", ErrAlgorithm, alg, oidc.RS256)
	}
	return nil
}

func (v *Verifier) checkClaims(c idClaims) error {
	if !slices.Contains(v.issuers, c.Issuer) {
		return fmt.Errorf("%w: token issued by %q, want one of %q", ErrIssuer, c.Issuer, v.issuers)
	}
	now := v.now()
	if c.Expiry == nil {
		return fmt.Errorf("%w: token has no exp claim", ErrExpired)
	}
	if !c.Expiry.t.After(now) {
		return fmt.Errorf("%w: exp %s, now %s", ErrExpired, c.Expiry.t.UTC(), now.UTC())
	}
	if c.NotBefore != nil && now.Add(v.leeway).Before(c.NotBefore.t) {
		return fmt.Errorf("%w: nbf %s, now %s", ErrNotYetValid, c.NotBefore.t.UTC(), now.UTC())
	}
	if iat := iatOf(c.IssuedAt); !iat.IsZero() && iat.After(now.Add(v.leeway)) {
		return fmt.Errorf("%w: iat %s is in the future", ErrNotYetValid, iat.UTC())
	}
	if !v.audienceAllowed(c.Audience) {
		return fmt.Errorf("%w: aud %q does not contain the configured audience", ErrAudience, []string(c.Audience))
	}
	if c.Subject == "" {
		return ErrNoSubject
	}
	return nil
}

// audienceAllowed is the only audience check there is (go-oidc's is skipped).
// The comparison is exact and constant-time; an empty entry never matches.
func (v *Verifier) audienceAllowed(aud []string) bool {
	want := []byte(v.Audience)
	for _, got := range aud {
		if got != "" && subtle.ConstantTimeCompare([]byte(got), want) == 1 {
			return true
		}
	}
	return false
}

func iatOf(n *numericDate) time.Time {
	if n == nil {
		return time.Time{}
	}
	return n.t
}

// ---------------------------------------------------------------------------
// Unverified pre-parse
// ---------------------------------------------------------------------------

// idClaims is the subset of a token this package inspects.
type idClaims struct {
	Issuer        string       `json:"iss"`
	Subject       string       `json:"sub"`
	Audience      audienceSet  `json:"aud"`
	Azp           string       `json:"azp"`
	Email         string       `json:"email"`
	EmailVerified looseBool    `json:"email_verified"`
	Nonce         string       `json:"nonce"`
	Expiry        *numericDate `json:"exp"`
	NotBefore     *numericDate `json:"nbf"`
	IssuedAt      *numericDate `json:"iat"`

	// Aggregated/distributed claims (OIDC Core §5.6.2): Google issues none and
	// this package implements none, so a token carrying them is refused.
	ClaimNames   map[string]any `json:"_claim_names"`
	ClaimSources map[string]any `json:"_claim_sources"`
}

// audienceSet accepts both shapes RFC 7519 permits for `aud`.
type audienceSet []string

func (a *audienceSet) UnmarshalJSON(b []byte) error {
	var one string
	if err := json.Unmarshal(b, &one); err == nil {
		*a = audienceSet{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return errors.New("aud is neither a string nor an array of strings")
	}
	*a = many
	return nil
}

// looseBool is Google's email_verified: JSON true, or the string "true".
// Anything else (absent, false, "false", junk) is false.
type looseBool bool

func (l *looseBool) UnmarshalJSON(b []byte) error {
	var v bool
	if err := json.Unmarshal(b, &v); err == nil {
		*l = looseBool(v)
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		*l = looseBool(s == "true")
		return nil
	}
	*l = false
	return nil
}

// numericDate is an RFC 7519 NumericDate. Fractional seconds are truncated,
// matching go-oidc, so the two never disagree by a rounding step.
type numericDate struct{ t time.Time }

func (n *numericDate) UnmarshalJSON(b []byte) error {
	var num json.Number
	if err := json.Unmarshal(b, &num); err != nil {
		return err
	}
	if i, err := num.Int64(); err == nil {
		n.t = time.Unix(i, 0)
		return nil
	}
	f, err := num.Float64()
	if err != nil {
		return err
	}
	n.t = time.Unix(int64(f), 0)
	return nil
}

// maxTokenBytes caps what this package will even look at: Verify is reachable
// by an unauthenticated caller and the first thing it does is base64-decode
// two attacker-sized segments. Google's tokens are about 1 KB.
const maxTokenBytes = 16 << 10

// parseUnverified splits a compact JWS and decodes its header and payload
// WITHOUT checking anything. Its output may only be used to reject.
func parseUnverified(token string) (map[string]json.RawMessage, idClaims, error) {
	if len(token) > maxTokenBytes {
		return nil, idClaims{}, fmt.Errorf("%w: %d bytes, cap is %d", ErrMalformed, len(token), maxTokenBytes)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, idClaims{}, fmt.Errorf("%w: %d segments, want 3", ErrMalformed, len(parts))
	}
	rawHdr, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, idClaims{}, fmt.Errorf("%w: header is not base64url", ErrMalformed)
	}
	rawPayload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, idClaims{}, fmt.Errorf("%w: payload is not base64url", ErrMalformed)
	}
	var hdr map[string]json.RawMessage
	if err := json.Unmarshal(rawHdr, &hdr); err != nil {
		return nil, idClaims{}, fmt.Errorf("%w: header is not a JSON object", ErrMalformed)
	}
	var claims idClaims
	if err := json.Unmarshal(rawPayload, &claims); err != nil {
		return nil, idClaims{}, fmt.Errorf("%w: payload is not valid claims JSON: %v", ErrMalformed, err)
	}
	if len(claims.ClaimNames) > 0 || len(claims.ClaimSources) > 0 {
		return nil, idClaims{}, fmt.Errorf("%w: aggregated/distributed claims are not supported", ErrMalformed)
	}
	return hdr, claims, nil
}
