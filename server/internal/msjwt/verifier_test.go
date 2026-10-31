package msjwt

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"
)

// Hermetic: every key is generated here and served from an httptest server.
// No test reaches Microsoft. The addresses and ids are synthetic.

const (
	testClientID = "00000000-1111-4222-8333-444444444444"
	testOid      = "00000000-0000-0000-aaaa-bbbbbbbbbbbb"
	testEmail    = "someone@outlook.example"
	// The work-and-school tenant of a made-up organisation.
	otherTenant = "11111111-2222-4333-8444-555555555555"
)

var bg = context.Background()

type key struct {
	kid string
	rsa *rsa.PrivateKey
}

var keys = sync.OnceValue(func() [2]*key {
	gen := func(kid string) *key {
		k, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
		return &key{kid: kid, rsa: k}
	}
	return [2]*key{gen("ms-1"), gen("attacker")}
})

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// jwks serves k the way Microsoft publishes its keys: kid, x5t and a use.
func jwks(t *testing.T, k *key) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{
			"kty": "RSA", "use": "sig", "kid": k.kid, "x5t": x5t(k),
			"n": b64(k.rsa.PublicKey.N.Bytes()), "e": b64(big.NewInt(int64(k.rsa.PublicKey.E)).Bytes()),
			"issuer": ConsumersIssuer,
		}}})
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// x5t is a stand-in SHA-1 thumbprint; no certificate is published with it.
func x5t(k *key) string {
	sum := sha256.Sum256([]byte(k.kid))
	return b64(sum[:20])
}

func seg(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b64(b)
}

func mint(t *testing.T, k *key, hdrOver, claims map[string]any) string {
	t.Helper()
	hdr := map[string]any{"typ": "JWT", "alg": "RS256", "kid": k.kid}
	for n, v := range hdrOver {
		if v == nil {
			delete(hdr, n)
		} else {
			hdr[n] = v
		}
	}
	in := seg(t, hdr) + "." + seg(t, claims)
	sum := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, k.rsa, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return in + "." + b64(sig)
}

var now = time.Date(2026, 10, 15, 9, 0, 0, 0, time.UTC)

// consumerClaims is the shape of a personal account's v2.0 ID token; a nil
// in over deletes a claim.
func consumerClaims(over map[string]any) map[string]any {
	c := map[string]any{
		"ver": "2.0", "iss": ConsumersIssuer, "sub": "AAAAAAAAAAAAAAAAAAAAAL-synthetic", "aud": testClientID,
		"exp": now.Add(time.Hour).Unix(), "iat": now.Add(-time.Minute).Unix(), "nbf": now.Add(-time.Minute).Unix(),
		"tid": ConsumersTenantID, "oid": testOid, "email": testEmail, "preferred_username": testEmail,
		"nonce": "bm9uY2U", "aio": "synthetic",
	}
	for n, v := range over {
		if v == nil {
			delete(c, n)
		} else {
			c[n] = v
		}
	}
	return c
}

func verifier(t *testing.T) *Verifier {
	t.Helper()
	return &Verifier{Audience: testClientID, JWKSURL: jwks(t, keys()[0]), Now: func() time.Time { return now }}
}

func mustReject(t *testing.T, v *Verifier, tok string, want error) {
	t.Helper()
	got, err := v.Verify(bg, tok)
	if !errors.Is(err, want) || !errors.Is(err, ErrTokenRejected) {
		t.Fatalf("Verify = %+v, %v; want %v", got, err, want)
	}
	if !reflect.DeepEqual(got, Claims{}) {
		t.Fatalf("a rejected token yielded claims %+v", got)
	}
}

