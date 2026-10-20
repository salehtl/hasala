package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// recWaker records every wake instead of sending it.
type recWaker struct {
	mu    sync.Mutex
	wakes []wakeRec
}

type wakeRec struct {
	user   uuid.UUID
	writer string
	others bool
	tokens []string // WakeTokens only
	r      pushv2.Reason
}

func (w *recWaker) WakeWriter(_ context.Context, u uuid.UUID, writer string, r pushv2.Reason) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.wakes = append(w.wakes, wakeRec{user: u, writer: writer, r: r})
}

func (w *recWaker) WakeOthers(_ context.Context, u uuid.UUID, except string, r pushv2.Reason) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.wakes = append(w.wakes, wakeRec{user: u, writer: except, others: true, r: r})
}

func (w *recWaker) WakeTokens(_ context.Context, ts []pushv2.Target, r pushv2.Reason) {
	w.mu.Lock()
	defer w.mu.Unlock()
	rec := wakeRec{r: r}
	for _, t := range ts {
		rec.tokens = append(rec.tokens, t.TokenHex)
	}
	w.wakes = append(w.wakes, rec)
}

func (w *recWaker) take() []wakeRec {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := w.wakes
	w.wakes = nil
	return out
}

// fakeVerifier stands in for googlejwt: a token is base64url(JSON claims), or
// "down" (the key set is unreachable), or anything else (rejected).
type fakeVerifier struct{ audience string }

type fakeClaims struct {
	Aud, Azp, Email, Nonce string
	EmailVerified          bool
	Iat                    time.Time
}

func (f fakeVerifier) Verify(_ context.Context, tok string) (googlejwt.Claims, error) {
	if tok == "down" {
		return googlejwt.Claims{}, googlejwt.ErrKeySetUnavailable
	}
	raw, err := base64.RawURLEncoding.DecodeString(tok)
	if err != nil {
		return googlejwt.Claims{}, googlejwt.ErrSignature
	}
	var c fakeClaims
	if json.Unmarshal(raw, &c) != nil {
		return googlejwt.Claims{}, googlejwt.ErrSignature
	}
	if c.Aud != f.audience {
		return googlejwt.Claims{}, googlejwt.ErrAudience
	}
	return googlejwt.Claims{Aud: []string{c.Aud}, Azp: c.Azp, Email: c.Email, Nonce: c.Nonce,
		EmailVerified: c.EmailVerified, Iat: c.Iat}, nil
}

func fakeToken(c fakeClaims) string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

const (
	testClientID = "1234-test.apps.googleusercontent.com"
	testAudience = "https://api.hasala.app/hooks/gmail/pubsub"
	testSA       = "hasala-push@test-project.iam.gserviceaccount.com"
	testSub      = "projects/test-project/subscriptions/hasala-gmail-qa"
	testMailbox  = "Someone.Else@Gmail.com"
)

const testTopic = "projects/test-project/topics/hasala-gmail-qa"

// withPushAndGmail mounts the mailbox link and the Pub/Sub push.
func withPushAndGmail(h *harness) (*recWaker, *GmailOptions) {
	h.t.Helper()
	return withGmail(h, &GmailPush{Topic: testTopic, Hook: fakeVerifier{testAudience}, Subscription: testSub,
		ServiceAccount: testSA})
}

// withGmail mounts the mailbox link, and the push when push is not nil.
func withGmail(h *harness, push *GmailPush) (*recWaker, *GmailOptions) {
	h.t.Helper()
	rk, err := gmailpush.NewRouteKey(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		h.t.Fatal(err)
	}
	w := &recWaker{}
	g := &GmailOptions{RouteKey: rk, Link: fakeVerifier{testClientID}, IOSClientID: testClientID,
		MailboxPerUser: NewLimiter(1000, 1000, 100, time.Now), Push: push}
	h.srv.Push.Waker = w
	h.srv.Gmail = g
	h.h = h.srv.Handler()
	return w, g
}

func tokenHexFor(b byte) string { return strings.Repeat(string("0123456789abcdef"[b%16]), 64) }

