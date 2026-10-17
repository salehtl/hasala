package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// Synthetic clientStates, the link's shape: 43 base64url characters.
var (
	testClientState  = strings.Repeat("Q", 40) + "x-_"
	otherClientState = strings.Repeat("r", 40) + "9Z_"
	// A message id and resource shaped like Graph's, synthetic.
	testMessageID = "AAMkADsyntheticmessageid000000000000000000000000000000AAA="
	testResource  = "Users/00000000-0000-0000-0000-000000000000/Messages/" + testMessageID
)

func outlookPushOn() *OutlookPush {
	return &OutlookPush{NotificationURL: testOutlookNotify, LifecycleURL: testOutlookLife}
}

// outlookLinkRow inserts an Outlook link for a fresh account, routed by
// SHA-256(clientState).
func outlookLinkRow(h *harness, o *OutlookOptions, sub, writer, clientState string) uuid.UUID {
	h.t.Helper()
	u := h.user(sub)
	h.writer(u, writer)
	sum := sha256.Sum256([]byte(clientState))
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		client_state_hash, created_at, updated_at) VALUES ($1, 'outlook', $2, $3, $4, $5, now(), now())`,
		u, o.RouteKey.AddressHMACFor(gmailpush.ProviderOutlook, sub+"@outlook.example"), o.RouteKey.KeyID(), writer,
		sum[:]); err != nil {
		h.t.Fatal(err)
	}
	return u
}

func (h *harness) graph(path, query string, body []byte) *httptest.ResponseRecorder {
	if query != "" {
		path += "?" + query
	}
	r := httptest.NewRequest("POST", path, bytes.NewReader(body))
	if len(body) > 0 {
		r.Header.Set("Content-Type", "application/json")
	} else {
		r.Header.Set("Content-Type", "text/plain")
	}
	w := httptest.NewRecorder()
	h.h.ServeHTTP(w, r)
	return w
}

// graphBody is a notification collection shaped like Graph's: every entry
// names the message through resource and resourceData.
func graphBody(t *testing.T, entries ...map[string]any) []byte {
	t.Helper()
	for _, e := range entries {
		if _, ok := e["resource"]; !ok {
			e["subscriptionId"] = "11111111-2222-4333-8444-555555555555"
			e["changeType"] = "created"
			e["tenantId"] = "9188040d-6c67-4c5b-b112-36a304b66dad"
			e["resource"] = testResource
			e["resourceData"] = map[string]any{"@odata.type": "#Microsoft.Graph.Message", "id": testMessageID}
		}
	}
	b, err := json.Marshal(map[string]any{"value": entries})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func note(cs string) map[string]any { return map[string]any{"clientState": cs} }

func lifecycleNote(cs, event string) map[string]any {
	return map[string]any{"clientState": cs, "lifecycleEvent": event}
}

func TestOutlookHookPathsAreTheConfiguredOnes(t *testing.T) {
	if outlookHookPath != config.OutlookNotificationPath || outlookLifecyclePath != config.OutlookLifecyclePath {
		t.Fatalf("hook paths %q %q, config %q %q", outlookHookPath, outlookLifecyclePath,
			config.OutlookNotificationPath, config.OutlookLifecyclePath)
	}
}

// The hooks exist only with the Outlook push: not with the link alone, nor
// with Gmail's push.
func TestOutlookHookIsMountedOnlyWithItsPush(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{outlookHookPath, outlookLifecyclePath} {
		wantNotFound(t, h.graph(p, "validationToken=abc", nil), "no mailbox at all")
	}
	withPushAndGmail(h)
	withOutlook(h, nil)
	for _, p := range []string{outlookHookPath, outlookLifecyclePath} {
		wantNotFound(t, h.graph(p, "validationToken=abc", nil), "the Outlook link without its push")
	}
	withOutlook(h, outlookPushOn())
	for _, p := range []string{outlookHookPath, outlookLifecyclePath} {
		wantStatus(t, h.graph(p, "validationToken=abc", nil), http.StatusOK)
		wantNotFound(t, h.graph(p+"/", "validationToken=abc", nil), "a trailing slash")
		w := httptest.NewRecorder()
		h.h.ServeHTTP(w, httptest.NewRequest("GET", p+"?validationToken=abc", nil))
		if w.Code == http.StatusOK {
			t.Fatalf("GET %s was served", p)
		}
	}
}

// The validation handshake: the token back as text/plain, with nosniff and
// no-store, after no database work, and counted by the per-IP and global
// budgets.
func TestOutlookHookValidation(t *testing.T) {
	h := newHarness(t)
	push := outlookPushOn()
	push.HookPerIP = NewLimiter(0, 8, 16, time.Now)
	_, o, _ := withOutlook(h, push)

	// No database: the handshake still answers.
	dead, err := pgxpool.New(bg, h.pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	dead.Close()
	h.srv.Pool = dead

	tok := "Validation: Token=+/ 1~2"
	for _, p := range []string{outlookHookPath, outlookLifecyclePath} {
		w := h.graph(p, "validationToken="+url.QueryEscape(tok), nil)
		wantStatus(t, w, http.StatusOK)
		if w.Body.String() != tok {
			t.Fatalf("%s echoed %q, want %q", p, w.Body.String(), tok)
		}
		for k, v := range map[string]string{
			"Content-Type":           "text/plain; charset=utf-8",
			"X-Content-Type-Options": "nosniff",
			"Cache-Control":          "no-store",
		} {
			if got := w.Header().Values(k); len(got) != 1 || got[0] != v {
				t.Fatalf("%s: %s = %q, want %q", p, k, got, v)
			}
		}
	}
	wantStatus(t, h.graph(outlookHookPath, "validationToken="+strings.Repeat("x", 256), nil), http.StatusOK)
	if o.Push.Counters.Validations.Load() != 3 {
		t.Fatalf("validations counted %d", o.Push.Counters.Validations.Load())
	}

	// Refused tokens: too long, not printable ASCII, empty, twice.
	for _, q := range []string{
		"validationToken=" + strings.Repeat("x", 257),
		"validationToken=" + url.QueryEscape("line\nbreak"),
		"validationToken=" + url.QueryEscape("caf\u00e9"),
		"validationToken=",
		"validationToken=a&validationToken=b",
	} {
		w := h.graph(outlookHookPath, q, nil)
		wantStatus(t, w, http.StatusBadRequest)
		if strings.Contains(w.Body.String(), "break") || strings.Contains(w.Body.String(), "xxxx") {
			t.Fatalf("a refused token was echoed: %s", w.Body)
		}
	}
	if o.Push.Counters.BadValidation.Load() != 5 {
		t.Fatalf("bad validations counted %d", o.Push.Counters.BadValidation.Load())
	}

	// hook-ip: the handshakes above spent the budget of 8.
	w := h.graph(outlookHookPath, "validationToken=abc", nil)
	wantStatus(t, w, http.StatusTooManyRequests)
}

func TestOutlookHookValidationCountsAgainstTheGlobalBudget(t *testing.T) {
	h := newHarness(t)
	push := outlookPushOn()
	push.HookGlobal = NewLimiter(0, 2, 1, time.Now)
	withOutlook(h, push)
	wantStatus(t, h.graph(outlookHookPath, "validationToken=a", nil), http.StatusOK)
	wantStatus(t, h.graph(outlookLifecyclePath, "validationToken=a", nil), http.StatusOK)
	wantStatus(t, h.graph(outlookHookPath, "validationToken=a", nil), http.StatusTooManyRequests)
}

// A token with a body is no handshake: 204, a counter, no echo, no wake.
func TestOutlookHookTokenWithBody(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	outlookLinkRow(h, o, "tok-body", "ios-61111111-1111-4111-8111-111111111111", testClientState)
	w := h.graph(outlookHookPath, "validationToken=abc", graphBody(t, note(testClientState)))
	wantStatus(t, w, http.StatusNoContent)
	if w.Body.Len() != 0 || o.Push.Counters.ValidationWithBody.Load() != 1 || len(wk.take()) != 0 {
		t.Fatalf("token with body: %q, counted %d", w.Body, o.Push.Counters.ValidationWithBody.Load())
	}
}

// Notifications: the holder is woken for mail, duplicates collapse, unknown
// and bad clientStates are counters, malformed bodies are 204, and nothing
// that names the message or the clientState reaches the log or the database.
func TestOutlookHookNotifications(t *testing.T) {
	h := newHarness(t)
	logs := &capturedLogs{}
	h.srv.Logf = logs.logf
	wk, o, _ := withOutlook(h, outlookPushOn())
	c := &o.Push.Counters
	holder := "ios-62222222-2222-4222-8222-222222222222"
	u := outlookLinkRow(h, o, "notify", holder, testClientState)

	// One notification, three times in one body: one wake, for mail.
	w := h.graph(outlookHookPath, "", graphBody(t, note(testClientState), note(testClientState), note(testClientState)))
	wantStatus(t, w, http.StatusAccepted)
	if w.Body.Len() != 0 {
		t.Fatalf("the hook answered a body: %q", w.Body)
	}
	ws := wk.take()
	if len(ws) != 1 || ws[0].others || ws[0].user != u || ws[0].writer != holder || ws[0].r != pushv2.ReasonMail {
		t.Fatalf("wakes %+v, want the holder once", ws)
	}
	var hour *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_wake_hour FROM mailbox_links WHERE user_id = $1`, u).Scan(&hour); err != nil ||
		hour == nil {
		t.Fatalf("last_wake_hour not recorded: %v", err)
	}

	// Unknown and badly shaped clientStates: 202, counted, nobody woken.
	wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(otherClientState))), http.StatusAccepted)
	wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note("short"), map[string]any{"changeType": "created"},
		note(testClientState[:42]+"="))), http.StatusAccepted)
	if c.Unknown.Load() != 1 || c.BadClientState.Load() != 3 || len(wk.take()) != 0 {
		t.Fatalf("unknown %d, bad %d", c.Unknown.Load(), c.BadClientState.Load())
	}

	// Malformed bodies: 204 and a counter, as Gmail's hook answers.
	many := make([]map[string]any, 101)
	for i := range many {
		many[i] = note(testClientState)
	}
	for _, b := range [][]byte{nil, []byte("hello"), []byte(`{"value":[]}`), []byte(`[{"clientState":"x"}]`),
		graphBody(t, many...)} {
		wantStatus(t, h.graph(outlookHookPath, "", b), http.StatusNoContent)
	}
	if c.Malformed.Load() != 5 || len(wk.take()) != 0 {
		t.Fatalf("malformed counted %d", c.Malformed.Load())
	}
	big := append([]byte(`{"value":[{"clientState":"`+testClientState+`","pad":"`), bytes.Repeat([]byte("x"), 64<<10)...)
	wantStatus(t, h.graph(outlookHookPath, "", append(big, `"}]}`...)), http.StatusRequestEntityTooLarge)

	// Nothing that names the message, nor the clientState or its hash, was
	// logged or stored.
	sum := sha256.Sum256([]byte(testClientState))
	for _, s := range []string{testMessageID, "Messages/", testClientState, otherClientState, hex.EncodeToString(sum[:])} {
		if strings.Contains(logs.String(), s) {
			t.Fatalf("the log holds %q:\n%s", s, logs.String())
		}
	}
	assertNoAddress(t, h, testMessageID)
	assertNoAddress(t, h, testClientState)
}