func TestAConsumerTokenVerifies(t *testing.T) {
	v := verifier(t)
	c, err := v.Verify(bg, mint(t, keys()[0], map[string]any{"x5t": x5t(keys()[0])}, consumerClaims(nil)))
	if err != nil {
		t.Fatal(err)
	}
	if !c.Iat.Equal(now.Add(-time.Minute)) {
		t.Fatalf("iat %s", c.Iat)
	}
	c.Iat = time.Time{}
	want := Claims{Tid: ConsumersTenantID, Oid: testOid, Sub: "AAAAAAAAAAAAAAAAAAAAAL-synthetic", Email: testEmail, PreferredUsername: testEmail,
		Nonce: "bm9uY2U", Aud: []string{testClientID}}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("claims %+v, want %+v", c, want)
	}
	if c.Address() != testEmail {
		t.Fatalf("address %q", c.Address())
	}
}

func TestTheTenantMustBeConsumers(t *testing.T) {
	v := verifier(t)
	// The consumers issuer with another tid, and the other tid's own issuer.
	mustReject(t, v, mint(t, keys()[0], nil, consumerClaims(map[string]any{"tid": otherTenant})), ErrTenant)
	mustReject(t, v, mint(t, keys()[0], nil, consumerClaims(map[string]any{"tid": nil})), ErrTenant)
	mustReject(t, v, mint(t, keys()[0], nil, consumerClaims(map[string]any{
		"tid": otherTenant, "iss": "https://login.microsoftonline.com/" + otherTenant + "/v2.0"})), ErrTokenRejected)
}

func TestTheAudienceIsTheOutlookClient(t *testing.T) {
	v := verifier(t)
	mustReject(t, v, mint(t, keys()[0], nil, consumerClaims(map[string]any{"aud": "another-client"})), ErrTokenRejected)
	// A verifier with no audience refuses everything.
	mustReject(t, &Verifier{JWKSURL: jwks(t, keys()[0]), Now: func() time.Time { return now }},
		mint(t, keys()[0], nil, consumerClaims(nil)), ErrTokenRejected)
}

func TestForgeriesAreRefused(t *testing.T) {
	v := verifier(t)
	// Signed by a key Microsoft does not publish, under its kid or its own.
	mustReject(t, v, mint(t, keys()[1], map[string]any{"kid": keys()[0].kid}, consumerClaims(nil)), ErrTokenRejected)
	mustReject(t, v, mint(t, keys()[1], nil, consumerClaims(nil)), ErrTokenRejected)
	// Key material in the header.
	mustReject(t, v, mint(t, keys()[0], map[string]any{"x5c": []string{"MIIB"}}, consumerClaims(nil)), ErrTokenRejected)
	mustReject(t, v, mint(t, keys()[0], map[string]any{"jku": "https://evil.example/keys"}, consumerClaims(nil)), ErrTokenRejected)
	// Not RS256.
	mustReject(t, v, mint(t, keys()[0], map[string]any{"alg": "HS256"}, consumerClaims(nil)), ErrTokenRejected)
	// Expired.
	mustReject(t, v, mint(t, keys()[0], nil, consumerClaims(map[string]any{"exp": now.Add(-time.Second).Unix()})), ErrTokenRejected)
}

func TestAnUnreachableKeySetIsNotARejection(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)
	v := &Verifier{Audience: testClientID, JWKSURL: srv.URL, Now: func() time.Time { return now }}
	_, err := v.Verify(bg, mint(t, keys()[0], nil, consumerClaims(nil)))
	if !errors.Is(err, ErrKeySetUnavailable) || errors.Is(err, ErrTokenRejected) {
		t.Fatalf("err %v, want only ErrKeySetUnavailable", err)
	}
}

func TestTheAddress(t *testing.T) {
	for _, c := range []struct {
		email, upn, want string
	}{
		{testEmail, "other@outlook.example", testEmail},
		{"", testEmail, testEmail},
		{"", "+971500000000", ""},
		{"", "", ""},
	} {
		if got := (Claims{Email: c.email, PreferredUsername: c.upn}).Address(); got != c.want {
			t.Errorf("Address(%q, %q) = %q, want %q", c.email, c.upn, got, c.want)
		}
	}
}