func TestAPNsTokenRoutes(t *testing.T) {
	h := newHarness(t)
	withPushAndGmail(h)
	u := h.user("apns")
	w1 := "ios-11111111-1111-4111-8111-111111111111"
	h.writer(u, w1)
	tok := h.session(u)

	// Unbound sessions cannot register a token.
	wantStatus(t, h.req("PUT", "/api/v1/push/apns", tok, PutAPNsRequest{TokenHex: tokenHexFor(1), Environment: "production"}),
		http.StatusForbidden)
	h.bind(tok, w1)
	for _, bad := range []PutAPNsRequest{
		{TokenHex: "xyz", Environment: "production"},
		{TokenHex: tokenHexFor(1), Environment: "development"},
	} {
		wantStatus(t, h.req("PUT", "/api/v1/push/apns", tok, bad), http.StatusBadRequest)
	}
	wantStatus(t, h.req("PUT", "/api/v1/push/apns", tok,
		PutAPNsRequest{TokenHex: strings.ToUpper(tokenHexFor(1)), Environment: "sandbox"}), http.StatusNoContent)
	devs := decodeJSON[APNsDevicesResponse](t, h.req("GET", "/api/v1/push/apns", tok, nil))
	if len(devs.Devices) != 1 || !devs.Devices[0].Current || devs.Devices[0].Environment != "sandbox" {
		t.Fatalf("devices %+v", devs)
	}

	// AT-APNS-7: another writer of the same account takes the token over.
	w1b := "ios-12222222-2222-4222-8222-222222222222"
	h.writer(u, w1b)
	tokB := h.session(u)
	h.bind(tokB, w1b)
	wantStatus(t, h.req("PUT", "/api/v1/push/apns", tokB,
		PutAPNsRequest{TokenHex: tokenHexFor(1), Environment: "production"}), http.StatusNoContent)
	var holder string
	if err := h.pool.QueryRow(bg, `SELECT writer_id FROM apns_tokens WHERE token_hex = $1`, tokenHexFor(1)).Scan(&holder); err != nil ||
		holder != w1b {
		t.Fatalf("the token is held by %q (%v), want the second writer", holder, err)
	}

	// Another account cannot take a token whose row is live; once that
	// session is gone, it moves and one row remains.
	v := h.user("apns-other")
	w2 := "ios-22222222-2222-4222-8222-222222222222"
	h.writer(v, w2)
	tok2 := h.session(v)
	h.bind(tok2, w2)
	w := h.req("PUT", "/api/v1/push/apns", tok2, PutAPNsRequest{TokenHex: tokenHexFor(1), Environment: "production"})
	wantStatus(t, w, http.StatusConflict)
	if !strings.Contains(w.Body.String(), "token_in_use") || h.countAPNs(u) != 1 || h.countAPNs(v) != 0 {
		t.Fatalf("a live token moved to another account: %s", w.Body)
	}
	if _, err := h.pool.Exec(bg, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE token_hash = $1`, auth.SessionHash(tokB)); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, h.req("PUT", "/api/v1/push/apns", tok2,
		PutAPNsRequest{TokenHex: tokenHexFor(1), Environment: "production"}), http.StatusNoContent)
	var owners []uuid.UUID
	rows, _ := h.pool.Query(bg, `SELECT user_id FROM apns_tokens WHERE token_hex = $1`, tokenHexFor(1))
	for rows.Next() {
		var o uuid.UUID
		_ = rows.Scan(&o)
		owners = append(owners, o)
	}
	rows.Close()
	if len(owners) != 1 || owners[0] != v {
		t.Fatalf("token owners %v, want only the caller", owners)
	}
	if n := len(decodeJSON[APNsDevicesResponse](t, h.req("GET", "/api/v1/push/apns", tok, nil)).Devices); n != 0 {
		t.Fatalf("the first account still lists %d devices", n)
	}
	wantStatus(t, h.req("DELETE", "/api/v1/push/apns", tok2, map[string]any{}), http.StatusNoContent)
	if h.countAPNs(v) != 0 {
		t.Fatal("DELETE left the token")
	}
}

func TestAPNsTokenMovesFromADeadRowOfAnotherAccount(t *testing.T) {
	h := newHarness(t)
	withPushAndGmail(h)
	put := func(tok string) *httptest.ResponseRecorder {
		return h.req("PUT", "/api/v1/push/apns", tok, PutAPNsRequest{TokenHex: tokenHexFor(5), Environment: "production"})
	}
	u := h.user("apns-dead")
	wu := "ios-13333333-3333-4333-8333-333333333333"
	h.writer(u, wu)
	tokU := h.session(u)
	h.bind(tokU, wu)
	wantStatus(t, put(tokU), http.StatusNoContent)
	v := h.user("apns-taker")
	wv := "ios-14444444-4444-4444-8444-444444444444"
	h.writer(v, wv)
	tokV := h.session(v)
	h.bind(tokV, wv)
	wantStatus(t, put(tokV), http.StatusConflict)

	if _, err := h.pool.Exec(bg, `UPDATE sessions SET created_at = now() - $2::interval, last_used_at = now() - $2::interval WHERE token_hash = $1`,
		auth.SessionHash(tokU), (h.srv.Sessions.TTL + time.Hour).String()); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, put(tokV), http.StatusNoContent)
	if h.countAPNs(u) != 0 || h.countAPNs(v) != 1 {
		t.Fatal("the token did not move from an idle session")
	}

	wu2 := "ios-15555555-5555-4555-8555-555555555555"
	h.writer(u, wu2)
	tokU2 := h.session(u)
	h.bind(tokU2, wu2)
	wantStatus(t, put(tokU2), http.StatusConflict)
	if _, err := h.pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`, v, wv); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, put(tokU2), http.StatusNoContent)
	if h.countAPNs(u) != 1 || h.countAPNs(v) != 0 {
		t.Fatal("the token did not move from a revoked writer")
	}
}

