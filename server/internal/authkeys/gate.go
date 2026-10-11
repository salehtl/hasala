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
// Concurrency hashes run at once, at most Queue callers wait, and a caller
// waits at most Wait. Every limiter runs before it, so a refused request costs
// no PBKDF2. A nil *Gate runs the work ungated (tests).
type Gate struct {
	slots chan struct{}
	queue int
	wait  time.Duration

	mu      sync.Mutex
	waiting int
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
	return &Gate{slots: make(chan struct{}, concurrency), queue: queue, wait: wait}
}

// Do runs f inside a slot, or answers ErrGateBusy without running it.
func (g *Gate) Do(ctx context.Context, f func() error) error {
	if g == nil {
		return f()
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
		return f()
	default:
	}
	g.mu.Lock()
	if g.waiting >= g.queue {
		g.mu.Unlock()
		return ErrGateBusy
	}
	g.waiting++
	g.mu.Unlock()
	defer func() {
		g.mu.Lock()
		g.waiting--
		g.mu.Unlock()
	}()
	t := time.NewTimer(g.wait)
	defer t.Stop()
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
		return f()
	case <-t.C:
		return ErrGateBusy
	case <-ctx.Done():
		return ctx.Err()
	}
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
