package console

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

const host = "console.example.test"

func req(c *Console, method, path string, form url.Values, mutate func(*http.Request)) *httptest.ResponseRecorder {
	var r *http.Request
	if form != nil {
		r = httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	r.RemoteAddr = "127.0.0.1:5555"
	r.Host = host
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Webauth-User", "owner@github")
	r.Header.Set("X-Webauth-Tailnet", "tail.example.ts.net.")
	r.Header.Set("Sec-Fetch-Site", "same-origin")
	r.Header.Set("Origin", "https://"+host)
	if mutate != nil {
		mutate(r)
	}
	w := httptest.NewRecorder()
	c.Handler().ServeHTTP(w, r)
	return w
}

func TestIdentifyRefusesAnythingButTheProxiedOwner(t *testing.T) {
	c := New(pgtest.New(t), host, "tail.example.ts.net", []string{"Owner@GitHub"}, 0)
	if w := req(c, "GET", "/", nil, nil); w.Code != http.StatusOK || strings.Contains(w.Body.String(), "<script") {
		t.Fatalf("owner: %d", w.Code)
	}
	for name, m := range map[string]func(*http.Request){
		"peer":      func(r *http.Request) { r.RemoteAddr = "192.0.2.5:1" },
		"cf":        func(r *http.Request) { r.Header.Set("Cf-Connecting-Ip", "1.2.3.4") },
		"host":      func(r *http.Request) { r.Host = "other.example" },
		"proto":     func(r *http.Request) { r.Header.Set("X-Forwarded-Proto", "http") },
		"identity":  func(r *http.Request) { r.Header.Del("X-Webauth-User") },
		"two ids":   func(r *http.Request) { r.Header.Add("X-Webauth-User", "x@github") },
		"ts header": func(r *http.Request) { r.Header.Set("Tailscale-User-Login", "x") },
		"tailnet":   func(r *http.Request) { r.Header.Set("X-Webauth-Tailnet", "other.ts.net") },
		"login":     func(r *http.Request) { r.Header.Set("X-Webauth-User", "stranger@github") },
	} {
		if w := req(c, "GET", "/", nil, m); w.Code != http.StatusForbidden {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
	// F7-2: no API or hook path.
	for _, p := range []string{"/api/v1/healthz", "/api/v1/waitlist", "/hooks/gmail/pubsub", "/metrics"} {
		if w := req(c, "GET", p, nil, nil); w.Code != http.StatusNotFound {
			t.Errorf("%s: %d", p, w.Code)
		}
	}
}

var csrfRE = regexp.MustCompile(`name="csrf" value="([^"]+)"`)

func TestApproveAndMintWithCSRF(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	var entry string
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at,
		updated_at, confirmed_at) VALUES (decode(repeat('ab', 32), 'hex'), 'guest@example.com', 'confirmed', 'enbd', 'web',
		now(), now(), now()) RETURNING id`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	page := req(c, "GET", "/", nil, nil).Body.String()
	m := csrfRE.FindStringSubmatch(page)
	if m == nil || !strings.Contains(page, "guest@example.com") {
		t.Fatalf("dashboard: %s", page)
	}
	path := "/waitlist/" + entry + "/approve"
	// Without same-origin evidence, or with a token for another path: refused.
	if w := req(c, "POST", path, url.Values{"csrf": {m[1]}}, func(r *http.Request) { r.Header.Del("Sec-Fetch-Site") }); w.Code != http.StatusForbidden {
		t.Fatalf("no Sec-Fetch-Site: %d", w.Code)
	}
	if w := req(c, "POST", path, url.Values{"csrf": {c.csrf("owner@github", "/invites/mint", "", c.now())}}, nil); w.Code != http.StatusForbidden {
		t.Fatalf("token for another path: %d", w.Code)
	}
	if w := req(c, "POST", path, url.Values{"csrf": {m[1]}}, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	var state string
	var queued int
	_ = pool.QueryRow(bg, `SELECT state FROM waitlist_entries WHERE id = $1`, entry).Scan(&state)
	_ = pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE kind = 'invite' AND status = 'queued'`).Scan(&queued)
	if state != "invited" || queued != 1 {
		t.Fatalf("after approve: %s, %d queued", state, queued)
	}
	// Approving again is refused and audited as such.
	if w := req(c, "POST", path, url.Values{"csrf": {m[1]}}, nil); w.Code != http.StatusConflict {
		t.Fatalf("second approve: %d", w.Code)
	}
	var ok, refused int
	_ = pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE result = 'ok'), count(*) FILTER (WHERE result = 'refused')
		FROM admin_audit WHERE actor = 'tailnet:owner@github'`).Scan(&ok, &refused)
	if ok != 1 || refused != 1 {
		t.Fatalf("audit ok=%d refused=%d", ok, refused)
	}

	// Mint a printed code: shown once.
	inv := req(c, "GET", "/invites", nil, nil).Body.String()
	tok := csrfRE.FindStringSubmatch(inv)[1]
	w := req(c, "POST", "/invites/mint", url.Values{"csrf": {tok}, "note": {"friend"}}, nil)
	if w.Code != http.StatusOK || !regexp.MustCompile(`[A-Z2-7]{4}(-[A-Z2-7]{4}){5}`).MatchString(w.Body.String()) {
		t.Fatalf("mint: %d %s", w.Code, w.Body)
	}
	var printed int
	_ = pool.QueryRow(bg, `SELECT count(*) FROM invite_codes WHERE origin = 'cli' AND state = 'active'`).Scan(&printed)
	if printed != 1 {
		t.Fatalf("%d printed invites", printed)
	}
}
