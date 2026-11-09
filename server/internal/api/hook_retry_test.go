package api

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pushv2"
)

func gmailHookLink(t *testing.T, h *harness, g *GmailOptions, writer string) uuid.UUID {
	t.Helper()
	u := h.user("hook-retry")
	h.writer(u, writer)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
		VALUES ($1, 'gmail', $2, $3, $4, now(), now())`, u, g.RouteKey.AddressHMAC(testMailbox), g.RouteKey.KeyID(), writer); err != nil {
		t.Fatal(err)
	}
	return u
}

func gmailHookAuth() string {
	return "Bearer " + fakeToken(fakeClaims{Aud: testAudience, Email: testSA, EmailVerified: true})
}

func gmailHookNotice(t *testing.T) []byte {
	t.Helper()
	return pubsubBody(t, testSub, map[string]any{"emailAddress": testMailbox, "historyId": 7})
}

func closedPool(t *testing.T, h *harness) *pgxpool.Pool {
	t.Helper()
	dead, err := pgxpool.New(bg, h.pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	dead.Close()
	return dead
}

func wakeHour(t *testing.T, h *harness, u uuid.UUID) *time.Time {
	t.Helper()
	var hour *time.Time
	if err := h.pool.QueryRow(bg, `SELECT last_wake_hour FROM mailbox_links WHERE user_id = $1`, u).Scan(&hour); err != nil {
		t.Fatal(err)
	}
	return hour
}

func TestGmailHookRouteFailureKeepsTheLinkBudget(t *testing.T) {
	h := newHarness(t)
	wk, g := withPushAndGmail(h)
	holder := "ios-81111111-1111-4111-8111-111111111111"
	u := gmailHookLink(t, h, g, holder)
	live := h.srv.Pool
	h.srv.Pool = closedPool(t, h)
	for i := range hookLinkBurst + 5 {
		if w := h.hook(gmailHookAuth(), gmailHookNotice(t)); w.Code != http.StatusServiceUnavailable {
			t.Fatalf("delivery %d during the outage answered %d, want 503 so Pub/Sub keeps it", i, w.Code)
		}
	}
	if n := g.Push.Counters.LinkLimited.Load(); n != 0 {
		t.Fatalf("the outage spent the link budget: %d limited", n)
	}
	h.srv.Pool = live
	wantStatus(t, h.hook(gmailHookAuth(), gmailHookNotice(t)), http.StatusNoContent)
	if ws := wk.take(); len(ws) != 1 || ws[0].user != u || ws[0].writer != holder {
		t.Fatalf("after the outage the notice woke %+v, want the holder", ws)
	}
}

func TestGmailHookAsksForARetryUntilTheWakeIsQueued(t *testing.T) {
	h := newHarness(t)
	_, g := withPushAndGmail(h)
	wk := &refusingWaker{}
	h.srv.Push.Waker = wk
	holder := "ios-82222222-2222-4222-8222-222222222222"
	u := gmailHookLink(t, h, g, holder)
	for i := range hookLinkBurst + 5 {
		if w := h.hook(gmailHookAuth(), gmailHookNotice(t)); w.Code != http.StatusServiceUnavailable {
			t.Fatalf("delivery %d with a full queue answered %d, want 503 so Pub/Sub keeps it", i, w.Code)
		}
	}
	if n := g.Push.Counters.Woken.Load(); n != 0 {
		t.Fatalf("wakes that were not queued were counted: %d", n)
	}
	if hour := wakeHour(t, h, u); hour != nil {
		t.Fatalf("a wake that was not queued recorded the hour %v", hour)
	}
	wk.accept = true
	wantStatus(t, h.hook(gmailHookAuth(), gmailHookNotice(t)), http.StatusNoContent)
	if ws := wk.take(); len(ws) != 1 || ws[0].writer != holder || ws[0].r != pushv2.ReasonMail {
		t.Fatalf("the retry woke %+v, want the holder", ws)
	}
	if g.Push.Counters.Woken.Load() != 1 || wakeHour(t, h, u) == nil {
		t.Fatalf("the queued wake was not recorded (woken %d)", g.Push.Counters.Woken.Load())
	}
}

func TestGmailHookAsksForARetryWhenTheDispatcherQueueIsFull(t *testing.T) {
	h := newHarness(t)
	_, g := withPushAndGmail(h)
	d := pushv2.NewDispatcher(h.pool, nil)
	h.srv.Push.Waker = d
	gmailHookLink(t, h, g, "ios-85555555-5555-4555-8555-555555555555")
	filler := uuid.New()
	for d.TryWakeWriter(bg, filler, "ios-filler", pushv2.ReasonSync) {
	}
	wantStatus(t, h.hook(gmailHookAuth(), gmailHookNotice(t)), http.StatusServiceUnavailable)
}

type oneWriterRefusingWaker struct {
	recWaker
	mu      sync.Mutex
	refused string
}

func (w *oneWriterRefusingWaker) refuse(writer string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.refused = writer
}

func (w *oneWriterRefusingWaker) TryWakeWriter(ctx context.Context, u uuid.UUID, writer string, r pushv2.Reason) bool {
	w.mu.Lock()
	refused := w.refused
	w.mu.Unlock()
	if writer == refused {
		return false
	}
	w.WakeWriter(ctx, u, writer, r)
	return true
}

func TestOutlookHookAsksForARetryUntilEveryWakeIsQueued(t *testing.T) {
	for _, path := range []string{outlookHookPath, outlookLifecyclePath} {
		t.Run(path, func(t *testing.T) {
			h := newHarness(t)
			_, o, _ := withOutlook(h, outlookPushOn())
			wk := &oneWriterRefusingWaker{}
			h.srv.Push.Waker = wk
			full := "ios-83333333-3333-4333-8333-333333333333"
			open := "ios-84444444-4444-4444-8444-444444444444"
			uFull := outlookLinkRow(h, o, "full", full, testClientState)
			uOpen := outlookLinkRow(h, o, "open", open, otherClientState)
			wk.refuse(full)
			body := graphBody(t, lifecycleNote(testClientState, "missed"), lifecycleNote(otherClientState, "missed"))
			for i := range hookLinkBurst + 5 {
				if w := h.graph(path, "", body); w.Code != http.StatusServiceUnavailable {
					t.Fatalf("delivery %d with a full queue answered %d, want 503 so Graph keeps it", i, w.Code)
				}
			}
			if n := o.Push.Counters.LinkLimited.Load(); n != 0 {
				t.Fatalf("the retries spent the link budget: %d limited", n)
			}
			if n := o.Push.Counters.Woken.Load(); n != int64(hookLinkBurst+5) {
				t.Fatalf("woken %d, want only the wakes that were queued", n)
			}
			if wakeHour(t, h, uFull) != nil {
				t.Fatal("a wake that was not queued recorded the hour")
			}
			if path == outlookHookPath && wakeHour(t, h, uOpen) == nil {
				t.Fatal("the queued wake did not record the hour")
			}
			wk.take()
			wk.refuse("")
			wantStatus(t, h.graph(path, "", body), http.StatusAccepted)
			if ws := wk.take(); len(ws) != 2 {
				t.Fatalf("the retry woke %+v, want both holders", ws)
			}
		})
	}
}
