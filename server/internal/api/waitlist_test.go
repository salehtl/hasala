package api

import (
	"bytes"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

type webRig struct {
	h      *harness
	fake   *mail.Fake
	q      *mailq.Queue
	wl     *waitlist.Service
	tagger mailq.Tagger
}

func newWebRig(t *testing.T) *webRig {
	t.Helper()
	h := newHarness(t).passkeys()
	// One queue and one tag for the waitlist and the account ceremonies, as
	// serve wires them.
	tagger, fake, q := h.accounts()
	q.Register("test", mailq.TestRenderer)
	q.Register("invite", invites.Renderer{WebBase: "https://hasala.app", ManualTestFlight: true})
	wl := waitlist.New(h.pool, tagger, "https://hasala.app")
	wl.Register(q)
	generous := func() *Limiter { return NewLimiter(1000, 1000, 100, time.Now) }
	h.srv.Web = &WebOptions{Waitlist: wl, Origins: []string{"https://hasala.app"}, DoneURL: "https://hasala.app/joined",
		WaitlistIP: generous(), WaitlistGlobal: generous(), LinkIP: generous(), BankIP: generous(),
		BankGlobal: generous(), BankUser: generous(), PreflightIP: generous()}
	h.h = h.srv.Handler()
	return &webRig{h: h, fake: fake, q: q, wl: wl, tagger: tagger}
}

func (r *webRig) drain() []mail.Message {
	r.h.t.Helper()
	r.fake.Reset()
	if _, err := r.q.Drain(bg); err != nil {
		r.h.t.Fatal(err)
	}
	return r.fake.Sent()
}

func (r *webRig) post(path string, body string, header map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range header {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	r.h.h.ServeHTTP(w, req)
	return w
}

var linkRE = regexp.MustCompile(`https://hasala\.app/(waitlist/confirm|waitlist/leave|i/[A-Z2-7]{24})#([A-Za-z0-9_-]{43})`)

func links(m mail.Message) map[string]string {
	out := map[string]string{}
	for _, l := range linkRE.FindAllStringSubmatch(m.Text, -1) {
		if strings.HasPrefix(l[1], "i/") {
			out["code"], out["linkkey"] = strings.TrimPrefix(l[1], "i/"), l[2]
			continue
		}
		out[l[1]] = l[2]
	}
	return out
}

func TestWaitlistDoubleOptInInviteAndJoin(t *testing.T) {
	r := newWebRig(t)
	h := r.h
	submit := func(email, bank string) *httptest.ResponseRecorder {
		return r.post("/api/v1/waitlist", `{"email":"`+email+`","bank":"`+bank+`","source":"web"}`, nil)
	}

	// A new address: 202 check_email, and one confirmation email.
	w := submit("Maya@Example.com", "enbd")
	wantStatus(t, w, http.StatusAccepted)
	answer := w.Body.String()
	if answer != `{"status":"check_email"}` {
		t.Fatalf("answer %s", answer)
	}
	sent := r.drain()
	if len(sent) != 1 || sent[0].To != "maya@example.com" || sent[0].Subject != "Confirm your place on the Hasala list" {
		t.Fatalf("sent %+v", sent)
	}
	if !strings.Contains(sent[0].Text, "Bank: Emirates NBD") || sent[0].HTML == "" {
		t.Fatalf("confirmation text %q", sent[0].Text)
	}
	l := links(sent[0])
	if l["waitlist/confirm"] == "" || l["waitlist/leave"] == "" {
		t.Fatalf("links %v in %q", l, sent[0].Text)
	}

	// The same address again within 10 minutes: the same answer, no email.
	wantStatus(t, submit("maya@example.com", "enbd"), http.StatusAccepted)
	if sent := r.drain(); len(sent) != 0 {
		t.Fatalf("a capped resubmission sent %d emails", len(sent))
	}

	// Confirm: once confirmed, then already_confirmed; a bad token is 410.
	// The operator's notice hook runs for the first only.
	notices := 0
	r.wl.OnConfirmed = func() { notices++ }
	if w := r.post("/api/v1/waitlist/confirm", `{"token":"`+l["waitlist/confirm"]+`"}`, nil); w.Body.String() != `{"status":"confirmed"}` {
		t.Fatalf("confirm %d %s", w.Code, w.Body)
	}
	if notices != 1 {
		t.Fatalf("OnConfirmed ran %d times for a confirmation, want 1", notices)
	}
	if w := r.post("/api/v1/waitlist/confirm", `{"token":"`+l["waitlist/confirm"]+`"}`, nil); w.Body.String() != `{"status":"already_confirmed"}` {
		t.Fatalf("second confirm %s", w.Body)
	}
	if notices != 1 {
		t.Fatalf("OnConfirmed ran again for already_confirmed (%d)", notices)
	}
	wantStatus(t, r.post("/api/v1/waitlist/confirm", `{"token":"`+strings.Repeat("A", 43)+`"}`, nil), http.StatusGone)
	wantStatus(t, r.post("/api/v1/waitlist/confirm", `{"token":"short"}`, nil), http.StatusBadRequest)

	// The operator approves (C5): the worker mints the code and link key.
	var entry uuid.UUID
	if err := h.pool.QueryRow(bg, `SELECT id FROM waitlist_entries WHERE email_norm = 'maya@example.com'`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	tx, _ := pgtx.BeginReadCommitted(bg, h.pool)
	inviteID, err := invites.ApproveEntry(bg, tx, r.q, entry, "", invites.DefaultTTL)
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	sent = r.drain()
	if len(sent) != 1 || sent[0].Subject != "Your Hasala invite" {
		t.Fatalf("invite email %+v", sent)
	}
	il := links(sent[0])
	code, key := il["code"], il["linkkey"]
	if code == "" || key == "" || !strings.Contains(sent[0].Text, invites.Display(code)) {
		t.Fatalf("invite links %v in %q", il, sent[0].Text)
	}
	if strings.Contains(sent[0].Subject, code) {
		t.Fatal("the code is in the subject")
	}
	// What the link proves (spec 07 §4.4).
	tag := r.tagger.EmailTag("maya@example.com")
	rawKey, _ := base64.RawURLEncoding.DecodeString(key)
	res, err := invites.Resolve(bg, h.pool, code, rawKey, tag, time.Now())
	if err != nil || !res.Proven || res.InviteID != inviteID {
		t.Fatalf("resolve with the link: %+v %v", res, err)
	}
	if res, err := invites.Resolve(bg, h.pool, code, nil, tag, time.Now()); err != nil || res.Proven {
		t.Fatalf("a code alone proved the address: %+v %v", res, err)
	}
	if _, err := invites.Resolve(bg, h.pool, code, rawKey, r.tagger.EmailTag("someone@example.com"), time.Now()); !errors.Is(err, invites.ErrNotInvited) {
		t.Fatalf("another address was accepted: %v", err)
	}
	// While invited, a resubmission says so by email (after the 10-minute cap).
	if _, err := h.pool.Exec(bg, `UPDATE mail_log SET created_at = created_at - interval '1 day'`); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, submit("maya@example.com", "dib"), http.StatusAccepted)
	if sent := r.drain(); len(sent) != 1 || sent[0].Subject != "You're already on the Hasala list" ||
		!strings.Contains(sent[0].Text, "Your invite went out") {
		t.Fatalf("already-invited email %+v", sent)
	}

	// An addressed invite at signup/begin (spec 02 §14.1, spec 07 §4.4): the
	// code sits in the link's path, which scanners see, so it proves nothing
	// alone. With another address it is the same not_invited as an unknown
	// code; with its own address and no key (or another key) the address
	// still needs a signup code; a malformed key is a 400; only the link's key
	// proves the address.
	begin := func(email, key string) *httptest.ResponseRecorder {
		return h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: code, Email: email,
			DisplayName: "Maya Rahman", InviteLinkKey: key})
	}
	notInvited := `{"error":"not_invited"}`
	if w := begin("someone@example.com", key); w.Code != http.StatusForbidden || w.Body.String() != notInvited {
		t.Fatalf("addressed invite with another address: %d %s", w.Code, w.Body)
	}
	for _, k := range []string{"", base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))} {
		w := begin("maya@example.com", k)
		wantStatus(t, w, http.StatusOK)
		if decodeJSON[SignupBeginResponse](t, w).EmailProven {
			t.Fatalf("key %q proved the address", k)
		}
	}
	for _, k := range []string{"short", key + "A", strings.Repeat("*", 43)} {
		wantStatus(t, begin("maya@example.com", k), http.StatusBadRequest)
	}
	// A refused unknown code answers the same bytes.
	if w := h.req("POST", "/api/v1/auth/signup/begin", "", SignupBeginRequest{InviteCode: strings.Repeat("A", 24),
		Email: "maya@example.com", DisplayName: "Maya"}); w.Body.String() != notInvited {
		t.Fatalf("unknown code: %s", w.Body)
	}

	// Redemption (with the link's key) joins the entry and forgets its address.
	w = begin("maya@example.com", key)
	wantStatus(t, w, http.StatusOK)
	signup := decodeJSON[SignupBeginResponse](t, w)
	if !signup.EmailProven {
		t.Fatal("the link's key did not prove the address")
	}
	_, sess := h.register(signup.SignupID)
	var state string
	var email *string
	if err := h.pool.QueryRow(bg, `SELECT state, email_norm FROM waitlist_entries WHERE id = $1`, entry).Scan(&state, &email); err != nil ||
		state != "joined" || email != nil {
		t.Fatalf("entry after redemption: %s %v %v", state, email, err)
	}
	if sess.SessionToken == "" {
		t.Fatal("no session")
	}
	// The code is spent.
	if _, err := invites.Resolve(bg, h.pool, code, nil, tag, time.Now()); !errors.Is(err, invites.ErrNotInvited) {
		t.Fatal("a redeemed code still resolves")
	}
}

