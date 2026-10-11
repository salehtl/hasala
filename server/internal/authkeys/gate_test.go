package authkeys

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// AT-RL-7 (spec 02 §16.2): at most Concurrency hashes at once, at most Queue
// callers waiting, first in first out, each for at most Wait.

func TestGateRefusesACallerBeyondTheQueue(t *testing.T) {
	g := NewGate(1, 1, time.Second)
	release, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() {
		r, err := g.Acquire(context.Background())
		if err == nil {
			r()
		}
		waited <- err
	}()
	waitForWaiters(t, g, 1)
	ran := false
	if err := g.Do(context.Background(), func() error { ran = true; return nil }); !errors.Is(err, ErrGateBusy) || ran {
		t.Fatalf("a third caller with the queue full: %v (ran %v)", err, ran)
	}
	release()
	if err := <-waited; err != nil {
		t.Fatalf("the queued caller: %v", err)
	}
}

func TestGateWaitRunsOut(t *testing.T) {
	g := NewGate(1, 4, 20*time.Millisecond)
	release, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	start := time.Now()
	if err := g.Do(context.Background(), func() error { t.Error("ran without a slot"); return nil }); !errors.Is(err, ErrGateBusy) {
		t.Fatalf("after the wait: %v", err)
	}
	if time.Since(start) < 20*time.Millisecond {
		t.Fatal("refused before the wait ran out")
	}
	g.mu.Lock()
	n := len(g.waiters)
	g.mu.Unlock()
	if n != 0 {
		t.Fatalf("%d waiters left behind", n)
	}
}

func TestGateIsFirstInFirstOut(t *testing.T) {
	g := NewGate(1, 8, 5*time.Second)
	release, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var (
		mu    sync.Mutex
		order []int
		wg    sync.WaitGroup
	)
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_ = g.Do(context.Background(), func() error {
				mu.Lock()
				order = append(order, i)
				mu.Unlock()
				return nil
			})
		}(i)
		waitForWaiters(t, g, i+1) // queue them in a known order
	}
	release()
	wg.Wait()
	for i, v := range order {
		if v != i {
			t.Fatalf("served in order %v", order)
		}
	}
}

func TestGateDefaults(t *testing.T) {
	if DefaultGateQueue != 16 || DefaultGateWait != 2*time.Second {
		t.Fatal("spec 02 §16.2's queue is 16 and its wait 2 seconds")
	}
	g := NewGate(0, -1, 0)
	if g.free != 1 || g.queue != DefaultGateQueue || g.wait != DefaultGateWait {
		t.Fatalf("defaults: %d slots, queue %d, wait %v", g.free, g.queue, g.wait)
	}
	var nilGate *Gate
	if err := nilGate.Do(context.Background(), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func waitForWaiters(t *testing.T, g *Gate, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		g.mu.Lock()
		got := len(g.waiters)
		g.mu.Unlock()
		if got >= n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("never saw %d waiters", n)
}
