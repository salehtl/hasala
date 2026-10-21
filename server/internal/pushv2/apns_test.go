package pushv2

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

var bg = context.Background()

func testKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return k, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

// fakeAPNs is an APNs stand-in over TLS with HTTP/2. It records every request
// and answers from a script keyed by token.
type fakeAPNs struct {
	srv *httptest.Server
	mu  sync.Mutex
	got []seen
	// answer returns (status, reason) for a token; nil = 200.
	answer func(token string, n int) (int, string)
}

type seen struct {
	path   string
	header http.Header
	body   []byte
	proto  int
}

func newFakeAPNs(t *testing.T) *fakeAPNs {
	f := &fakeAPNs{}
	f.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.got = append(f.got, seen{path: r.URL.Path, header: r.Header.Clone(), body: b, proto: r.ProtoMajor})
		n := len(f.got)
		ans := f.answer
		f.mu.Unlock()
		status, reason := http.StatusOK, ""
		if ans != nil {
			status, reason = ans(strings.TrimPrefix(r.URL.Path, "/3/device/"), n)
		}
		if reason != "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
			return
		}
		w.WriteHeader(status)
	}))
	f.srv.EnableHTTP2 = true
	f.srv.StartTLS()
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAPNs) requests() []seen {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]seen(nil), f.got...)
}

