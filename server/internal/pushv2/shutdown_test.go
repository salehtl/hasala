package pushv2

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func waitDone(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the dispatcher did not stop")
	}
}

func TestShutdownSendsWhatWasQueued(t *testing.T) {
	s := &fakeSender{block: make(chan struct{})}
	d := NewDispatcher(nil, s)
	ctx, cancel := context.WithCancel(bg)
	defer cancel()
	done := d.Start(ctx)
	const queued = 64
	for i := range queued {
		d.WakeTokens(bg, []Target{fixedTarget(byte(i))}, ReasonSecurity)
	}
	cancel()
	close(s.block)
	waitDone(t, done)
	if s.count() != queued {
		t.Fatalf("%d of %d queued wakes sent", s.count(), queued)
	}
	if n := d.Stats.Dropped[ReasonSecurity].Load(); n != 0 {
		t.Fatalf("%d queued wakes dropped", n)
	}
}

func TestShutdownRunsAConfirmationForAQueuedWake(t *testing.T) {
	d := NewDispatcher(nil, &fakeSender{})
	ctx, cancel := context.WithCancel(bg)
	cancel()
	var confirmed atomic.Int64
	for i := range 8 {
		if !d.enqueue(job{tokens: []Target{fixedTarget(byte(i))}, r: ReasonSecurity, sent: func() { confirmed.Add(1) }}) {
			t.Fatal("not queued")
		}
	}
	waitDone(t, d.Start(ctx))
	if confirmed.Load() != 8 {
		t.Fatalf("%d of 8 confirmations", confirmed.Load())
	}
}

func TestAWakeAfterShutdownIsRefused(t *testing.T) {
	s := &fakeSender{}
	d := NewDispatcher(nil, s)
	ctx, cancel := context.WithCancel(bg)
	done := d.Start(ctx)
	cancel()
	waitDone(t, done)
	if d.TryWakeWriter(bg, uuid.New(), "w", ReasonNudge) {
		t.Fatal("a wake after shutdown was reported queued")
	}
	if len(d.queue) != 0 {
		t.Fatal("a wake after shutdown waits in a queue nobody reads")
	}
	if n := d.Stats.Dropped[ReasonNudge].Load(); n != 1 {
		t.Fatalf("dropped %d, want 1", n)
	}
}

type hangingSender struct{ sends atomic.Int64 }

func (h *hangingSender) Send(ctx context.Context, _ Target) Result {
	h.sends.Add(1)
	<-ctx.Done()
	return ResultTransient
}

func TestShutdownStopsSendingAtItsLimit(t *testing.T) {
	h := &hangingSender{}
	d := NewDispatcher(nil, h)
	d.drainFor = 50 * time.Millisecond
	const queued = 40
	for i := range queued {
		d.WakeTokens(bg, []Target{fixedTarget(byte(i))}, ReasonSecurity)
	}
	ctx, cancel := context.WithCancel(bg)
	done := d.Start(ctx)
	cancel()
	waitDone(t, done)
	dropped := d.Stats.Dropped[ReasonSecurity].Load()
	if dropped == 0 || h.sends.Load()+dropped != queued {
		t.Fatalf("%d sends and %d dropped of %d queued", h.sends.Load(), dropped, queued)
	}
	if len(d.queue) != 0 {
		t.Fatalf("%d wakes left behind", len(d.queue))
	}
}
