package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/turnstile"
)

type fakeTurnstile struct{ calls []string }

func (f *fakeTurnstile) Verify(_ context.Context, token, action string) error {
	f.calls = append(f.calls, action+":"+token)
	switch token {
	case "good":
		return nil
	case "down":
		return turnstile.ErrUnavailable
	}
	return turnstile.ErrRefused
}

func TestTurnstileGuardsTheWebRoutes(t *testing.T) {
	r := newWebRig(t)
	f := &fakeTurnstile{}
	r.h.srv.Web.Turnstile = f
	r.h.srv.Web.TurnstileRequired = true
	waitlist := func(email, tok string) *httptest.ResponseRecorder {
		body := `{"email":"` + email + `","bank":"enbd","source":"web"`
		if tok != "" {
			body += `,"turnstileToken":"` + tok + `"`
		}
		return r.post("/api/v1/waitlist", body+"}", nil)
	}
	bank := func(tok string) *httptest.ResponseRecorder {
		return r.post("/api/v1/bank-requests", `{"bank":"other","otherBank":"Bank Of Nowhere","source":"web","turnstileToken":"`+tok+`"}`, nil)
	}
	var n int
	entries := func() int {
		_ = r.h.pool.QueryRow(bg, `SELECT count(*) FROM waitlist_entries`).Scan(&n)
		return n
	}
	for _, tok := range []string{"", "bad", "down"} {
		w := waitlist("ts@example.com", tok)
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "turnstile_failed") {
			t.Fatalf("waitlist with token %q: %d %s", tok, w.Code, w.Body)
		}
		w = bank(tok)
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "turnstile_failed") {
			t.Fatalf("bank request with token %q: %d %s", tok, w.Code, w.Body)
		}
	}
	if entries() != 0 {
		t.Fatal("a refused token made a waitlist entry")
	}
	_ = r.h.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests`).Scan(&n)
	if n != 0 {
		t.Fatal("a refused token recorded a bank request")
	}
	wantStatus(t, waitlist("ts@example.com", "good"), http.StatusAccepted)
	wantStatus(t, bank("good"), http.StatusAccepted)
	if entries() != 1 {
		t.Fatal("a good token made no waitlist entry")
	}
	if got := strings.Join(f.calls, ","); !strings.Contains(got, "waitlist:good") || !strings.Contains(got, "bank_request:good") {
		t.Fatalf("verifier calls %s", got)
	}

	form := url.Values{"email": {"form-ts@example.com"}, "bank": {"enbd"}, "source": {"web"}, "cf-turnstile-response": {"bad"}}
	req := httptest.NewRequest("POST", "/api/v1/waitlist", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "text/html")
	fw := httptest.NewRecorder()
	r.h.h.ServeHTTP(fw, req)
	if fw.Code != http.StatusSeeOther || fw.Header().Get("Location") != "https://hasala.app/joined?error=turnstile_failed" {
		t.Fatalf("form post %d %v", fw.Code, fw.Header())
	}

	r.h.srv.Web.TurnstileRequired = false
	f.calls = nil
	wantStatus(t, waitlist("optional@example.com", ""), http.StatusAccepted)
	if len(f.calls) != 0 {
		t.Fatalf("an absent optional token was verified: %v", f.calls)
	}
	wantStatus(t, waitlist("optional2@example.com", "bad"), http.StatusForbidden)
}

func TestTurnstileRequiredWithoutAVerifierRefuses(t *testing.T) {
	r := newWebRig(t)
	r.h.srv.Web.TurnstileRequired = true
	wantStatus(t, r.post("/api/v1/waitlist", `{"email":"nov@example.com","bank":"enbd","source":"web","turnstileToken":"x"}`, nil),
		http.StatusForbidden)
}

type publicForm struct {
	name, path, good string
	junk             []string
	global, prefix   func(*WebOptions) **Limiter
}

func publicFormCases() []publicForm {
	waitlist := publicForm{name: "waitlist", path: "/api/v1/waitlist"}
	waitlist.good = `{"email":"form@example.com","bank":"enbd","source":"web","turnstileToken":"good"}`
	waitlist.junk = []string{
		"",
		"garbage",
		`{"email":"form@example.com","bank":"enbd","source":"web","website":"x"}`,
		`{"email":"nope","bank":"enbd","source":"web","turnstileToken":"good"}`,
		`{"email":"form@example.com","bank":"enbd","source":"web"}`,
		`{"email":"form@example.com","bank":"enbd","source":"web","turnstileToken":"bad"}`,
	}
	waitlist.global = func(o *WebOptions) **Limiter { return &o.WaitlistGlobal }
	waitlist.prefix = func(o *WebOptions) **Limiter { return &o.WaitlistPrefix }

	bank := publicForm{name: "bank request", path: "/api/v1/bank-requests"}
	bank.good = `{"bank":"other","otherBank":"Bank Of Nowhere","source":"web","turnstileToken":"good"}`
	bank.junk = []string{
		"",
		"garbage",
		`{"bank":"enbd","source":"web","website":"x"}`,
		`{"bank":"enbd","source":"app","turnstileToken":"good"}`,
		`{"bank":"other","otherBank":"Bank Of Nowhere","source":"web"}`,
		`{"bank":"other","otherBank":"Bank Of Nowhere","source":"web","turnstileToken":"bad"}`,
	}
	bank.global = func(o *WebOptions) **Limiter { return &o.BankGlobal }
	bank.prefix = func(o *WebOptions) **Limiter { return &o.BankPrefix }

	return []publicForm{waitlist, bank}
}

func TestPublicGlobalBudgetIsSpentOnlyAfterTurnstile(t *testing.T) {
	for _, c := range publicFormCases() {
		t.Run(c.name, func(t *testing.T) {
			r := newWebRig(t)
			o := r.h.srv.Web
			o.Turnstile, o.TurnstileRequired = &fakeTurnstile{}, true
			*c.global(o) = NewLimiter(0, 1, 1, nil)
			for range 3 {
				for _, body := range c.junk {
					if w := r.post(c.path, body, nil); w.Code == http.StatusTooManyRequests {
						t.Fatalf("%q was refused by the global budget", body)
					}
				}
			}
			wantStatus(t, r.post(c.path, c.good, nil), http.StatusAccepted)
			w := r.post(c.path, c.good, nil)
			wantStatus(t, w, http.StatusTooManyRequests)
			if w.Header().Get("Retry-After") != "600" {
				t.Fatalf("Retry-After %q", w.Header().Get("Retry-After"))
			}
		})
	}
}

func TestPublicFormsHaveAPrefixTierBeforeTurnstile(t *testing.T) {
	for _, c := range publicFormCases() {
		t.Run(c.name, func(t *testing.T) {
			r := newWebRig(t)
			r.h.srv.TrustCloudflare = true
			o := r.h.srv.Web
			f := &fakeTurnstile{}
			o.Turnstile, o.TurnstileRequired = f, true
			*c.prefix(o) = NewLimiter(0, 2, 16, nil)
			body := strings.ReplaceAll(c.good, `"good"`, `"bad"`)
			post := func(ip string) int {
				req := httptest.NewRequest("POST", c.path, strings.NewReader(body))
				req.RemoteAddr = "127.0.0.1:40000"
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Cf-Connecting-Ip", ip)
				w := httptest.NewRecorder()
				r.h.h.ServeHTTP(w, req)
				return w.Code
			}
			for _, ip := range []string{"2001:db8:7:1::1", "2001:db8:7:2::1"} {
				if got := post(ip); got != http.StatusForbidden {
					t.Fatalf("%s inside the tier: %d", ip, got)
				}
			}
			if got := post("2001:db8:7:3::1"); got != http.StatusTooManyRequests {
				t.Fatalf("a /48 over its tier: %d", got)
			}
			if len(f.calls) != 2 {
				t.Fatalf("%d verifier calls, want 2", len(f.calls))
			}
			if got := post("2001:db8:8::1"); got != http.StatusForbidden {
				t.Fatalf("another /48: %d", got)
			}
		})
	}
}