func TestWaitlistAnswersAreUniform(t *testing.T) {
	r := newWebRig(t)
	h := r.h
	u := h.user("has-account")
	if _, err := h.pool.Exec(bg, `UPDATE users SET email_norm = 'holder@example.com' WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	// An entry in every later state (spec 07 §5.9: one answer for all).
	entry := func(email, state string) {
		t.Helper()
		var norm any = email
		if state == "joined" {
			norm = nil
		}
		if _, err := h.pool.Exec(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source,
			created_at, updated_at, confirmed_at, invited_at, joined_at)
			VALUES ($1, $2, $3, 'enbd', 'web', now(), now(), now(),
			        CASE WHEN $3 IN ('invited','joined') THEN now() END, CASE WHEN $3 = 'joined' THEN now() END)`,
			r.tagger.EmailTag(email), norm, state); err != nil {
			t.Fatal(err)
		}
	}
	entry("confirmed@example.com", "confirmed")
	entry("invited@example.com", "invited")
	entry("joined@example.com", "joined")
	// Joined, then the account was deleted: the purge removes the entry.
	entry("gone@example.com", "joined")
	if _, err := h.pool.Exec(bg, `DELETE FROM waitlist_entries WHERE email_tag = $1`, r.tagger.EmailTag("gone@example.com")); err != nil {
		t.Fatal(err)
	}
	var bodies []string
	for _, email := range []string{"new@example.com", "new@example.com", "holder@example.com", "confirmed@example.com",
		"invited@example.com", "joined@example.com", "gone@example.com"} {
		w := r.post("/api/v1/waitlist", `{"email":"`+email+`","bank":"other","otherBank":"Some Bank","source":"web"}`, nil)
		wantStatus(t, w, http.StatusAccepted)
		bodies = append(bodies, w.Body.String())
	}
	for _, b := range bodies[1:] {
		if b != bodies[0] {
			t.Fatalf("answers differ: %v", bodies)
		}
	}
	sent := r.drain()
	subjects := map[string]string{}
	for _, m := range sent {
		subjects[m.To] = m.Subject
		if strings.Contains(m.Text, "Some Bank") {
			t.Fatal("typed bank text reached an email")
		}
	}
	if subjects["holder@example.com"] != "You already have a Hasala account" || subjects["new@example.com"] == "" {
		t.Fatalf("subjects %v", subjects)
	}

	// Honeypot: the same answer, nothing stored.
	w := r.post("/api/v1/waitlist", `{"email":"bot@example.com","bank":"enbd","source":"web","website":"x"}`, nil)
	if w.Code != http.StatusAccepted || w.Body.String() != bodies[0] {
		t.Fatalf("honeypot %d %s", w.Code, w.Body)
	}
	var n int
	_ = h.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE recipient = 'bot@example.com'`).Scan(&n)
	if n != 0 {
		t.Fatal("the honeypot queued an email")
	}

	// Validation.
	for body, code := range map[string]string{
		`{"email":"nope","bank":"enbd","source":"web"}`:                             "bad_email",
		`{"email":"a@example.com","bank":"nobank","source":"web"}`:                  "bad_bank",
		`{"email":"a@example.com","bank":"other","otherBank":"<x>","source":"web"}`: "bad_bank",
		`{"email":"a@example.com","bank":"enbd","source":"app"}`:                    "bad_request",
		`{"email":"a@example.com","bank":"enbd","source":"web","extra":1}`:          "bad_request",
	} {
		w := r.post("/api/v1/waitlist", body, nil)
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), code) {
			t.Errorf("%s: %d %s, want %s", body, w.Code, w.Body, code)
		}
	}
}

func TestWebRoutesCORSMethodsAndForms(t *testing.T) {
	r := newWebRig(t)
	ok := `{"email":"cors@example.com","bank":"enbd","source":"web"}`
	w := r.post("/api/v1/waitlist", ok, map[string]string{"Origin": "https://evil.example"})
	if w.Code != http.StatusForbidden || w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("foreign origin: %d %v", w.Code, w.Header())
	}
	w = r.post("/api/v1/waitlist", ok, map[string]string{"Origin": "https://hasala.app"})
	if w.Code != http.StatusAccepted || w.Header().Get("Access-Control-Allow-Origin") != "https://hasala.app" {
		t.Fatalf("listed origin: %d %v", w.Code, w.Header())
	}
	pre := httptest.NewRequest("OPTIONS", "/api/v1/bank-requests", nil)
	pre.Header.Set("Origin", "https://hasala.app")
	pre.Header.Set("Access-Control-Request-Method", "POST")
	pw := httptest.NewRecorder()
	r.h.h.ServeHTTP(pw, pre)
	if pw.Code != http.StatusNoContent || pw.Header().Get("Access-Control-Max-Age") != "600" {
		t.Fatalf("preflight %d %v", pw.Code, pw.Header())
	}
	for _, m := range []string{"GET", "PUT", "DELETE"} {
		w := r.h.req(m, "/api/v1/waitlist", "", nil)
		if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != "POST, OPTIONS" {
			t.Fatalf("%s: %d %v", m, w.Code, w.Header())
		}
	}
	// A script-free form post gets a 303 to the done page.
	form := url.Values{"email": {"form@example.com"}, "bank": {"other"}, "source": {"web"}}
	req := httptest.NewRequest("POST", "/api/v1/waitlist", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "text/html")
	fw := httptest.NewRecorder()
	r.h.h.ServeHTTP(fw, req)
	if fw.Code != http.StatusSeeOther || fw.Header().Get("Location") != "https://hasala.app/joined" {
		t.Fatalf("form post %d %v", fw.Code, fw.Header())
	}
	bad := httptest.NewRequest("POST", "/api/v1/waitlist", strings.NewReader("email=x&source=web&bank=enbd"))
	bad.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	bad.Header.Set("Accept", "text/html")
	bw := httptest.NewRecorder()
	r.h.h.ServeHTTP(bw, bad)
	if bw.Code != http.StatusSeeOther || bw.Header().Get("Location") != "https://hasala.app/joined?error=bad_email" {
		t.Fatalf("bad form post %d %v", bw.Code, bw.Header())
	}
	xml := httptest.NewRequest("POST", "/api/v1/waitlist", strings.NewReader("<x/>"))
	xml.Header.Set("Content-Type", "application/xml")
	xw := httptest.NewRecorder()
	r.h.h.ServeHTTP(xw, xml)
	wantStatus(t, xw, http.StatusUnsupportedMediaType)
}

func TestWaitlistLeave(t *testing.T) {
	r := newWebRig(t)
	wantStatus(t, r.post("/api/v1/waitlist", `{"email":"leaver@example.com","bank":"enbd","source":"web"}`, nil), http.StatusAccepted)
	l := links(r.drain()[0])
	// Any well-formed token gets the same answer.
	for _, tok := range []string{strings.Repeat("B", 43), l["waitlist/leave"]} {
		w := r.post("/api/v1/waitlist/leave", `{"token":"`+tok+`"}`, nil)
		if w.Code != http.StatusOK || w.Body.String() != `{"status":"done"}` {
			t.Fatalf("leave %d %s", w.Code, w.Body)
		}
	}
	var n int
	_ = r.h.pool.QueryRow(bg, `SELECT count(*) FROM waitlist_entries`).Scan(&n)
	if n != 0 {
		t.Fatal("the entry survived its leave link")
	}
	_ = r.h.pool.QueryRow(bg, `SELECT count(*) FROM mail_log`).Scan(&n)
	if n != 0 {
		t.Fatal("the entry's mail rows survived it")
	}
}

func TestBankRequests(t *testing.T) {
	r := newWebRig(t)
	h := r.h
	count := func() (n int) {
		_ = h.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests`).Scan(&n)
		return
	}
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"enbd","source":"web"}`, nil), http.StatusAccepted)
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"adib","source":"web"}`, nil), http.StatusAccepted)
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"other","otherBank":"Abu Dhabi Islamic Bank","source":"web"}`, nil), http.StatusAccepted)
	if count() != 0 {
		t.Fatal("a supported bank was stored")
	}
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"other","otherBank":"Mashreq Bank","source":"web"}`, nil), http.StatusAccepted)
	var slug *string
	if err := h.pool.QueryRow(bg, `SELECT bank_slug FROM bank_requests`).Scan(&slug); err != nil || slug == nil || *slug != "mashreq" {
		t.Fatalf("an alias did not resolve to the catalog: %v %v", slug, err)
	}
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"other","otherBank":"Bank Of  Nowhere","source":"web"}`, nil), http.StatusAccepted)
	var key, text string
	if err := h.pool.QueryRow(bg, `SELECT other_key, other_text FROM bank_requests WHERE other_key IS NOT NULL`).Scan(&key, &text); err != nil ||
		key != "bank of nowhere" || text != "Bank Of Nowhere" {
		t.Fatalf("free text: %q %q %v", key, text, err)
	}
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"other","source":"web"}`, nil), http.StatusBadRequest)
	wantStatus(t, r.post("/api/v1/bank-requests", `{"bank":"adcb","source":"app"}`, nil), http.StatusBadRequest)

	// Signed in: once per bank per account.
	u := h.user("bank-app")
	tok := h.session(u)
	for range 2 {
		wantStatus(t, h.req("POST", "/api/v1/bank-requests", tok, map[string]any{"bank": "adcb", "source": "app"}), http.StatusAccepted)
	}
	var n int
	_ = h.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE user_id = $1`, u).Scan(&n)
	if n != 1 {
		t.Fatalf("%d app requests, want 1", n)
	}
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", tok, map[string]any{"bank": "adcb", "source": "web"}), http.StatusBadRequest)
}

// The CLI's `invite mint --email`: queued without any tag (the CLI holds no
// auth key); the worker tags the row and the invite, mints and sends.
func TestCLIEmailedInviteIsTaggedAndMintedByTheWorker(t *testing.T) {
	r := newWebRig(t)
	h := r.h
	cli := mailq.New(h.pool, nil, nil)
	var id uuid.UUID
	err := pgx.BeginFunc(bg, h.pool, func(tx pgx.Tx) error {
		v, err := invites.EnqueueEmailed(bg, tx, cli, "Guest@Example.com", "friend", invites.DefaultTTL)
		id = v
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	var tag []byte
	_ = h.pool.QueryRow(bg, `SELECT recipient_tag FROM mail_log`).Scan(&tag)
	if tag != nil {
		t.Fatal("the CLI computed a tag")
	}
	sent := r.drain()
	if len(sent) != 1 || sent[0].To != "guest@example.com" {
		t.Fatalf("sent %+v", sent)
	}
	l := links(sent[0])
	rawKey, _ := base64.RawURLEncoding.DecodeString(l["linkkey"])
	res, err := invites.Resolve(bg, h.pool, l["code"], rawKey, r.tagger.EmailTag("guest@example.com"), time.Now())
	if err != nil || !res.Proven || res.InviteID != id {
		t.Fatalf("resolve: %+v %v", res, err)
	}
	if strings.Contains(sent[0].Text, "friend") {
		t.Fatal("the operator's note reached the email")
	}
}
