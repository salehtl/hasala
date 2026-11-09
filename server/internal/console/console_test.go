package console

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
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
	// The forms' POSTs only carry the console's Origin (which action
	// requires) when the policy is not no-referrer.
	if p := req(c, "GET", "/", nil, nil).Header().Get("Referrer-Policy"); p != "same-origin" {
		t.Fatalf("Referrer-Policy %q", p)
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
	if w := req(c, "POST", path, url.Values{"csrf": {m[1]}}, func(r *http.Request) { r.Header.Set("Origin", "null") }); w.Code != http.StatusForbidden {
		t.Fatalf("Origin null: %d", w.Code)
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

	gone, cancel := context.WithCancel(bg)
	cancel()
	if w := req(c, "POST", path, url.Values{"csrf": {m[1]}}, func(r *http.Request) { *r = *r.WithContext(gone) }); w.Code != http.StatusConflict {
		t.Fatalf("an approve whose request was cancelled: %d", w.Code)
	}
	var failed int
	_ = pool.QueryRow(bg, `SELECT count(*) FROM admin_audit WHERE actor = 'tailnet:owner@github' AND result = 'error'`).Scan(&failed)
	if failed != 1 {
		t.Fatalf("a cancelled request's failure left %d audit rows", failed)
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

// Spec 07 §13.3 (probe P8): /healthz is ok until a request carrying a
// Cloudflare header reaches the console; then it is 503 for 24 hours.
func TestHealthzTurnsOnATunnelLeak(t *testing.T) {
	c := New(pgtest.New(t), host, "tail.example.ts.net", []string{"owner@github"}, 0)
	health := func() (int, HealthBody) {
		w := httptest.NewRecorder()
		c.HealthHandler().ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
		var b HealthBody
		if err := json.Unmarshal(w.Body.Bytes(), &b); err != nil {
			t.Fatalf("body %q: %v", w.Body, err)
		}
		return w.Code, b
	}
	if code, b := health(); code != http.StatusOK || b != (HealthBody{Status: "ok", DB: "ok", ASC: "disabled"}) {
		t.Fatalf("healthy: %d %+v", code, b)
	}
	req(c, "GET", "/", nil, func(r *http.Request) { r.Header.Set("Cdn-Loop", "cloudflare") })
	req(c, "GET", "/", nil, func(r *http.Request) { r.Header.Set("Cf-Ray", "x") })
	if code, b := health(); code != http.StatusServiceUnavailable || b.Status != "fail" || b.TunnelRefusals24 != 2 {
		t.Fatalf("after a leak: %d %+v", code, b)
	}
	c.Now = func() time.Time { return time.Now().Add(25 * time.Hour) }
	if code, _ := health(); code != http.StatusOK {
		t.Fatalf("a day later: %d", code)
	}
	for _, p := range []string{"/metrics", "/", "/api/v1/healthz"} {
		w := httptest.NewRecorder()
		c.HealthHandler().ServeHTTP(w, httptest.NewRequest("GET", p, nil))
		if w.Code != http.StatusNotFound {
			t.Errorf("%s on the health listener: %d", p, w.Code)
		}
	}
}

func TestARevokedInviteIsRecordedInTheRestoreLedger(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	var got []purgeledger.Entry
	c.Record = func(e purgeledger.Entry) error {
		got = append(got, e)
		return nil
	}
	id, _, err := invites.MintPrinted(bg, pool, "", invites.DefaultTTL, false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	path := "/invites/" + id.String() + "/revoke"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id.String(), c.now())}}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("revoke: %d %s", w.Code, w.Body)
	}
	if len(got) != 1 || got[0].Kind != purgeledger.KindInviteRevoked || got[0].ID != id {
		t.Fatalf("ledger %+v, want one invite revocation", got)
	}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusConflict {
		t.Fatalf("second revoke: %d", w.Code)
	}
	if len(got) != 1 {
		t.Fatalf("a refused revocation was recorded: %+v", got)
	}
}

func TestARevocationTheLedgerDidNotRecordIsNotReportedAsDone(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	c.Record = func(purgeledger.Entry) error { return os.ErrPermission }
	id, _, err := invites.MintPrinted(bg, pool, "", invites.DefaultTTL, false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	path := "/invites/" + id.String() + "/revoke"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id.String(), c.now())}}
	w := req(c, "POST", path, form, nil)
	if w.Code != http.StatusInternalServerError || !strings.Contains(w.Body.String(), "restore ledger") {
		t.Fatalf("revoke with a failed ledger write: %d %s", w.Code, w.Body)
	}
}