func TestAnUploadWakesTheOtherDevices(t *testing.T) {
	h := newHarness(t)
	w, _ := withPushAndGmail(h)
	u := h.user("upload-wake")
	writer := "ios-33333333-3333-4333-8333-333333333333"
	h.writer(u, writer)
	tok := h.session(u)
	blobs, _ := uploadChain(t, u, writer, 1, blob.ZeroHash, 1)
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{WriterID: writer, Stream: "hot", Blobs: blobs}), http.StatusOK)
	got := w.take()
	if len(got) != 1 || !got[0].others || got[0].writer != writer || got[0].user != u || got[0].r != pushv2.ReasonSync {
		t.Fatalf("wakes %+v, want one sync wake to the others", got)
	}
}

// linkChallenge asks for a nonce on tok's session.
func linkChallenge(h *harness, tok string) string {
	h.t.Helper()
	w := h.req("POST", "/api/v1/mailbox/link/challenge", tok, map[string]any{})
	wantStatus(h.t, w, http.StatusOK)
	return decodeJSON[LinkChallengeResponse](h.t, w).Nonce
}

func goodClaims(nonce string) fakeClaims {
	return fakeClaims{Aud: testClientID, Azp: testClientID, Email: testMailbox, Nonce: nonce, EmailVerified: true,
		Iat: time.Now().Add(-time.Minute)}
}

func link(k *keyed, tok, idToken string) *httptest.ResponseRecorder {
	k.h.t.Helper()
	th := sha256.Sum256([]byte(idToken))
	return k.h.req("PUT", "/api/v1/mailbox/link", tok, LinkRequest{IDToken: idToken,
		StepUp: k.stepUp(tok, keyproto.ActionMailboxLink, th[:])})
}

