package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

func watchedOutlookLink(t *testing.T, h *harness, o *OutlookOptions, name, writer, clientState string) uuid.UUID {
	t.Helper()
	u := outlookLinkRow(h, o, name, writer, clientState)
	if _, err := h.pool.Exec(bg, `UPDATE mailbox_links SET watch_expires_at = now() + interval '5 days',
		created_at = now() - interval '2 hours' WHERE user_id = $1`, u); err != nil {
		t.Fatal(err)
	}
	return u
}

func outlookWatch(t *testing.T, h *harness, u uuid.UUID) *time.Time {
	t.Helper()
	var at *time.Time
	if err := h.pool.QueryRow(bg, `SELECT watch_expires_at FROM mailbox_links WHERE user_id = $1`, u).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func TestOutlookSubscriptionRemovedEndsTheWatch(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	holder := "ios-91111111-1111-4111-8111-111111111111"
	u := watchedOutlookLink(t, h, o, "removed", holder, testClientState)
	other := watchedOutlookLink(t, h, o, "other", "ios-92222222-2222-4222-8222-222222222222", otherClientState)

	for _, ev := range []string{"missed", "reauthorizationRequired"} {
		wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, ev))), http.StatusAccepted)
		if outlookWatch(t, h, u) == nil {
			t.Fatalf("%s ended a subscription that is still live", ev)
		}
	}
	wk.take()
	nudged := &recWaker{}
	if _, err := gmailpush.Nudge(bg, h.pool, nudged, gmailpush.ProviderOutlook); err != nil || len(nudged.take()) != 0 {
		t.Fatalf("a live watch was nudged (%v)", err)
	}

	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))),
		http.StatusAccepted)
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != holder || ws[0].r != pushv2.ReasonNudge {
		t.Fatalf("wakes %+v, want one nudge", ws)
	}
	if at := outlookWatch(t, h, u); at != nil {
		t.Fatalf("a removed subscription still reads as a watch until %v", at)
	}
	if outlookWatch(t, h, other) == nil {
		t.Fatal("another link's watch ended")
	}
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))),
		http.StatusAccepted)
	if _, err := gmailpush.Nudge(bg, h.pool, nudged, gmailpush.ProviderOutlook); err != nil {
		t.Fatal(err)
	}
	if ws := nudged.take(); len(ws) != 1 || ws[0].writer != holder {
		t.Fatalf("the nudge sweep woke %+v, want the holder of the removed subscription", ws)
	}
}

func TestOutlookSubscriptionRemovedOnTheChangePathIsIgnored(t *testing.T) {
	h := newHarness(t)
	_, o, _ := withOutlook(h, outlookPushOn())
	u := watchedOutlookLink(t, h, o, "main-path", "ios-93333333-3333-4333-8333-333333333333", testClientState)
	wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))),
		http.StatusAccepted)
	if outlookWatch(t, h, u) == nil {
		t.Fatal("the change path ended a watch")
	}
}

func TestOutlookSubscriptionRemovedOverTheLinkBudgetStillEndsTheWatch(t *testing.T) {
	h := newHarness(t)
	wk, o, _ := withOutlook(h, outlookPushOn())
	u := watchedOutlookLink(t, h, o, "budget", "ios-94444444-4444-4444-8444-444444444444", testClientState)
	for range hookLinkBurst {
		wantStatus(t, h.graph(outlookHookPath, "", graphBody(t, note(testClientState))), http.StatusAccepted)
	}
	wk.take()
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))),
		http.StatusAccepted)
	if len(wk.take()) != 0 || o.Push.Counters.LinkLimited.Load() != 1 {
		t.Fatalf("expected the wake to be limited (limited %d)", o.Push.Counters.LinkLimited.Load())
	}
	if at := outlookWatch(t, h, u); at != nil {
		t.Fatalf("a link over its wake budget kept the watch until %v", at)
	}
}

func TestOutlookSubscriptionRemovedWritesNothingThroughATrippedFuse(t *testing.T) {
	h := newHarness(t)
	h.srv.Headroom = &fakeFuse{tripped: true}
	wk, o, _ := withOutlook(h, outlookPushOn())
	u := watchedOutlookLink(t, h, o, "fuse", "ios-95555555-5555-4555-8555-555555555555", testClientState)
	wantStatus(t, h.graph(outlookLifecyclePath, "", graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))),
		http.StatusAccepted)
	if len(wk.take()) != 1 {
		t.Fatal("the nudge did not go out through a tripped fuse")
	}
	if outlookWatch(t, h, u) == nil {
		t.Fatal("a row was written through a tripped fuse")
	}
}

func TestOutlookSubscriptionRemovedThatCannotBeRecordedIsRetried(t *testing.T) {
	h := newHarness(t)
	logs := &capturedLogs{}
	h.srv.Logf = logs.logf
	wk, o, _ := withOutlook(h, outlookPushOn())
	u := watchedOutlookLink(t, h, o, "retry", "ios-96666666-6666-4666-8666-666666666666", testClientState)
	cfg := h.pool.Config().Copy()
	cfg.ConnConfig.RuntimeParams["default_transaction_read_only"] = "on"
	readOnly, err := pgxpool.NewWithConfig(bg, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer readOnly.Close()
	live := h.srv.Pool
	h.srv.Pool = readOnly
	body := graphBody(t, lifecycleNote(testClientState, "subscriptionRemoved"))
	for range hookLinkBurst + 5 {
		wantStatus(t, h.graph(outlookLifecyclePath, "", body), http.StatusServiceUnavailable)
	}
	if len(wk.take()) != 0 || o.Push.Counters.LinkLimited.Load() != 0 {
		t.Fatalf("a failed write spent the budget (limited %d)", o.Push.Counters.LinkLimited.Load())
	}
	if strings.Contains(logs.String(), testClientState) {
		t.Fatalf("the failure log holds the clientState:\n%s", logs.String())
	}
	h.srv.Pool = live
	wantStatus(t, h.graph(outlookLifecyclePath, "", body), http.StatusAccepted)
	if len(wk.take()) != 1 || outlookWatch(t, h, u) != nil {
		t.Fatal("the retry did not end the watch and wake the holder")
	}
}