func TestAResendPastTheMintLimitIsRefusedAndAudited(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	var entry string
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at,
		updated_at, confirmed_at, invited_at) VALUES (decode(repeat('ab', 32), 'hex'), 'limit@example.com', 'invited', 'enbd', 'web',
		now(), now(), now(), now()) RETURNING id`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	var id string
	if err := pool.QueryRow(bg, `INSERT INTO invite_codes (code_hash, email_tag, waitlist_entry_id, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES (decode(repeat('cd', 32), 'hex'), decode(repeat('ab', 32), 'hex'), $1, 'admin',
		'active', now(), now(), now() + interval '1 day', $2) RETURNING id`, entry, invites.MaxMints).Scan(&id); err != nil {
		t.Fatal(err)
	}
	path := "/invites/" + id + "/resend"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id, c.now())}}
	w := req(c, "POST", path, form, nil)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "refused") {
		t.Fatalf("resend at the limit: %d %s", w.Code, w.Body)
	}
	var queued int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE invite_id = $1`, id).Scan(&queued); err != nil || queued != 0 {
		t.Fatalf("%d mail rows, %v", queued, err)
	}
	var result, code string
	if err := pool.QueryRow(bg, `SELECT result, error_code FROM admin_audit WHERE action = 'console.invite.resend'`).
		Scan(&result, &code); err != nil {
		t.Fatal(err)
	}
	if result != "refused" || code != "mint_limit" {
		t.Fatalf("audit %s %s", result, code)
	}
}

