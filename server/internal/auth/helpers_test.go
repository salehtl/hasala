package auth

import (
	"context"
	"sync"
	"time"
)

// Shared test fixtures. They lived in idp_test.go until the Apple/Google
// exchange left this package (internal/googlejwt).

var bgctx = context.Background()

// clock is a settable, concurrency-safe test clock.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func newClock() *clock {
	return &clock{t: time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)}
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}