// AT-GM-1, -2, -6, -9: the link proves the nonce, the step-up and the claims;
// only the HMAC is stored; the holder and the watch.
func TestMailboxLink(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, g := withPushAndGmail(h)
	k := h.onboard(true)

	// Without a step-up: 403 step_up_required, nothing stored.
	n := linkChallenge(h, k.token)
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{IDToken: fakeToken(goodClaims(n))}),
		http.StatusForbidden)

	// Claim failures: each a 403 link_rejected.
	other := h.session(k.user)
	h.bind(other, k.device.WriterID)
	foreign := linkChallenge(h, other)
	for name, c := range map[string]fakeClaims{
		"another session's nonce": goodClaims(foreign),
		"unverified email":        func() fakeClaims { c := goodClaims(n); c.EmailVerified = false; return c }(),
		"old iat":                 func() fakeClaims { c := goodClaims(n); c.Iat = time.Now().Add(-11 * time.Minute); return c }(),
		"wrong azp":               func() fakeClaims { c := goodClaims(n); c.Azp = "other.apps.googleusercontent.com"; return c }(),
		"wrong aud":               func() fakeClaims { c := goodClaims(n); c.Aud = "other"; return c }(),
	} {
		w := link(k, k.token, fakeToken(c))
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "link_rejected") {
			t.Fatalf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	wantStatus(t, link(k, k.token, "down"), http.StatusServiceUnavailable)

	w := link(k, k.token, fakeToken(goodClaims(n)))
	wantStatus(t, w, http.StatusOK)
	got := decodeJSON[LinkResponse](t, w)
	if got.Holder.WriterID != k.device.WriterID || !got.Holder.IsThisDevice || got.Provider != "gmail" {
		t.Fatalf("link %+v", got)
	}
	// Reused nonce.
	if w := link(k, k.token, fakeToken(goodClaims(n))); w.Code != http.StatusForbidden {
		t.Fatalf("a reused nonce linked: %d", w.Code)
	}
	// The address is stored nowhere: scan every text and bytea column.
	assertNoAddress(t, h, testMailbox)
	var stored []byte
	if err := h.pool.QueryRow(bg, `SELECT address_hmac FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&stored); err != nil ||
		!bytes.Equal(stored, g.RouteKey.AddressHMAC(testMailbox)) {
		t.Fatalf("stored hmac %x, %v", stored, err)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].r != pushv2.ReasonSecurity || !ws[0].others {
		t.Fatalf("link wakes %+v", ws)
	}

	// The watch: holder only, within 8 days.
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token,
		LinkWatchRequest{ExpiresAt: time.Now().Add(9 * 24 * time.Hour)}), http.StatusBadRequest)
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token,
		LinkWatchRequest{ExpiresAt: time.Now().Add(7 * 24 * time.Hour)}), http.StatusNoContent)
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.WatchExpiresAt == nil {
		t.Fatal("#37 does not report the watch #36 recorded")
	}

	// A second device takes over: the first sees is_this_device = false and
	// its watch report is 409 not_holder.
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != d2.WriterID || ws[0].r != pushv2.ReasonSecurity {
		t.Fatalf("enrolment wakes %+v, want a security wake to the others", ws)
	}
	n2 := linkChallenge(h, tok2)
	wantStatus(t, link(k, tok2, fakeToken(goodClaims(n2))), http.StatusOK)
	st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil))
	if st.Holder.IsThisDevice || st.Holder.WriterID != d2.WriterID {
		t.Fatalf("status %+v", st)
	}
	w = h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: time.Now().Add(time.Hour)})
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "not_holder") {
		t.Fatalf("non-holder watch: %d %s", w.Code, w.Body)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != d2.WriterID || !ws[0].others {
		t.Fatalf("holder change wakes %+v, want the others (the old holder among them)", ws)
	}

	// Unlink with a step-up.
	wantStatus(t, h.req("DELETE", "/api/v1/mailbox/link", tok2, UnlinkRequest{}), http.StatusForbidden)
	wantStatus(t, h.req("DELETE", "/api/v1/mailbox/link", tok2,
		UnlinkRequest{StepUp: k.stepUp(tok2, keyproto.ActionMailboxUnlink)}), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/mailbox/link", k.token, nil), http.StatusNotFound)

	// Each link and the unlink are auth events with no alert (spec 02 §10.16).
	var linked, unlinked, alerts int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE kind = 'mailbox_linked'),
	    count(*) FILTER (WHERE kind = 'mailbox_unlinked') FROM auth_events WHERE user_id = $1`, k.user).
		Scan(&linked, &unlinked); err != nil {
		t.Fatal(err)
	}
	_ = h.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE kind = 'alert'`).Scan(&alerts)
	if linked != 2 || unlinked != 1 || alerts != 0 {
		t.Fatalf("auth events: %d linked, %d unlinked, %d alerts; want 2, 1, 0", linked, unlinked, alerts)
	}
}

// mailboxRoutes is #34–#38.
var mailboxRoutes = []struct{ method, path string }{
	{"POST", "/api/v1/mailbox/link/challenge"},
	{"PUT", "/api/v1/mailbox/link"},
	{"PUT", "/api/v1/mailbox/link/watch"},
	{"GET", "/api/v1/mailbox/link"},
	{"DELETE", "/api/v1/mailbox/link"},
}

// wantNotFound wants the catch-all's 404 not_found: the route is not mounted.
func wantNotFound(t *testing.T, w *httptest.ResponseRecorder, what string) {
	t.Helper()
	if w.Code != http.StatusNotFound || decodeJSON[errorBody](t, w).Error != "not_found" {
		t.Fatalf("%s: %d %s, want the unmounted 404 not_found", what, w.Code, w.Body)
	}
}

// Without [gmail] nothing of #34–#39 is mounted and /meta offers no topic.
func TestNoGmailMountsNothing(t *testing.T) {
	h := newHarness(t)
	for _, rt := range mailboxRoutes {
		wantNotFound(t, h.req(rt.method, rt.path, "", map[string]any{}), rt.method+" "+rt.path)
	}
	wantNotFound(t, h.hook("", pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": "1"})),
		"the hook")
	if m := decodeJSON[MetaResponse](t, h.req("GET", "/api/v1/meta", "", nil)); m.GmailWatchTopic != nil {
		t.Fatalf("meta offers the topic %q", *m.GmailWatchTopic)
	}
}

// The mailbox link without the Pub/Sub push: #34–#38 are mounted and link,
// report and unlink a mailbox as they do with it; #36 records no watch (409
// no_watch_topic), #37 reports none, /meta offers no topic, and the hook (#39)
// is not mounted, so nothing is ever woken.
func TestMailboxLinkWithoutPush(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, g := withGmail(h, nil)
	k := h.onboard(true)

	// Mounted: without a session each is the one 401, not the catch-all 404.
	for _, rt := range mailboxRoutes {
		if w := h.req(rt.method, rt.path, "", map[string]any{}); w.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s: %d %s, want 401 (mounted)", rt.method, rt.path, w.Code, w.Body)
		}
	}

	// The link: the same nonce, step-up and claims as with the push.
	n := linkChallenge(h, k.token)
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{IDToken: fakeToken(goodClaims(n))}),
		http.StatusForbidden)
	if w := link(k, k.token, fakeToken(func() fakeClaims { c := goodClaims(n); c.Aud = "other"; return c }())); w.Code != http.StatusForbidden {
		t.Fatalf("an ID token for another client linked: %d", w.Code)
	}
	w := link(k, k.token, fakeToken(goodClaims(n)))
	wantStatus(t, w, http.StatusOK)
	if got := decodeJSON[LinkResponse](t, w); got.Holder.WriterID != k.device.WriterID || !got.Holder.IsThisDevice {
		t.Fatalf("link %+v", got)
	}
	var stored []byte
	if err := h.pool.QueryRow(bg, `SELECT address_hmac FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&stored); err != nil ||
		!bytes.Equal(stored, g.RouteKey.AddressHMAC(testMailbox)) {
		t.Fatalf("stored hmac %x, %v", stored, err)
	}
	assertNoAddress(t, h, testMailbox)
	if ws := wk.take(); len(ws) != 1 || ws[0].r != pushv2.ReasonSecurity || !ws[0].others {
		t.Fatalf("link wakes %+v", ws)
	}

	// #36: no topic, no watch.
	w = h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: time.Now().Add(7 * 24 * time.Hour)})
	if w.Code != http.StatusConflict || decodeJSON[errorBody](t, w).Error != "no_watch_topic" {
		t.Fatalf("watch without the push: %d %s, want 409 no_watch_topic", w.Code, w.Body)
	}
	var watch *time.Time
	if err := h.pool.QueryRow(bg, `SELECT watch_expires_at FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&watch); err != nil ||
		watch != nil {
		t.Fatalf("a watch was recorded without the push: %v %v", watch, err)
	}

	// #37: the holder, and no watch, even one recorded while the push was on.
	if _, err := h.pool.Exec(bg, `UPDATE mailbox_links SET watch_expires_at = now() + interval '3 days' WHERE user_id = $1`,
		k.user); err != nil {
		t.Fatal(err)
	}
	st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil))
	if !st.Holder.IsThisDevice || st.Holder.WriterID != k.device.WriterID || st.WatchExpiresAt != nil {
		t.Fatalf("status %+v", st)
	}

	// /meta: no topic, so the app never calls users.watch.
	if m := decodeJSON[MetaResponse](t, h.req("GET", "/api/v1/meta", "", nil)); m.GmailWatchTopic != nil {
		t.Fatalf("meta offers the topic %q without the push", *m.GmailWatchTopic)
	}

	// #39: not mounted, even for a well-formed, well-signed notice of a linked mailbox.
	pushToken := "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
	wantNotFound(t, h.hook(pushToken, pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": "1"})),
		"the hook without the push")
	if ws := wk.take(); len(ws) != 0 {
		t.Fatalf("the hook woke %+v without the push", ws)
	}

	// #38.
	wantStatus(t, h.req("DELETE", "/api/v1/mailbox/link", k.token,
		UnlinkRequest{StepUp: k.stepUp(k.token, keyproto.ActionMailboxUnlink)}), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/mailbox/link", k.token, nil), http.StatusNotFound)
}

func assertNoAddress(t *testing.T, h *harness, addr string) {
	t.Helper()
	rows, err := h.pool.Query(bg, `SELECT table_name, column_name, data_type FROM information_schema.columns
		WHERE table_schema = 'public' AND data_type IN ('text','bytea','jsonb')`)
	if err != nil {
		t.Fatal(err)
	}
	type col struct{ table, column, typ string }
	var cols []col
	for rows.Next() {
		var c col
		_ = rows.Scan(&c.table, &c.column, &c.typ)
		cols = append(cols, c)
	}
	rows.Close()
	if len(cols) < 20 {
		t.Fatalf("scanned %d columns; the scan would be vacuous", len(cols))
	}
	needle := strings.ToLower(strings.TrimSpace(addr))
	for _, c := range cols {
		q := `SELECT count(*) FROM ` + c.table + ` WHERE position($1 in lower(` + c.column + `::text)) > 0`
		arg := any(needle)
		if c.typ == "bytea" {
			q = `SELECT count(*) FROM ` + c.table + ` WHERE position($1::bytea in ` + c.column + `) > 0`
			arg = []byte(needle)
		}
		var n int
		if err := h.pool.QueryRow(bg, q, arg).Scan(&n); err != nil {
			t.Fatalf("scan %s.%s: %v", c.table, c.column, err)
		}
		if n > 0 {
			t.Fatalf("%s.%s holds the mailbox address", c.table, c.column)
		}
	}
}

func pubsubBody(t *testing.T, sub string, data any) []byte {
	t.Helper()
	raw, _ := json.Marshal(data)
	b, _ := json.Marshal(map[string]any{
		"message":      map[string]any{"data": base64.StdEncoding.EncodeToString(raw), "messageId": "1"},
		"subscription": sub,
	})
	return b
}

func (h *harness) hook(authz string, body []byte) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/hooks/gmail/pubsub", bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if authz != "" {
		r.Header.Set("Authorization", authz)
	}
	w := httptest.NewRecorder()
	h.h.ServeHTTP(w, r)
	return w
}

// AT-GM-3, -4, -5, -10: the hook's answers and who it wakes.
func TestGmailHook(t *testing.T) {
	h := newHarness(t)
	wk, g := withPushAndGmail(h)
	u := h.user("hook")
	holder := "ios-44444444-4444-4444-8444-444444444444"
	h.writer(u, holder)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
		VALUES ($1, 'gmail', $2, $3, $4, now(), now())`, u, g.RouteKey.AddressHMAC(testMailbox), g.RouteKey.KeyID(), holder); err != nil {
		t.Fatal(err)
	}
	pushToken := "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
	notice := map[string]any{"emailAddress": "  someone.else@gmail.com ", "historyId": 12345}
	good := pubsubBody(t, testSub, notice)

	wantStatus(t, h.hook("", good), http.StatusUnauthorized)
	wantStatus(t, h.hook("Bearer garbage", good), http.StatusUnauthorized)
	wantStatus(t, h.hook("Bearer "+fakeToken(fakeClaims{Aud: "https://elsewhere", Email: testSA, EmailVerified: true}), good),
		http.StatusUnauthorized)
	wantStatus(t, h.hook("Bearer "+fakeToken(fakeClaims{Aud: testAudience, Email: "x@example.com", EmailVerified: true}), good),
		http.StatusForbidden)
	wantStatus(t, h.hook("Bearer "+fakeToken(fakeClaims{Aud: testAudience, Email: testSA}), good), http.StatusForbidden)
	wantStatus(t, h.hook("Bearer down", good), http.StatusServiceUnavailable)
	if len(wk.take()) != 0 {
		t.Fatal("an unauthenticated push woke someone")
	}

	before := g.Push.Counters.Malformed.Load()
	wantStatus(t, h.hook(pushToken, []byte(`{"message":{"data":"!!!"},"subscription":"`+testSub+`"}`)), http.StatusNoContent)
	wantStatus(t, h.hook(pushToken, pubsubBody(t, testSub, map[string]any{"emailAddress": "a@b.c", "historyId": "x1"})),
		http.StatusNoContent)
	if g.Push.Counters.Malformed.Load() != before+2 {
		t.Fatal("malformed pushes were not counted")
	}
	wantStatus(t, h.hook(pushToken, pubsubBody(t, "projects/x/subscriptions/other", notice)), http.StatusNoContent)
	if g.Push.Counters.ForeignSubscription.Load() != 1 {
		t.Fatal("foreign subscription not counted")
	}
	wantStatus(t, h.hook(pushToken, pubsubBody(t, testSub, map[string]any{"emailAddress": "nobody@gmail.com", "historyId": "9"})),
		http.StatusNoContent)
	if g.Push.Counters.Unknown.Load() != 1 || len(wk.take()) != 0 {
		t.Fatal("an unknown address was not a counted no-op")
	}

	wantStatus(t, h.hook(pushToken, good), http.StatusNoContent)
	ws := wk.take()
	if len(ws) != 1 || ws[0].others || ws[0].writer != holder || ws[0].user != u || ws[0].r != pushv2.ReasonMail {
		t.Fatalf("wakes %+v, want exactly the holder", ws)
	}
	var hour *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_wake_hour FROM mailbox_links WHERE user_id = $1`, u).Scan(&hour); err != nil || hour == nil {
		t.Fatalf("last_wake_hour not recorded: %v", err)
	}

	// hook-link: the burst for one address runs out; another is unaffected.
	limited := 0
	for range 20 {
		h.hook(pushToken, good)
	}
	limited = int(g.Push.Counters.LinkLimited.Load())
	if limited == 0 {
		t.Fatal("hook-link never limited one address")
	}
	wantStatus(t, h.hook(pushToken, pubsubBody(t, testSub, map[string]any{"emailAddress": "fresh@gmail.com", "historyId": "1"})),
		http.StatusNoContent)
	if g.Push.Counters.LinkLimited.Load() != int64(limited) {
		t.Fatal("another address was limited by the first one's budget")
	}
}

func TestGmailHookUnverifiedRequestsSpendNoGlobalBudget(t *testing.T) {
	h := newHarness(t)
	wk, g := withGmail(h, &GmailPush{Topic: testTopic, Hook: fakeVerifier{testAudience}, Subscription: testSub,
		ServiceAccount: testSA, HookPerIP: NewLimiter(1e6, 1e6, 10, time.Now), HookGlobal: NewLimiter(0, 1, 1, time.Now)})
	u := h.user("hook-global")
	holder := "ios-46666666-6666-4666-8666-666666666666"
	h.writer(u, holder)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
		VALUES ($1, 'gmail', $2, $3, $4, now(), now())`, u, g.RouteKey.AddressHMAC(testMailbox), g.RouteKey.KeyID(), holder); err != nil {
		t.Fatal(err)
	}
	good := pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": "1"})
	for range 5 {
		wantStatus(t, h.hook("", good), http.StatusUnauthorized)
		wantStatus(t, h.hook("Bearer garbage", good), http.StatusUnauthorized)
		wantStatus(t, h.hook("Bearer "+fakeToken(fakeClaims{Aud: testAudience, Email: "x@example.com", EmailVerified: true}), good),
			http.StatusForbidden)
	}
	pushToken := "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
	wantStatus(t, h.hook(pushToken, good), http.StatusNoContent)
	if ws := wk.take(); len(ws) != 1 || ws[0].user != u || ws[0].writer != holder {
		t.Fatalf("wakes %+v, want the holder once", ws)
	}
	wantStatus(t, h.hook(pushToken, good), http.StatusTooManyRequests)
	if len(wk.take()) != 0 {
		t.Fatal("a request over the global budget woke someone")
	}
}

