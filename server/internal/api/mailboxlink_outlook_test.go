package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/msjwt"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// fakeMSVerifier stands in for msjwt: a token is base64url(JSON claims), or
// "down" (the key set is unreachable), or anything else (rejected). Calls are
// counted, so a test can show a refusal came before any verification.
type fakeMSVerifier struct {
	audience string
	calls    *atomic.Int64
}

type fakeMSClaims struct {
	Aud, Tid, Email, PreferredUsername, Nonce string
	Iat                                       time.Time
}

func (f fakeMSVerifier) Verify(_ context.Context, tok string) (msjwt.Claims, error) {
	f.calls.Add(1)
	if tok == "down" {
		return msjwt.Claims{}, msjwt.ErrKeySetUnavailable
	}
	raw, err := base64.RawURLEncoding.DecodeString(tok)
	if err != nil {
		return msjwt.Claims{}, msjwt.ErrTokenRejected
	}
	var c fakeMSClaims
	if json.Unmarshal(raw, &c) != nil {
		return msjwt.Claims{}, msjwt.ErrTokenRejected
	}
	// Like msjwt, the audience is checked by the verifier; the route checks
	// it again, which "a verifier for another client" below exercises.
	if f.audience != "" && c.Aud != f.audience {
		return msjwt.Claims{}, msjwt.ErrTokenRejected
	}
	return msjwt.Claims{Aud: []string{c.Aud}, Tid: c.Tid, Email: c.Email, PreferredUsername: c.PreferredUsername,
		Nonce: c.Nonce, Iat: c.Iat}, nil
}

func fakeMSToken(c fakeMSClaims) string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

const (
	testOutlookClient  = "00000000-1111-4222-8333-444444444444"
	testOutlookMailbox = "Someone.Else@Outlook.example"
	testOutlookNotify  = "https://api.hasala.app/hooks/outlook/graph"
	testOutlookLife    = "https://api.hasala.app/hooks/outlook/graph/lifecycle"
)

func goodMSClaims(nonce string) fakeMSClaims {
	return fakeMSClaims{Aud: testOutlookClient, Tid: msjwt.ConsumersTenantID, Email: testOutlookMailbox, Nonce: nonce,
		Iat: time.Now().Add(-time.Minute)}
}

// withOutlook mounts the Outlook link (and its push when push is not nil) on
// the same route key and limiter withGmail uses, beside whatever Gmail
// options h already has.
func withOutlook(h *harness, push *OutlookPush) (*recWaker, *OutlookOptions, *atomic.Int64) {
	h.t.Helper()
	rk, err := gmailpush.NewRouteKey(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		h.t.Fatal(err)
	}
	w, ok := h.srv.Push.Waker.(*recWaker)
	if !ok {
		w = &recWaker{}
		h.srv.Push.Waker = w
	}
	calls := &atomic.Int64{}
	o := &OutlookOptions{RouteKey: rk, Link: fakeMSVerifier{audience: testOutlookClient, calls: calls},
		ClientID: testOutlookClient, MailboxPerUser: NewLimiter(1000, 1000, 100, time.Now), Push: push}
	h.srv.Outlook = o
	h.h = h.srv.Handler()
	return w, o, calls
}

func linkAs(k *keyed, tok, provider, idToken string) *httptest.ResponseRecorder {
	k.h.t.Helper()
	th := sha256.Sum256([]byte(idToken))
	return k.h.req("PUT", "/api/v1/mailbox/link", tok, LinkRequest{Provider: provider, IDToken: idToken,
		StepUp: k.stepUp(tok, keyproto.ActionMailboxLink, th[:])})
}

// capturedLogs collects the operator log.
type capturedLogs struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (c *capturedLogs) logf(f string, a ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	fmt.Fprintf(&c.buf, f+"\n", a...)
}

func (c *capturedLogs) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

