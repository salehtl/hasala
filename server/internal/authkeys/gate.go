package authkeys

import (
	"context"
	"errors"
	"sync"
	"time"
)

// ErrGateBusy is the PBKDF2 gate refusing work: its queue is full or the wait
// ran out (spec 02 §16.2: 503 unavailable with Retry-After: 2).
var ErrGateBusy = errors.New("authkeys: the password hash gate is busy")

// Gate defaults (spec 02 §16.2).
const (
	DefaultGateQueue = 16
	DefaultGateWait  = 2 * time.Second
)

// Gate is the process-wide PBKDF2 semaphore of spec 02 §16.2: at most
// Concurrency hashes run at once, at most Queue callers wait, first in first
// out, and a caller waits at most Wait. Every limiter runs before it, so a
// refused request costs no PBKDF2. A nil *Gate runs the work ungated (tests).
type Gate struct {
	queue int
	wait  time.Duration

	mu      sync.Mutex
	free    int             // idle slots
	waiters []chan struct{} // FIFO; a slot is handed over by closing one
}

// NewGate builds a gate; concurrency < 1 is 1, queue < 0 is DefaultGateQueue
// and wait <= 0 is DefaultGateWait.
func NewGate(concurrency, queue int, wait time.Duration) *Gate {
	if concurrency < 1 {
		concurrency = 1
	}
	if queue < 0 {
		queue = DefaultGateQueue
	}
	if wait <= 0 {
		wait = DefaultGateWait
	}
	return &Gate{free: concurrency, queue: queue, wait: wait}
}

// Acquire takes a slot, waiting in line behind earlier callers, or answers
// ErrGateBusy (the line is full or the wait ran out) or the context's error.
// The caller runs release exactly once. On a nil *Gate it is a no-op.
func (g *Gate) Acquire(ctx context.Context) (release func(), err error) {
	if g == nil {
		return func() {}, nil
	}
	g.mu.Lock()
	if g.free > 0 && len(g.waiters) == 0 {
		g.free--
		g.mu.Unlock()
		return g.releaser(), nil
	}
	if len(g.waiters) >= g.queue {
		g.mu.Unlock()
		return nil, ErrGateBusy
	}
	ch := make(chan struct{})
	g.waiters = append(g.waiters, ch)
	g.mu.Unlock()

	t := time.NewTimer(g.wait)
	defer t.Stop()
	var why error
	select {
	case <-ch:
		return g.releaser(), nil
	case <-t.C:
		why = ErrGateBusy
	case <-ctx.Done():
		why = ctx.Err()
	}
	g.mu.Lock()
	for i, w := range g.waiters {
		if w == ch {
			g.waiters = append(g.waiters[:i], g.waiters[i+1:]...)
			g.mu.Unlock()
			return nil, why
		}
	}
	g.mu.Unlock()
	// The slot was handed over as the wait ended: pass it on.
	g.releaser()()
	return nil, why
}

// releaser hands a held slot to the longest waiter, or back to the pool.
func (g *Gate) releaser() func() {
	var once sync.Once
	return func() {
		once.Do(func() {
			g.mu.Lock()
			defer g.mu.Unlock()
			if len(g.waiters) > 0 {
				ch := g.waiters[0]
				g.waiters = g.waiters[1:]
				close(ch)
				return
			}
			g.free++
		})
	}
}

// Do runs f inside a slot, or answers ErrGateBusy without running it.
func (g *Gate) Do(ctx context.Context, f func() error) error {
	release, err := g.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	return f()
}

// HashGated is VerifierHash through the gate. Callers count it as the one
// PBKDF2 of the request.
func (k *Keys) HashGated(ctx context.Context, g *Gate, s, pwSalt []byte, generation int) ([]byte, error) {
	var out []byte
	err := g.Do(ctx, func() error {
		var err error
		out, err = k.VerifierHash(s, pwSalt, generation)
		return err
	})
	return out, err
}
