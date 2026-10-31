// Package msjwt verifies the Microsoft ID token the app sends when it links an
// Outlook mailbox: a v2.0 token from the consumers tenant, so personal
// Microsoft accounts only. It never signs anyone in and never holds a
// Microsoft credential.
//
// # One verifier, not two
//
// The JWT checks are googlejwt's, configured for Microsoft's issuer and key
// set: the JWKS cache (a refresh on a clock, never on a failed token; a single
// detached fetch; a stale ceiling), the forbidden-header list (jwk, jku, x5u,
// x5c, crit), RS256 only, the 16 KiB cap, one exact audience, and go-oidc over
// go-jose for the signature. Keys are chosen by kid; an x5t header is allowed
// and not used. Copying that code here would leave two copies of the part of
// the server that is easiest to get wrong.
//
// What this package adds is Microsoft's claims. They are read from the same
// payload segment googlejwt has just authenticated, after it succeeds, and
// never before.
package msjwt

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/salehtl/hasala/server/internal/googlejwt"
)

// The consumers tenant: personal Microsoft accounts (outlook.com, hotmail.com,
// live.com). Its issuer is fixed, and the key set is named in full, because
// the server does no OpenID discovery.
const (
	ConsumersTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
	ConsumersIssuer   = "https://login.microsoftonline.com/" + ConsumersTenantID + "/v2.0"
	ConsumersJWKSURL  = "https://login.microsoftonline.com/consumers/discovery/v2.0/keys"
)

// Errors. Every rejection wraps ErrTokenRejected; ErrKeySetUnavailable is
// not one of them, so "Microsoft's key set is down" stays distinguishable
// from "this token is forged". They are googlejwt's own values.
var (
	ErrTokenRejected     = googlejwt.ErrTokenRejected
	ErrKeySetUnavailable = googlejwt.ErrKeySetUnavailable
	ErrMalformed         = googlejwt.ErrMalformed
	ErrTenant            = fmt.Errorf("%w: not the consumers tenant", ErrTokenRejected)
)

// Verifier checks a Microsoft ID token for one application. The zero value
// is not usable: Audience is required. Fields must not change after the
// first Verify.
type Verifier struct {
	Audience string // the Outlook application (client) id
	JWKSURL  string // default ConsumersJWKSURL; tests only
	Now      func() time.Time

	once  sync.Once
	inner *googlejwt.Verifier
}

// Claims are the authenticated claims a caller may use. Microsoft's v2.0
// tokens carry neither email_verified nor azp.
type Claims struct {
	Tid, Oid, Sub, Email, PreferredUsername, Nonce string
	Aud                                       []string
	Iat                                       time.Time
}

func (v *Verifier) init() {
	jwks := v.JWKSURL
	if jwks == "" {
		jwks = ConsumersJWKSURL
	}
	v.inner = &googlejwt.Verifier{
		Issuers:  []string{ConsumersIssuer},
		Audience: v.Audience,
		JWKSURL:  jwks,
		Now:      v.Now,
	}
}

// Verify authenticates token and returns its claims, or an error wrapping
// ErrTokenRejected (or ErrKeySetUnavailable). It performs no network I/O
// except the rate-limited JWKS refresh.
func (v *Verifier) Verify(ctx context.Context, token string) (Claims, error) {
	v.once.Do(v.init)
	g, err := v.inner.Verify(ctx, token)
	if err != nil {
		return Claims{}, err
	}
	// googlejwt verified the signature over exactly these bytes, so this is
	// the authenticated payload, decoded a second time for the claims it does
	// not return.
	var ms struct {
		Tid               string `json:"tid"`
		Oid               string `json:"oid"`
		PreferredUsername string `json:"preferred_username"`
	}
	parts := strings.Split(token, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(raw, &ms) != nil {
		return Claims{}, fmt.Errorf("%w: verified payload", ErrMalformed)
	}
	if ms.Tid != ConsumersTenantID {
		return Claims{}, fmt.Errorf("%w: tid %q", ErrTenant, ms.Tid)
	}
	return Claims{
		Tid: ms.Tid, Oid: ms.Oid, Sub: g.Sub, Email: g.Email, PreferredUsername: ms.PreferredUsername, Nonce: g.Nonce,
		Aud: g.Aud, Iat: g.Iat,
	}, nil
}

// Address is the mailbox the token names: email, or preferred_username when
// it looks like an address. Personal accounts may have no email claim when
// the app's registration does not ask for it as an optional claim.
func (c Claims) Address() string {
	if c.Email != "" {
		return c.Email
	}
	if strings.Contains(c.PreferredUsername, "@") {
		return c.PreferredUsername
	}
	return ""
}
