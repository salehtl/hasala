package api

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type scriptedSender struct {
	mu     sync.Mutex
	result pushv2.Result
	sends  int
	seen   chan struct{}
}

func (s *scriptedSender) Send(context.Context, pushv2.Target) pushv2.Result {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sends++
	s.seen <- struct{}{}
	return s.result
}

func (s *scriptedSender) set(r pushv2.Result) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.result = r
}

func (s *scriptedSender) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sends
}

type nudgeRig struct {
	t      *testing.T
	h      *harness
	sender *scriptedSender
	d      *pushv2.Dispatcher
	user   uuid.UUID
	ahead  atomic.Int64
}

func newNudgeRig(t *testing.T, name, holder string, withToken bool) *nudgeRig {
	t.Helper()
	h := newHarness(t)
	_, g := withPushAndGmail(h)
	u := h.user(name)
	h.writer(u, holder)
	if _, err := h.pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		watch_expires_at, created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, now() + interval '30 hours', now(), now())`,
		u, g.RouteKey.AddressHMAC(name+"@gmail.com"), g.RouteKey.KeyID(), holder); err != nil {
		t.Fatal(err)
	}
	if withToken {
		h.apnsToken(u, holder, h.session(u))
	}
	s := &scriptedSender{result: pushv2.ResultSent, seen: make(chan struct{}, 16)}
	r := &nudgeRig{t: t, h: h, sender: s, user: u}
	r.newDispatcher()
	return r
}

func (r *nudgeRig) newDispatcher() {
	r.d = pushv2.NewDispatcher(r.h.pool, r.sender)
	r.d.Now = func() time.Time { return time.Now().Add(time.Duration(r.ahead.Load())) }
}

func (r *nudgeRig) start() {
	r.t.Helper()
	ctx, cancel := context.WithCancel(bg)
	done := r.d.Start(ctx)
	r.t.Cleanup(func() { cancel(); <-done })
}

func (r *nudgeRig) sweep() string {
	r.t.Helper()
	msg, err := gmailpush.Nudge(bg, r.h.pool, r.d, gmailpush.ProviderGmail)
	if err != nil {
		r.t.Fatalf("nudge: %v", err)
	}
	return msg
}

func (r *nudgeRig) waitForSend() {
	r.t.Helper()
	select {
	case <-r.sender.seen:
	case <-time.After(10 * time.Second):
		r.t.Fatal("no wake reached the sender")
	}
}

func (r *nudgeRig) markAgeMinutes() float64 {
	r.t.Helper()
	var age float64
	if err := r.h.pool.QueryRow(bg, `SELECT extract(epoch FROM now() - last_nudge_at) / 60 FROM mailbox_links WHERE user_id = $1`,
		r.user).Scan(&age); err != nil {
		r.t.Fatal(err)
	}
	return age
}

func (r *nudgeRig) nextRun() {
	r.t.Helper()
	r.ahead.Add(int64(15 * time.Minute))
	if _, err := r.h.pool.Exec(bg, `UPDATE mailbox_links SET last_nudge_at = last_nudge_at - interval '15 minutes' WHERE user_id = $1`,
		r.user); err != nil {
		r.t.Fatal(err)
	}
}

func (r *nudgeRig) waitForMarkYoungerThanAMinute() {
	r.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for r.markAgeMinutes() >= 1 {
		if time.Now().After(deadline) {
			r.t.Fatalf("a wake that went out left the mark %.0f minutes old", r.markAgeMinutes())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNudgeThatAPNsDidNotTakeIsTriedAgainOnTheNextRun(t *testing.T) {
	for name, result := range map[string]pushv2.Result{
		"transient": pushv2.ResultTransient,
		"cooldown":  pushv2.ResultCooldown,
	} {
		t.Run(name, func(t *testing.T) {
			r := newNudgeRig(t, "undelivered-"+name, "ios-71111111-1111-4111-8111-111111111111", true)
			r.sender.set(result)
			r.start()
			if r.sweep() == "" {
				t.Fatal("the first run nudged nobody")
			}
			r.waitForSend()
			if msg := r.sweep(); msg != "" {
				t.Fatalf("the same run's mark did not hold off an immediate second sweep: %q", msg)
			}
			r.nextRun()
			r.sender.set(pushv2.ResultSent)
			if r.sweep() == "" {
				t.Fatal("a nudge APNs did not take was not tried again on the next run")
			}
			r.waitForSend()
			r.waitForMarkYoungerThanAMinute()
			r.nextRun()
			if msg := r.sweep(); msg != "" {
				t.Fatalf("a nudge that went out did not hold for 12 hours: %q", msg)
			}
			if n := r.sender.count(); n != 2 {
				t.Fatalf("%d sends, want the failed one and the retry", n)
			}
		})
	}
}

func TestNudgeForAHolderWithNoTokenIsTriedAgainOnTheNextRun(t *testing.T) {
	r := newNudgeRig(t, "no-token", "ios-72222222-2222-4222-8222-222222222222", false)
	r.start()
	if r.sweep() == "" {
		t.Fatal("the first run nudged nobody")
	}
	r.nextRun()
	if r.sweep() == "" {
		t.Fatal("a nudge with no device to wake silenced the next run")
	}
}

func TestNudgeLeftInTheQueueAtAStopIsTriedAgainAfterARestart(t *testing.T) {
	r := newNudgeRig(t, "stopped", "ios-73333333-3333-4333-8333-333333333333", true)
	if r.sweep() == "" {
		t.Fatal("the first run nudged nobody")
	}
	if n := r.sender.count(); n != 0 {
		t.Fatalf("%d sends from a dispatcher that never started", n)
	}
	r.newDispatcher()
	r.start()
	r.nextRun()
	if r.sweep() == "" {
		t.Fatal("a nudge abandoned in the queue silenced the run after a restart")
	}
	r.waitForSend()
	r.waitForMarkYoungerThanAMinute()
}