// AT-GM-7: the nudge sweep.
func TestNudgeSweep(t *testing.T) {
	h := newHarness(t)
	_, g := withPushAndGmail(h)
	u := h.user("nudge")
	holder := "ios-55555555-5555-4555-8555-555555555555"
	h.writer(u, holder)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		watch_expires_at, created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, now() + interval '30 hours', now(), now())`,
		u, g.RouteKey.AddressHMAC("n@gmail.com"), g.RouteKey.KeyID(), holder); err != nil {
		t.Fatal(err)
	}
	wk := &recWaker{}
	if msg, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil || msg == "" {
		t.Fatalf("nudge: %q %v", msg, err)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != holder || ws[0].r != pushv2.ReasonNudge {
		t.Fatalf("nudges %+v", ws)
	}
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil || len(wk.take()) != 0 {
		t.Fatal("a second nudge inside 12 hours")
	}
	if err := gmailpush.CheckKeyID(bg, h.pool, g.RouteKey); err != nil {
		t.Fatalf("CheckKeyID with the same key: %v", err)
	}
	other, _ := gmailpush.NewRouteKey(bytes.Repeat([]byte{8}, 32))
	if err := gmailpush.CheckKeyID(bg, h.pool, other); err == nil {
		t.Fatal("CheckKeyID accepted links made under another key")
	}
}

type refusingWaker struct {
	recWaker
	accept bool
}

func (w *refusingWaker) TryWakeWriter(ctx context.Context, u uuid.UUID, writer string, r pushv2.Reason) bool {
	if !w.accept {
		return false
	}
	w.WakeWriter(ctx, u, writer, r)
	return true
}

func TestNudgeNotQueuedIsRetriedOnTheNextRun(t *testing.T) {
	h := newHarness(t)
	_, g := withPushAndGmail(h)
	u := h.user("nudge-dropped")
	holder := "ios-56666666-6666-4666-8666-666666666666"
	h.writer(u, holder)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		watch_expires_at, created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, now() + interval '30 hours', now(), now())`,
		u, g.RouteKey.AddressHMAC("d@gmail.com"), g.RouteKey.KeyID(), holder); err != nil {
		t.Fatal(err)
	}
	wk := &refusingWaker{}
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil || len(wk.take()) != 0 {
		t.Fatalf("nudge: %v", err)
	}
	var mark *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_nudge_at FROM mailbox_links WHERE user_id = $1`, u).Scan(&mark); err != nil || mark != nil {
		t.Fatalf("a nudge that was not queued left the mark %v (%v)", mark, err)
	}
	wk.accept = true
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil {
		t.Fatal(err)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != holder || ws[0].r != pushv2.ReasonNudge {
		t.Fatalf("the next run nudged %+v, want the holder", ws)
	}
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil || len(wk.take()) != 0 {
		t.Fatal("a second nudge inside 12 hours after a queued one")
	}
}

// putToken registers an APNs token for a bound session.
func putToken(h *harness, tok string, b byte) string {
	h.t.Helper()
	wantStatus(h.t, h.req("PUT", "/api/v1/push/apns", tok, PutAPNsRequest{TokenHex: tokenHexFor(b), Environment: "production"}),
		http.StatusNoContent)
	return tokenHexFor(b)
}

// Spec 02 §12.5: a revoked writer and the devices a logout-all signs out are
// woken through tokens collected before their rows went away.
func TestRevokeAndLogoutAllWakeCollectedTokens(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	putToken(h, k.token, 1)
	t2 := putToken(h, tok2, 2)
	wk.take()

	su := k.stepUp(k.token, keyproto.ActionWriterRevoke, []byte(d2.WriterID))
	n := k.nonce(k.token)
	rm, _ := keyproto.RevocationMessage(n, d2.WriterID, 0, make([]byte, 32))
	wantStatus(t, h.req("POST", "/api/v1/writers/revoke", k.token, RevokeRequest{WriterID: d2.WriterID,
		SignerWriterID: k.device.WriterID, Nonce: b64(n), FinalCounter: "0", FinalHead: b64(make([]byte, 32)),
		Sig: b64(ed25519.Sign(k.device.DWK, rm)), StepUp: su}), http.StatusNoContent)
	if h.countAPNs(k.user) != 1 {
		t.Fatal("the revoked writer's token survived")
	}
	ws := wk.take()
	if len(ws) != 2 || !ws[0].others || ws[0].writer != k.device.WriterID || ws[0].r != pushv2.ReasonSecurity ||
		len(ws[1].tokens) != 1 || ws[1].tokens[0] != t2 || ws[1].r != pushv2.ReasonSecurity {
		t.Fatalf("revoke wakes %+v, want the others and the revoked writer's token", ws)
	}

	// logout-all: every other device's token, never the caller's.
	d3 := authtest.NewDevice(t)
	tok3 := k.enrol(d3)
	t3 := putToken(h, tok3, 3)
	wk.take()
	// It needs a session.logout_all step-up (spec 02 §9.3).
	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", k.token, map[string]any{}), http.StatusForbidden)
	if ws := wk.take(); len(ws) != 0 {
		t.Fatalf("a refused logout-all woke %+v", ws)
	}
	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionSessionLogoutAll)}), http.StatusNoContent)
	if h.countAPNs(k.user) != 0 {
		t.Fatal("logout-all left tokens")
	}
	ws = wk.take()
	if len(ws) != 1 || len(ws[0].tokens) != 1 || ws[0].tokens[0] != t3 || ws[0].r != pushv2.ReasonSecurity {
		t.Fatalf("logout-all wakes %+v, want only the other device's token", ws)
	}
}

// Spec 02 §12.5: account deletion wakes every device, account-gone, through
// tokens collected before the purge.
func TestAccountDeletionWakesEveryDevice(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	acc := h.deletable(t, "wake")
	h.bind(acc.tok, "ios-00000000-0000-4000-8000-000000000206")
	tk := putToken(h, acc.tok, 5)
	wk.take()
	wantStatus(t, h.req("DELETE", "/api/v1/account", acc.tok, acc.body(t, h)), http.StatusNoContent)
	ws := wk.take()
	if len(ws) != 1 || len(ws[0].tokens) != 1 || ws[0].tokens[0] != tk || ws[0].r != pushv2.ReasonAccountGone {
		t.Fatalf("deletion wakes %+v", ws)
	}
}