func (f *fakeAPNs) client(t *testing.T, key *ecdsa.PrivateKey, now func() time.Time, hosts map[string]string) *Client {
	t.Helper()
	hc := f.srv.Client()
	tr := hc.Transport.(*http.Transport)
	tr.DisableCompression = true
	tr.ForceAttemptHTTP2 = true
	if hosts == nil {
		hosts = map[string]string{EnvProduction: f.srv.URL, EnvSandbox: f.srv.URL}
	}
	c, err := NewClient(ClientConfig{TeamID: "TEAM123456", KeyID: "KEY1234567", Topic: "app.hasala.ios",
		Key: key, HTTP: hc, Hosts: hosts, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func tokenHex(b byte) string { return strings.Repeat(string("0123456789abcdef"[b%16]), 64) }

// AT-APNS-1: the body and the header set are pinned, and identical for every reason.
func TestPayloadAndHeadersArePinned(t *testing.T) {
	if len(Payload) != 31 {
		t.Fatalf("payload is %d bytes, want 31", len(Payload))
	}
	key, _ := testKey(t)
	f := newFakeAPNs(t)
	now := time.Unix(1_760_000_000, 0)
	c := f.client(t, key, func() time.Time { return now }, nil)
	d := NewDispatcher(nil, c)
	d.Now = func() time.Time { return now }
	for _, r := range []Reason{ReasonMail, ReasonSync, ReasonSecurity, ReasonNudge, ReasonAccountGone} {
		d.run(bg, job{tokens: []Target{{TokenHex: tokenHex(byte(r)), Environment: EnvProduction}}, r: r})
	}
	reqs := f.requests()
	if len(reqs) != 5 {
		t.Fatalf("%d requests, want 5", len(reqs))
	}
	want := []string{"Apns-Expiration", "Apns-Priority", "Apns-Push-Type", "Apns-Topic", "Authorization",
		"Content-Length", "Content-Type"}
	for _, q := range reqs {
		if q.proto != 2 {
			t.Errorf("request over HTTP/%d, want h2", q.proto)
		}
		if string(q.body) != Payload {
			t.Errorf("body %q", q.body)
		}
		var names []string
		for k := range q.header {
			names = append(names, k)
		}
		slices.Sort(names)
		if !slices.Equal(names, want) {
			t.Errorf("headers %v, want exactly %v", names, want)
		}
		if q.header.Get("Apns-Topic") != "app.hasala.ios" || q.header.Get("Apns-Push-Type") != "background" ||
			q.header.Get("Apns-Priority") != "5" || q.header.Get("Content-Type") != "application/json" ||
			q.header.Get("Apns-Expiration") != "1760003600" {
			t.Errorf("header values %v", q.header)
		}
		if !strings.HasPrefix(q.path, "/3/device/") {
			t.Errorf("path %s", q.path)
		}
	}
}

// AT-APNS-2: each token goes to its environment's gateway.
func TestTokensRouteToTheirEnvironment(t *testing.T) {
	key, _ := testKey(t)
	prod, sand := newFakeAPNs(t), newFakeAPNs(t)
	hc := prod.srv.Client()
	pool := hc.Transport.(*http.Transport).TLSClientConfig.RootCAs
	pool.AddCert(sand.srv.Certificate())
	hc.Transport.(*http.Transport).DisableCompression = true
	c, err := NewClient(ClientConfig{TeamID: "TEAM123456", KeyID: "KEY1234567", Topic: "app.hasala.ios", Key: key,
		HTTP: hc, Hosts: map[string]string{EnvProduction: prod.srv.URL, EnvSandbox: sand.srv.URL}})
	if err != nil {
		t.Fatal(err)
	}
	if r := c.Send(bg, Target{TokenHex: tokenHex(1), Environment: EnvProduction}); r != ResultSent {
		t.Fatalf("production send: %v", r)
	}
	if r := c.Send(bg, Target{TokenHex: tokenHex(2), Environment: EnvSandbox}); r != ResultSent {
		t.Fatalf("sandbox send: %v", r)
	}
	if len(prod.requests()) != 1 || len(sand.requests()) != 1 ||
		!strings.HasSuffix(prod.requests()[0].path, tokenHex(1)) || !strings.HasSuffix(sand.requests()[0].path, tokenHex(2)) {
		t.Fatalf("routing: prod %d sandbox %d", len(prod.requests()), len(sand.requests()))
	}
	if r := c.Send(bg, Target{TokenHex: tokenHex(3), Environment: "development"}); r != ResultGone {
		t.Fatalf("unknown environment: %v", r)
	}
}

// AT-APNS-3 (the transport half): answers classify per spec 02 §12.3, and an
// ExpiredProviderToken regenerates the JWT once and retries once.
func TestResponsesClassifyAndExpiredTokenRetriesOnce(t *testing.T) {
	cases := []struct {
		status int
		reason string
		want   Result
	}{
		{200, "", ResultSent},
		{410, "Unregistered", ResultGone},
		{400, "BadDeviceToken", ResultGone},
		{400, "DeviceTokenNotForTopic", ResultGone},
		{400, "PayloadEmpty", ResultTransient},
		{429, "TooManyRequests", ResultCooldown},
		{403, "InvalidProviderToken", ResultConfig},
		{403, "BadTopic", ResultConfig},
		{403, "BadEnvironmentKeyIdInToken", ResultEnvironment},
		{403, "BadCertificateEnvironment", ResultEnvironment},
		{500, "InternalServerError", ResultTransient},
		{503, "ServiceUnavailable", ResultTransient},
	}
	for _, tc := range cases {
		if got := classify(tc.status, tc.reason); got != tc.want {
			t.Errorf("%d %s → %v, want %v", tc.status, tc.reason, got, tc.want)
		}
	}

	key, _ := testKey(t)
	f := newFakeAPNs(t)
	now := time.Unix(1_760_000_000, 0)
	c := f.client(t, key, func() time.Time { return now }, nil)
	if r := c.Send(bg, Target{TokenHex: tokenHex(1), Environment: EnvProduction}); r != ResultSent {
		t.Fatal(r)
	}
	first := f.requests()[0].header.Get("Authorization")
	now = now.Add(25 * time.Minute)
	f.answer = func(_ string, n int) (int, string) {
		if n == 2 {
			return 403, "ExpiredProviderToken"
		}
		return 200, ""
	}
	if r := c.Send(bg, Target{TokenHex: tokenHex(1), Environment: EnvProduction}); r != ResultSent {
		t.Fatalf("after ExpiredProviderToken: %v", r)
	}
	reqs := f.requests()
	if len(reqs) != 3 {
		t.Fatalf("%d requests, want 3 (one retry)", len(reqs))
	}
	if reqs[1].header.Get("Authorization") != first || reqs[2].header.Get("Authorization") == first {
		t.Fatal("the retry did not regenerate the provider token")
	}
}

// AT-APNS-4: the JWT verifies under the .p8's public key with kid and iss.
func TestProviderTokenVerifiesUnderTheKey(t *testing.T) {
	key, p8 := testKey(t)
	parsed, err := ParseP8(p8)
	if err != nil || !parsed.Equal(key) {
		t.Fatalf("ParseP8: %v", err)
	}
	iat := time.Unix(1_760_000_000, 0)
	tok, err := SignJWT(parsed, "KEY1234567", "TEAM123456", iat)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("token %q", tok)
	}
	dec := base64.RawURLEncoding
	h, _ := dec.DecodeString(parts[0])
	c, _ := dec.DecodeString(parts[1])
	if string(h) != `{"alg":"ES256","kid":"KEY1234567"}` || string(c) != `{"iss":"TEAM123456","iat":1760000000}` {
		t.Fatalf("header %s claims %s", h, c)
	}
	sig, _ := dec.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("signature is %d bytes, want raw r‖s", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("the JWT does not verify under the key")
	}

	// Any other key type is refused at startup.
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(rk)
	if _, err := ParseP8(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); !errors.Is(err, ErrKeyType) {
		t.Fatalf("an RSA key was accepted: %v", err)
	}
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ = x509.MarshalPKCS8PrivateKey(p384)
	if _, err := ParseP8(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); !errors.Is(err, ErrKeyType) {
		t.Fatalf("a P-384 key was accepted: %v", err)
	}
	if _, err := ParseP8([]byte("not a key")); !errors.Is(err, ErrKeyType) {
		t.Fatal("garbage accepted")
	}
}