// The Outlook link: the same nonce and step-up as Gmail's, Microsoft's claim
// rules, a clientState returned once and kept only as its hash, and the
// address only as an HMAC under the Outlook domain.
func TestOutlookMailboxLink(t *testing.T) {
	h := newHarness(t).passkeys()
	logs := &capturedLogs{}
	h.srv.Logf = logs.logf
	wk, o, calls := withOutlook(h, &OutlookPush{NotificationURL: testOutlookNotify, LifecycleURL: testOutlookLife})
	k := h.onboard(true)
	n := linkChallenge(h, k.token)

	// Without a step-up: 403 step_up_required, and the token is not verified.
	w := h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{Provider: "outlook", IDToken: fakeMSToken(goodMSClaims(n))})
	if w.Code != http.StatusForbidden || decodeJSON[errorBody](t, w).Error != "step_up_required" {
		t.Fatalf("no step-up: %d %s", w.Code, w.Body)
	}
	if calls.Load() != 0 {
		t.Fatal("the ID token was verified before the step-up was asked for")
	}

	// Claim failures: each a 403 link_rejected.
	other := h.session(k.user)
	h.bind(other, k.device.WriterID)
	foreign := linkChallenge(h, other)
	o.Link = fakeMSVerifier{calls: calls} // the route's own audience check
	h.h = h.srv.Handler()
	for name, c := range map[string]fakeMSClaims{
		"another session's nonce": goodMSClaims(foreign),
		"tid of another tenant": func() fakeMSClaims {
			c := goodMSClaims(n)
			c.Tid = "11111111-2222-4333-8444-555555555555"
			return c
		}(),
		"no tid":    func() fakeMSClaims { c := goodMSClaims(n); c.Tid = ""; return c }(),
		"wrong aud": func() fakeMSClaims { c := goodMSClaims(n); c.Aud = "99999999-1111-4222-8333-444444444444"; return c }(),
		"old iat":   func() fakeMSClaims { c := goodMSClaims(n); c.Iat = time.Now().Add(-11 * time.Minute); return c }(),
		"no email": func() fakeMSClaims {
			c := goodMSClaims(n)
			c.Email, c.PreferredUsername = "", "+971500000000"
			return c
		}(),
		"bad nonce": func() fakeMSClaims { c := goodMSClaims(n); c.Nonce = "short"; return c }(),
	} {
		w := linkAs(k, k.token, "outlook", fakeMSToken(c))
		if w.Code != http.StatusForbidden || decodeJSON[errorBody](t, w).Error != "link_rejected" {
			t.Fatalf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	o.Link = fakeMSVerifier{audience: testOutlookClient, calls: calls}
	h.h = h.srv.Handler()
	wantStatus(t, linkAs(k, k.token, "outlook", "down"), http.StatusServiceUnavailable)
	// A Google-shaped token is not an Outlook one.
	if w := linkAs(k, k.token, "outlook", fakeToken(goodClaims(n))); w.Code != http.StatusForbidden {
		t.Fatalf("a Google token linked Outlook: %d", w.Code)
	}

	// The address from preferred_username when there is no email claim.
	good := goodMSClaims(n)
	good.Email, good.PreferredUsername = "", testOutlookMailbox
	w = linkAs(k, k.token, "outlook", fakeMSToken(good))
	wantStatus(t, w, http.StatusOK)
	got := decodeJSON[LinkResponse](t, w)
	if got.Provider != "outlook" || got.Holder.WriterID != k.device.WriterID || !got.Holder.IsThisDevice {
		t.Fatalf("link %+v", got)
	}
	cs, err := base64.RawURLEncoding.DecodeString(got.ClientState)
	if err != nil || len(cs) != 32 {
		t.Fatalf("client_state %q is not 32 bytes of base64url", got.ClientState)
	}

	var provider string
	var addr, csHash []byte
	if err := h.pool.QueryRow(bg, `SELECT provider, address_hmac, client_state_hash FROM mailbox_links WHERE user_id = $1`,
		k.user).Scan(&provider, &addr, &csHash); err != nil {
		t.Fatal(err)
	}
	wantHash := sha256.Sum256([]byte(got.ClientState))
	if provider != "outlook" || !bytes.Equal(csHash, wantHash[:]) ||
		!bytes.Equal(addr, o.RouteKey.AddressHMACFor(gmailpush.ProviderOutlook, testOutlookMailbox)) ||
		bytes.Equal(addr, o.RouteKey.AddressHMAC(testOutlookMailbox)) {
		t.Fatalf("stored %s %x %x", provider, addr, csHash)
	}
	assertNoAddress(t, h, testOutlookMailbox)
	assertNoAddress(t, h, got.ClientState)
	if strings.Contains(logs.String(), got.ClientState) || strings.Contains(strings.ToLower(logs.String()), "someone.else") {
		t.Fatalf("the log holds the clientState or the address:\n%s", logs)
	}
	if ws := wk.take(); len(ws) != 1 || ws[0].r != pushv2.ReasonSecurity || !ws[0].others {
		t.Fatalf("link wakes %+v", ws)
	}

	// #37 reports the provider.
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.Provider != "outlook" ||
		!st.Holder.IsThisDevice || st.WatchExpiresAt != nil {
		t.Fatalf("status %+v", st)
	}

	// #36: a Graph subscription lasts at most 7 days.
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token,
		LinkWatchRequest{ExpiresAt: time.Now().Add(7*24*time.Hour + time.Hour)}), http.StatusBadRequest)
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token,
		LinkWatchRequest{ExpiresAt: time.Now().Add(6*24*time.Hour + 23*time.Hour)}), http.StatusNoContent)
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.WatchExpiresAt == nil {
		t.Fatal("#37 does not report the watch #36 recorded")
	}

	// Linking again mints a new clientState; the old one routes nowhere.
	n2 := linkChallenge(h, k.token)
	w = linkAs(k, k.token, "outlook", fakeMSToken(goodMSClaims(n2)))
	wantStatus(t, w, http.StatusOK)
	again := decodeJSON[LinkResponse](t, w)
	if again.ClientState == got.ClientState || again.ClientState == "" {
		t.Fatal("a second link reused the clientState")
	}
	var count int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM mailbox_links WHERE client_state_hash = $1`, wantHash[:]).
		Scan(&count); err != nil || count != 0 {
		t.Fatalf("the old clientState still routes: %d %v", count, err)
	}

	// #38 removes it.
	wantStatus(t, h.req("DELETE", "/api/v1/mailbox/link", k.token,
		UnlinkRequest{StepUp: k.stepUp(k.token, keyproto.ActionMailboxUnlink)}), http.StatusNoContent)
	wantStatus(t, h.req("GET", "/api/v1/mailbox/link", k.token, nil), http.StatusNotFound)
}

// The provider is settled first: an unknown one, or one this server does not
// link, is a 400 before any step-up or token work.
func TestMailboxLinkProviderIsCheckedFirst(t *testing.T) {
	h := newHarness(t).passkeys()
	withGmail(h, nil)
	k := h.onboard(true)
	for _, p := range []string{"yahoo", "Gmail", "OUTLOOK", "outlook"} {
		w := h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{Provider: p})
		if w.Code != http.StatusBadRequest || decodeJSON[errorBody](t, w).Error != "unsupported_provider" {
			t.Fatalf("provider %q on a Gmail-only server: %d %s", p, w.Code, w.Body)
		}
	}

	h = newHarness(t).passkeys()
	_, _, calls := withOutlook(h, nil)
	k = h.onboard(true)
	for _, p := range []string{"", "gmail", "imap"} {
		w := h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{Provider: p, IDToken: "x"})
		if w.Code != http.StatusBadRequest || decodeJSON[errorBody](t, w).Error != "unsupported_provider" {
			t.Fatalf("provider %q on an Outlook-only server: %d %s", p, w.Code, w.Body)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("an unsupported provider reached a verifier")
	}
	// The Outlook link alone mounts the routes; with no push #36 records nothing.
	n := linkChallenge(h, k.token)
	wantStatus(t, linkAs(k, k.token, "outlook", fakeMSToken(goodMSClaims(n))), http.StatusOK)
	w := h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: time.Now().Add(time.Hour)})
	if w.Code != http.StatusConflict || decodeJSON[errorBody](t, w).Error != "no_watch_topic" {
		t.Fatalf("watch without the push: %d %s", w.Code, w.Body)
	}
}

// One mailbox per account: Gmail replaces Outlook and Outlook replaces Gmail,
// leaving one row; each provider's watch rule follows the row.
func TestLinkingOneProviderReplacesTheOther(t *testing.T) {
	h := newHarness(t).passkeys()
	_, g := withGmail(h, &GmailPush{Topic: testTopic, Hook: fakeVerifier{testAudience}, Subscription: testSub,
		ServiceAccount: testSA})
	_, _, _ = withOutlook(h, nil) // the Graph push is off
	k := h.onboard(true)

	row := func() (provider string, csHash []byte, n int) {
		t.Helper()
		if err := h.pool.QueryRow(bg, `SELECT count(*) FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 1 {
			if err := h.pool.QueryRow(bg, `SELECT provider, client_state_hash FROM mailbox_links WHERE user_id = $1`,
				k.user).Scan(&provider, &csHash); err != nil {
				t.Fatal(err)
			}
		}
		return
	}

	// Gmail, by default.
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token,
		LinkWatchRequest{ExpiresAt: time.Now().Add(7*24*time.Hour + time.Hour)}), http.StatusNoContent)
	if p, cs, n := row(); n != 1 || p != "gmail" || cs != nil {
		t.Fatalf("after gmail: %d rows, %s %x", n, p, cs)
	}

	// Outlook replaces it, watch and all.
	w := linkAs(k, k.token, "outlook", fakeMSToken(goodMSClaims(linkChallenge(h, k.token))))
	wantStatus(t, w, http.StatusOK)
	if p, cs, n := row(); n != 1 || p != "outlook" || len(cs) != 32 {
		t.Fatalf("after outlook: %d rows, %s %x", n, p, cs)
	}
	st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil))
	if st.Provider != "outlook" || st.WatchExpiresAt != nil {
		t.Fatalf("status %+v", st)
	}
	// Gmail's push is on, Outlook's is not: no watch for this link.
	w = h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: time.Now().Add(time.Hour)})
	if w.Code != http.StatusConflict || decodeJSON[errorBody](t, w).Error != "no_watch_topic" {
		t.Fatalf("outlook watch with only gmail's push: %d %s", w.Code, w.Body)
	}

	// And Gmail replaces Outlook again, explicitly named.
	n := linkChallenge(h, k.token)
	tok := fakeToken(goodClaims(n))
	th := sha256.Sum256([]byte(tok))
	w = h.req("PUT", "/api/v1/mailbox/link", k.token, LinkRequest{Provider: "gmail", IDToken: tok,
		StepUp: k.stepUp(k.token, keyproto.ActionMailboxLink, th[:])})
	wantStatus(t, w, http.StatusOK)
	if got := decodeJSON[LinkResponse](t, w); got.Provider != "gmail" || got.ClientState != "" {
		t.Fatalf("gmail link %+v", got)
	}
	if p, cs, n := row(); n != 1 || p != "gmail" || cs != nil {
		t.Fatalf("after gmail again: %d rows, %s %x", n, p, cs)
	}
	var addr []byte
	if err := h.pool.QueryRow(bg, `SELECT address_hmac FROM mailbox_links WHERE user_id = $1`, k.user).Scan(&addr); err != nil ||
		!bytes.Equal(addr, g.RouteKey.AddressHMAC(testMailbox)) {
		t.Fatalf("gmail hmac %x %v", addr, err)
	}
}

// The schema holds the rules on its own: one link per account, and a
// clientState hash exactly on Outlook links.
func TestMailboxLinksSchemaRules(t *testing.T) {
	h := newHarness(t).passkeys()
	withGmail(h, nil)
	k := h.onboard(true)
	rk, _ := gmailpush.NewRouteKey(bytes.Repeat([]byte{7}, 32))
	hash := sha256.Sum256([]byte("synthetic client state"))
	insert := func(provider string, cs []byte) error {
		_, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id,
		    holder_writer_id, client_state_hash, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, now(), now())`,
			k.user, provider, rk.AddressHMACFor(provider, testMailbox), rk.KeyID(), k.device.WriterID, cs)
		return err
	}
	for name, err := range map[string]error{
		"outlook without a hash": insert("outlook", nil),
		"outlook, short hash":    insert("outlook", hash[:16]),
		"gmail with a hash":      insert("gmail", hash[:]),
		"another provider":       insert("imap", nil),
	} {
		if err == nil {
			t.Fatalf("%s: inserted", name)
		}
	}
	if err := insert("gmail", nil); err != nil {
		t.Fatal(err)
	}
	if err := insert("outlook", hash[:]); err == nil {
		t.Fatal("a second link for one account")
	}
}
