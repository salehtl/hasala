package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/authtest"
)

func TestPrefixKey(t *testing.T) {
	for _, c := range []struct {
		key, want string
		ok        bool
	}{
		{"6:20010db800010002", "6p:20010db80001", true},
		{"4:192.0.2.7", "", false},
		{"local", "", false},
		{"peer:203.0.113.9", "", false},
		{"6:2001", "", false},
	} {
		got, ok := prefixKey(c.key)
		if got != c.want || ok != c.ok {
			t.Errorf("prefixKey(%q) = %q, %v; want %q, %v", c.key, got, ok, c.want, c.ok)
		}
	}
}

func prefixTierServer() *Server {
	return &Server{
		TrustCloudflare:    true,
		Logf:               func(string, ...any) {},
		PasskeyPerIP:       NewLimiter(0, 12, passkeyMaxKeys, nil),
		PasskeyPerPrefix:   NewLimiter(0, 24, passkeyMaxKeys, nil),
		PasskeyGlobal:      NewLimiter(0, 100, 1, nil),
		DevFreezeIP:        NewLimiter(0, 10, accountLimiterKeys, nil),
		DevFreezePerPrefix: NewLimiter(0, 20, accountLimiterKeys, nil),
		DevFreezeGlobal:    NewLimiter(0, 50, 1, nil),
	}
}

func postFrom(h http.Handler, ip string) int {
	r := httptest.NewRequest("POST", "/", strings.NewReader("{}"))
	r.RemoteAddr = "127.0.0.1:40000"
	r.Header.Set("Cf-Connecting-Ip", ip)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w.Code
}

func floodPrefixTier(t *testing.T, h http.Handler, perIP, globalBurst, prefixBurst int) {
	t.Helper()
	passed := 0
	for i := 0; i < 128; i++ {
		ip := fmt.Sprintf("2001:db8:0:1%02x::1", i)
		for j := 0; j < perIP+2; j++ {
			if postFrom(h, ip) == http.StatusOK {
				passed++
			}
		}
	}
	if passed != prefixBurst {
		t.Fatalf("one /56 passed %d requests, want %d", passed, prefixBurst)
	}
	if got := postFrom(h, "192.0.2.1"); got != http.StatusOK {
		t.Fatalf("after one /56 flooded, another client got %d", got)
	}
	for i := 0; i < globalBurst; i++ {
		postFrom(h, fmt.Sprintf("2001:db8:%x::1", 0x100+i))
	}
	if got := postFrom(h, "192.0.2.2"); got != http.StatusTooManyRequests {
		t.Fatalf("after many /48s the global bucket still allowed: %d", got)
	}
}

func okHandler(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

func TestSigninGlobalHasAPrefixTier(t *testing.T) {
	s := prefixTierServer()
	floodPrefixTier(t, s.withClientKey(s.limited(okHandler, s.PasskeyPerIP, s.PasskeyGlobal)), 12, 100, 24)
}

func TestPasskeyGlobalHasAPrefixTier(t *testing.T) {
	s := prefixTierServer()
	floodPrefixTier(t, s.withClientKey(s.passkeyLimited(okHandler)), 12, 100, 24)
}

func TestDevFreezeGlobalHasAPrefixTier(t *testing.T) {
	s := prefixTierServer()
	writer := authtest.NewDevice(t).WriterID
	h := s.withClientKey(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.devFreezeLimited(w, r, writer) {
			okHandler(w, r)
		}
	}))
	floodPrefixTier(t, h, 10, 50, 20)
}

func freezeLinkSetup(t *testing.T) (*harness, pwAccount, string) {
	t.Helper()
	h := newHarness(t)
	keys, fake, q := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")
	wantStatus(t, h.passwordLogin(a, a.s), http.StatusOK)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	link := regexp.MustCompile(`freeze#([A-Za-z0-9_-]{43})`).FindStringSubmatch(mailTexts(fake.To(a.addr)))
	if link == nil {
		t.Fatal("no freeze link was mailed")
	}
	h.srv.FreezePerIP = NewLimiter(1e6, 1e6, 16, nil)
	h.srv.FreezeGlobal = NewLimiter(0, 1, 1, nil)
	h.h = h.srv.Handler()
	return h, a, link[1]
}

