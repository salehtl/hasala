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