func TestARevocationTheLedgerMissedIsRecordedByPostingItAgain(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	ledger := filepath.Join(t.TempDir(), "purged")
	broken := true
	c.Record = func(e purgeledger.Entry) error {
		if broken {
			return os.ErrPermission
		}
		return purgeledger.AppendEntries(ledger, e)
	}
	c.Missing = func(e purgeledger.Entry) (bool, error) { return purgeledger.Missing(ledger, e, time.Time{}) }
	id, _, err := invites.MintPrinted(bg, pool, "", invites.DefaultTTL, false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	path := "/invites/" + id.String() + "/revoke"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id.String(), c.now())}}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusInternalServerError {
		t.Fatalf("revoke with a failed ledger write: %d %s", w.Code, w.Body)
	}
	var closed time.Time
	if err := pool.QueryRow(bg, `SELECT closed_at FROM invite_codes WHERE id = $1`, id).Scan(&closed); err != nil {
		t.Fatal(err)
	}

	broken = false
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("posting again: %d %s", w.Code, w.Body)
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].Kind != purgeledger.KindInviteRevoked || entries[0].ID != id ||
		!entries[0].At.Equal(closed.Truncate(time.Second)) {
		t.Fatalf("ledger %+v %v, want the revocation at %v", entries, err, closed)
	}

	if w := req(c, "POST", path, form, nil); w.Code != http.StatusConflict {
		t.Fatalf("a third post: %d %s", w.Code, w.Body)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a third post, want one entry", entries, err)
	}
	var ok, refused int
	_ = pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE result = 'ok'), count(*) FILTER (WHERE result = 'refused')
		FROM admin_audit WHERE action = 'console.invite.revoke'`).Scan(&ok, &refused)
	if ok != 2 || refused != 1 {
		t.Fatalf("audit ok=%d refused=%d", ok, refused)
	}
}

func TestPostingARevokeForAnInviteThatWasNeverRevokedStaysRefused(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	ledger := filepath.Join(t.TempDir(), "purged")
	c.Record = func(e purgeledger.Entry) error { return purgeledger.AppendEntries(ledger, e) }
	c.Missing = func(e purgeledger.Entry) (bool, error) { return purgeledger.Missing(ledger, e, time.Time{}) }
	id := uuid.New()
	path := "/invites/" + id.String() + "/revoke"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id.String(), c.now())}}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusConflict {
		t.Fatalf("revoke of an unknown invite: %d %s", w.Code, w.Body)
	}
	if entries, err := purgeledger.Read(ledger); err != nil || len(entries) != 0 {
		t.Fatalf("ledger %+v %v, want nothing recorded", entries, err)
	}
}

func onceConsole(t *testing.T) (*Console, *time.Time) {
	t.Helper()
	c := New(pgtest.New(t), host, "tail.example.ts.net", []string{"owner@github"}, 0)
	now := time.Now().Truncate(time.Second)
	c.Now = func() time.Time { return now }
	return c, &now
}

func countInvites(t *testing.T, c *Console) (invitesMade, mails int) {
	t.Helper()
	if err := c.Pool.QueryRow(bg, `SELECT (SELECT count(*) FROM invite_codes), (SELECT count(*) FROM mail_log)`).Scan(&invitesMade, &mails); err != nil {
		t.Fatal(err)
	}
	return
}

func TestAMintFormMintsOnce(t *testing.T) {
	c, now := onceConsole(t)
	tok := c.csrf("owner@github", "/invites/mint", "", c.now())
	form := url.Values{"csrf": {tok}, "note": {"friend"}}
	if w := req(c, "POST", "/invites/mint", form, nil); w.Code != http.StatusOK {
		t.Fatalf("mint: %d %s", w.Code, w.Body)
	}
	w := req(c, "POST", "/invites/mint", form, nil)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "Go back and reload") {
		t.Fatalf("the same form again: %d %s", w.Code, w.Body)
	}
	if made, _ := countInvites(t, c); made != 1 {
		t.Fatalf("%d invites from one form", made)
	}
	var refused int
	_ = c.Pool.QueryRow(bg, `SELECT count(*) FROM admin_audit WHERE action = 'console.invite.mint' AND result = 'refused'`).Scan(&refused)
	if refused != 1 {
		t.Fatalf("%d refused audit rows, want the repeat audited", refused)
	}

	*now = now.Add(time.Second)
	fresh := url.Values{"csrf": {c.csrf("owner@github", "/invites/mint", "", c.now())}}
	if w := req(c, "POST", "/invites/mint", fresh, nil); w.Code != http.StatusOK {
		t.Fatalf("a reloaded form: %d %s", w.Code, w.Body)
	}
}

func TestAMintFormThatFailedCanBeSentAgain(t *testing.T) {
	c, _ := onceConsole(t)
	tok := c.csrf("owner@github", "/invites/mint", "", c.now())
	bad := url.Values{"csrf": {tok}, "email": {"not an address"}}
	if w := req(c, "POST", "/invites/mint", bad, nil); w.Code != http.StatusConflict {
		t.Fatalf("a bad address: %d %s", w.Code, w.Body)
	}
	good := url.Values{"csrf": {tok}, "email": {"guest@example.com"}}
	if w := req(c, "POST", "/invites/mint", good, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("the corrected form: %d %s", w.Code, w.Body)
	}
	if made, mails := countInvites(t, c); made != 1 || mails != 1 {
		t.Fatalf("%d invites and %d mails", made, mails)
	}
}

func TestADoubleSubmittedMintFormMintsOnce(t *testing.T) {
	c, _ := onceConsole(t)
	form := url.Values{"csrf": {c.csrf("owner@github", "/invites/mint", "", c.now())}}
	codes := make(chan int, 8)
	for range cap(codes) {
		go func() { codes <- req(c, "POST", "/invites/mint", form, nil).Code }()
	}
	done, refused := 0, 0
	for range cap(codes) {
		switch code := <-codes; code {
		case http.StatusOK:
			done++
		case http.StatusConflict:
			refused++
		default:
			t.Fatalf("status %d", code)
		}
	}
	if made, _ := countInvites(t, c); done != 1 || refused != cap(codes)-1 || made != 1 {
		t.Fatalf("%d done, %d refused, %d invites", done, refused, made)
	}
}

func TestAResendFormSendsOnce(t *testing.T) {
	c, now := onceConsole(t)
	mint := url.Values{"csrf": {c.csrf("owner@github", "/invites/mint", "", c.now())}, "email": {"guest@example.com"}}
	if w := req(c, "POST", "/invites/mint", mint, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("mint: %d %s", w.Code, w.Body)
	}
	var id string
	if err := c.Pool.QueryRow(bg, `SELECT id FROM invite_codes`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	path := "/invites/" + id + "/resend"
	form := url.Values{"csrf": {c.csrf("owner@github", path, id, c.now())}}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("resend: %d %s", w.Code, w.Body)
	}
	if w := req(c, "POST", path, form, nil); w.Code != http.StatusConflict {
		t.Fatalf("the same form again: %d %s", w.Code, w.Body)
	}
	if _, mails := countInvites(t, c); mails != 2 {
		t.Fatalf("%d mails, want the first and one resend", mails)
	}

	*now = now.Add(time.Second)
	again := url.Values{"csrf": {c.csrf("owner@github", path, id, c.now())}}
	if w := req(c, "POST", path, again, nil); w.Code != http.StatusSeeOther {
		t.Fatalf("a resend from a reloaded page: %d %s", w.Code, w.Body)
	}
	if _, mails := countInvites(t, c); mails != 3 {
		t.Fatalf("%d mails after a deliberate second resend", mails)
	}
}

func TestSpentFormsAreForgottenWhenTheyExpire(t *testing.T) {
	var s spentTokens
	at := time.Now()
	if !s.claim("a", at) || s.claim("a", at) {
		t.Fatal("a form was not spent by its first use")
	}
	s.claim("b", at.Add(csrfTTL+time.Second))
	if len(s.until) != 1 {
		t.Fatalf("%d forms held after one expired", len(s.until))
	}
}