// Lifecycle events wake the holder with a nudge; other events wake nobody.
func TestOutlookLifecycleHook(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	holder := "ios-63333333-3333-4333-8333-333333333333"
	u := outlookLinkRow(h, o, "lifecycle", holder, testClientState)
	for _, ev := range []string{"reauthorizationRequired", "subscriptionRemoved", "missed"} {
		wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, ev))), http.StatusAccepted)
		ws := wk.take()
		if len(ws) != 1 || ws[0].user != u || ws[0].writer != holder || ws[0].r != pushv2.ReasonNudge {
			t.Fatalf("%s wakes %+v, want one nudge", ev, ws)
		}
	}
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "somethingNew"),
		note(testClientState))), http.StatusAccepted)
	if ws := wk.take(); len(ws) != 0 || o.Push.Counters.Ignored.Load() != 2 {
		t.Fatalf("an unknown lifecycle event woke %+v (ignored %d)", ws, o.Push.Counters.Ignored.Load())
	}
	// A nudge is not mail: no wake hour.
	var hour *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_wake_hour FROM mailbox_links WHERE user_id = $1`, u).Scan(&hour); err != nil ||
		hour != nil {
		t.Fatalf("a lifecycle event recorded a wake hour: %v %v", hour, err)
	}
}

// hook-link: one link's burst runs out; another link is unaffected.
func TestOutlookHookLinkLimiter(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	outlookLinkRow(h, o, "limit-a", "ios-64444444-4444-4444-8444-444444444444", testClientState)
	b := outlookLinkRow(h, o, "limit-b", "ios-65555555-5555-4555-8555-555555555555", otherClientState)
	for range 20 {
		wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(testClientState))), http.StatusAccepted)
	}
	limited := o.Push.Counters.LinkLimited.Load()
	if limited == 0 || len(wk.take()) >= 20 {
		t.Fatal("hook-link never limited one link")
	}
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(otherClientState, "missed"))),
		http.StatusAccepted)
	if ws := wk.take(); len(ws) != 1 || ws[0].user != b || o.Push.Counters.LinkLimited.Load() != limited {
		t.Fatalf("another link was limited by the first one's budget: %+v", ws)
	}
}

// Made-up clientStates never reach hook-link: a flood of them cannot fill the
// limiter and push a real link into its shared fallback, so the real link is
// still woken and nothing is counted as link-limited.
func TestOutlookHookUnknownClientStatesSpendNoLinkBudget(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	o.Push.HookPerIP = NewLimiter(1e6, 1e6, 10, time.Now)
	o.Push.HookGlobal = NewLimiter(1e6, 1e6, 1, time.Now)
	o.Push.HookLink = NewLimiter(hookLinkRate, hookLinkBurst, 4, time.Now)
	u := outlookLinkRow(h, o, "flood", "ios-66666666-6666-4666-8666-666666666666", testClientState)
	for i := range 20 {
		entries := make([]map[string]any, 0, 100)
		for j := range 100 {
			entries = append(entries, note(strings.Repeat("A", 32)+fmt.Sprintf("%011d", i*100+j)))
		}
		wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, entries...)), http.StatusAccepted)
	}
	if n := o.Push.Counters.Unknown.Load(); n != 2000 {
		t.Fatalf("unknown %d, want 2000", n)
	}
	for range 3 {
		wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(testClientState))), http.StatusAccepted)
	}
	ws := wk.take()
	if len(ws) != 3 || ws[0].user != u || o.Push.Counters.LinkLimited.Load() != 0 {
		t.Fatalf("after the flood the real link woke %d times (limited %d)", len(ws), o.Push.Counters.LinkLimited.Load())
	}
}

// A route that cannot be read is 503, so Graph retries; nobody is woken.
func TestOutlookHookDatabaseFailure(t *testing.T) {
	h := newHarness(t)
	logs := &capturedLogs{}
	h.srv.Logf = logs.logf
	wk, o, _ := withOutlook(h, outlookPushOn())
	outlookLinkRow(h, o, "dbfail", "ios-66666666-6666-4666-8666-666666666666", testClientState)
	dead, err := pgxpool.New(bg, h.pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	dead.Close()
	h.srv.Pool = dead
	for _, p := range []string{outlookHookPath, outlookLifecyclePath} {
		wantStatus(t, h.graph(p, "", graphBody(t, lifecycleNote(testClientState, "missed"))), http.StatusServiceUnavailable)
	}
	if len(wk.take()) != 0 {
		t.Fatal("a failed route woke someone")
	}
	if strings.Contains(logs.String(), testClientState) || strings.Contains(logs.String(), testMessageID) {
		t.Fatalf("the failure log holds the notification:\n%s", logs.String())
	}
}

// The hooks are exempt from the headroom fuse, like Gmail's, and skip the
// wake-hour write while it is tripped.
func TestOutlookHookPassesTheHeadroomFuse(t *testing.T) {
	h := newHarness(t)
	h.srv.Headroom = &fakeFuse{tripped: true}
	wk, o, _ := withOutlook(h, outlookPushOn())
	u := outlookLinkRow(h, o, "fuse", "ios-67777777-7777-4777-8777-777777777777", testClientState)
	wantStatus(t, h.graph(outlookHookPath, "validationToken=abc", nil), http.StatusOK)
	wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(testClientState))), http.StatusAccepted)
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "missed"))),
		http.StatusAccepted)
	if len(wk.take()) != 2 {
		t.Fatal("the hooks did not wake through a tripped fuse")
	}
	var hour *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_wake_hour FROM mailbox_links WHERE user_id = $1`, u).Scan(&hour); err != nil ||
		hour != nil {
		t.Fatalf("a wake hour was written through a tripped fuse: %v %v", hour, err)
	}
}