func postFreezeLink(h *harness, ctx context.Context, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/api/v1/account/freeze", strings.NewReader(body)).WithContext(ctx)
	r.Header.Set("Content-Type", "text/plain")
	w := httptest.NewRecorder()
	h.h.ServeHTTP(w, r)
	return w
}

func randomFreezeToken(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func TestFreezeLinkJunkSpendsNoGlobalBudget(t *testing.T) {
	h, a, token := freezeLinkSetup(t)
	for i := 0; i < 101; i++ {
		for _, body := range []string{"garbage", `{"token":"AAAA"}`, `{"token":"` + strings.Repeat("!", 43) + `"}`, `{"token":"` + randomFreezeToken(t) + `"}`} {
			wantStatus(t, postFreezeLink(h, bg, body), http.StatusNoContent)
		}
	}
	wantStatus(t, postFreezeLink(h, bg, `{"token":"`+token+`"}`), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
}

func TestFreezeLinkRefusedByGlobalIsNotASuccess(t *testing.T) {
	h, a, token := freezeLinkSetup(t)
	h.srv.FreezeGlobal.Allow("")
	w := postFreezeLink(h, bg, `{"token":"`+token+`"}`)
	wantStatus(t, w, http.StatusServiceUnavailable)
	if w.Header().Get("Retry-After") == "" || w.Body.Len() != 0 {
		t.Fatalf("refused freeze link: Retry-After %q, body %q", w.Header().Get("Retry-After"), w.Body.String())
	}
	wantStatus(t, postFreezeLink(h, bg, `{"token":"`+randomFreezeToken(t)+`"}`), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusOK)
	h.srv.FreezeGlobal = NewLimiter(0, 1, 1, nil)
	h.h = h.srv.Handler()
	wantStatus(t, postFreezeLink(h, bg, `{"token":"`+token+`"}`), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
}

func TestFreezeLinkPrefixTierIsNotASuccess(t *testing.T) {
	h, a, token := freezeLinkSetup(t)
	h.srv.TrustCloudflare = true
	h.srv.FreezePerPrefix = NewLimiter(0, 2, 16, nil)
	h.h = h.srv.Handler()
	post := func(ip, tok string) int {
		r := httptest.NewRequest("POST", "/api/v1/account/freeze", strings.NewReader(`{"token":"`+tok+`"}`))
		r.RemoteAddr = "127.0.0.1:40000"
		r.Header.Set("Cf-Connecting-Ip", ip)
		w := httptest.NewRecorder()
		h.h.ServeHTTP(w, r)
		return w.Code
	}
	for i := 0; i < 2; i++ {
		if got := post(fmt.Sprintf("2001:db8:7:%x::1", i), randomFreezeToken(t)); got != http.StatusNoContent {
			t.Fatalf("junk token %d: %d", i, got)
		}
	}
	if got := post("2001:db8:7:9::1", token); got != http.StatusServiceUnavailable {
		t.Fatalf("a /48 over its tier: %d, want 503", got)
	}
	if got := post("2001:db8:7:a::1", randomFreezeToken(t)); got != http.StatusServiceUnavailable {
		t.Fatalf("a /48 over its tier with an unknown token: %d, want 503", got)
	}
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusOK)
	if got := post("192.0.2.9", token); got != http.StatusNoContent {
		t.Fatalf("another client: %d", got)
	}
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
}

func TestFreezeLinkStatusIsReadableByTheSite(t *testing.T) {
	h, _, _ := freezeLinkSetup(t)
	h.srv.Web = &WebOptions{Origins: []string{"https://site.example"}}
	for _, c := range []struct{ origin, want string }{
		{"https://site.example", "https://site.example"},
		{"https://other.example", ""},
		{"", ""},
	} {
		r := httptest.NewRequest("POST", "/api/v1/account/freeze", strings.NewReader(`{"token":"`+randomFreezeToken(t)+`"}`))
		r.Header.Set("Content-Type", "text/plain")
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		h.h.ServeHTTP(w, r)
		wantStatus(t, w, http.StatusNoContent)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != c.want {
			t.Fatalf("origin %q: Access-Control-Allow-Origin %q, want %q", c.origin, got, c.want)
		}
	}
}

func TestFreezeLinkErrorIsNotASuccess(t *testing.T) {
	h, a, token := freezeLinkSetup(t)
	h.srv.FreezeGlobal = NewLimiter(1e6, 1e6, 1, nil)
	h.h = h.srv.Handler()
	ctx, cancel := context.WithCancel(bg)
	cancel()
	wantStatus(t, postFreezeLink(h, ctx, `{"token":"`+token+`"}`), http.StatusServiceUnavailable)
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusOK)
	wantStatus(t, postFreezeLink(h, bg, `{"token":"`+token+`"}`), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
}

func TestClientAddressLimitersCarryAPrefixQuota(t *testing.T) {
	h := newHarness(t)
	h.srv.Web = &WebOptions{}
	h.h = h.srv.Handler()
	for name, l := range map[string]*Limiter{
		"recover":  h.srv.RecoverPerIP,
		"code":     h.srv.CodePerIP,
		"passkey":  h.srv.PasskeyPerIP,
		"meta":     h.srv.MetaPerIP,
		"waitlist": h.srv.Web.WaitlistIP,
		"link":     h.srv.Web.LinkIP,
		"bank":     h.srv.Web.BankIP,
	} {
		if l.prefixQuota != l.maxKeys/prefixQuotaShare {
			t.Errorf("%s: prefix quota %d of %d keys", name, l.prefixQuota, l.maxKeys)
		}
	}
}

func TestPasswordLoginFinishHasAPrefixAndAGlobalTier(t *testing.T) {
	h := newHarness(t)
	keys, _, _ := h.accounts()
	h.srv.TrustCloudflare = true
	h.srv.PasskeyPerPrefix = NewLimiter(0, 2, 16, nil)
	h.srv.PasskeyGlobal = NewLimiter(0, 4, 1, nil)
	h.h = h.srv.Handler()
	post := func(ip string) int {
		r := httptest.NewRequest("POST", "/api/v1/auth/password/login/finish",
			strings.NewReader(`{"ceremony_id":"nope","verifier":"`+b64(make([]byte, 32))+`"}`))
		r.RemoteAddr = "127.0.0.1:40000"
		r.Header.Set("Cf-Connecting-Ip", ip)
		w := httptest.NewRecorder()
		h.h.ServeHTTP(w, r)
		return w.Code
	}
	for i := range 2 {
		if got := post(fmt.Sprintf("2001:db8:7:%x::1", i)); got != http.StatusForbidden {
			t.Fatalf("call %d inside the tier: %d", i, got)
		}
	}
	hashes := keys.HashCount()
	for i := 2; i < 6; i++ {
		if got := post(fmt.Sprintf("2001:db8:7:%x::1", i)); got != http.StatusTooManyRequests {
			t.Fatalf("call %d over the /48's tier: %d", i, got)
		}
	}
	if keys.HashCount() != hashes {
		t.Fatal("a call over the /48's tier ran a hash")
	}
	if got := post("2001:db8:8::1"); got != http.StatusForbidden {
		t.Fatalf("another /48: %d", got)
	}
	if got := post("192.0.2.9"); got != http.StatusForbidden {
		t.Fatalf("an IPv4 client: %d", got)
	}
	hashes = keys.HashCount()
	if got := post("192.0.2.10"); got != http.StatusTooManyRequests {
		t.Fatalf("over the global budget: %d", got)
	}
	if keys.HashCount() != hashes {
		t.Fatal("a call over the global budget ran a hash")
	}
}