// The clientState the link returns is the one the hook routes by.
func TestOutlookLinkThenHook(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _, _ := withOutlook(h, outlookPushOn())
	k := h.onboard(true)
	w := linkAs(k, k.token, "outlook", fakeMSToken(goodMSClaims(linkChallenge(h, k.token))))
	wantStatus(t, w, http.StatusOK)
	cs := decodeJSON[LinkResponse](t, w).ClientState
	wk.take()
	wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(cs))), http.StatusAccepted)
	if ws := wk.take(); len(ws) != 1 || ws[0].user != k.user || ws[0].writer != k.device.WriterID ||
		ws[0].r != pushv2.ReasonMail {
		t.Fatalf("wakes %+v, want the linking device", ws)
	}
}

// The Gmail hook routes only Gmail links, even to an Outlook row that carries
// the very address HMAC the notice computes.
func TestGmailHookIgnoresOutlookLinks(t *testing.T) {
	h := newHarness(t)
	wk, g := withPushAndGmail(h)
	_, o, _ := withOutlook(h, outlookPushOn())
	u := outlookLinkRow(h, o, "gmail-ignores", "ios-68888888-8888-4888-8888-888888888888", testClientState)
	if _, err := h.pool.Exec(bg, `UPDATE mailbox_links SET address_hmac = $2 WHERE user_id = $1`, u,
		g.RouteKey.AddressHMAC(testMailbox)); err != nil {
		t.Fatal(err)
	}
	pushToken := "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
	wantStatus(t, h.hook(pushToken, pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": "1"})),
		http.StatusNoContent)
	if ws := wk.take(); len(ws) != 0 || g.Push.Counters.Unknown.Load() != 1 {
		t.Fatalf("the Gmail hook woke an Outlook link: %+v", ws)
	}
	// And the two hooks share one per-IP budget, but not the global one.
	if g.Push.HookPerIP != o.Push.HookPerIP {
		t.Fatal("the hooks have separate per-IP budgets")
	}
	if g.Push.HookGlobal == nil || o.Push.HookGlobal == nil || g.Push.HookGlobal == o.Push.HookGlobal {
		t.Fatal("the hooks share one global budget")
	}
}

// The nudge visits only the providers whose push is on.
func TestNudgeIsPerProvider(t *testing.T) {
	h := newHarness(t)
	_, o, _ := withOutlook(h, outlookPushOn())
	holder := "ios-69999999-9999-4999-8999-999999999999"
	outlookLinkRow(h, o, "nudge-outlook", holder, testClientState)
	if _, err := h.pool.Exec(bg, `UPDATE mailbox_links SET watch_expires_at = now() + interval '30 hours'`); err != nil {
		t.Fatal(err)
	}
	wk := &recWaker{}
	if _, err := gmailpush.Nudge(bg, h.pool, wk); err != nil || len(wk.take()) != 0 {
		t.Fatal("a nudge with no provider woke someone")
	}
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail); err != nil || len(wk.take()) != 0 {
		t.Fatal("the Gmail nudge woke an Outlook holder")
	}
	if _, err := gmailpush.Nudge(bg, h.pool, wk, gmailpush.ProviderGmail, gmailpush.ProviderOutlook); err != nil {
		t.Fatal(err)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != holder || ws[0].r != pushv2.ReasonNudge {
		t.Fatalf("nudges %+v", ws)
	}
}
