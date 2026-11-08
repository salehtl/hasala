package mailq

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type gateSender struct {
	entered chan struct{}
	release chan struct{}
	sent    atomic.Int32
}

func newGateSender() *gateSender {
	return &gateSender{entered: make(chan struct{}, 64), release: make(chan struct{})}
}

func (s *gateSender) Send(ctx context.Context, _ mail.Message) (string, error) {
	s.entered <- struct{}{}
	<-s.release
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.sent.Add(1)
	return "provider-id", nil
}

func (s *gateSender) awaitEntered(t *testing.T) {
	t.Helper()
	select {
	case <-s.entered:
	case <-time.After(30 * time.Second):
		t.Fatal("no worker reached the sender")
	}
}

func statusCounts(t *testing.T, q *Queue) map[string]int {
	t.Helper()
	counts := map[string]int{}
	rows, err := q.Pool.Query(bg, `SELECT status, count(*) FROM mail_log GROUP BY status`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var (
			status string
			n      int
		)
		if err := rows.Scan(&status, &n); err != nil {
			t.Fatal(err)
		}
		counts[status] = n
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return counts
}

func TestShutdownEndsADrainBetweenRowsAndFinishesTheRowsInFlight(t *testing.T) {
	pool := pgtest.New(t)
	sender := newGateSender()
	q := New(pool, sender, fixedTagger{})
	q.Register("test", TestRenderer)
	const backlog = 12
	for i := range backlog {
		enqueue(t, pool, q, Enqueue{Kind: "test", To: fmt.Sprintf("backlog%d@example.com", i)})
	}
	ctx, cancel := context.WithCancel(bg)
	defer cancel()
	done := q.Run(ctx)
	sender.awaitEntered(t)
	sender.awaitEntered(t)
	cancel()
	close(sender.release)
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		t.Fatal("the workers did not stop")
	}
	got := statusCounts(t, q)
	if got["sent"] != workerCount || got["queued"] != backlog-workerCount || got["sending"] != 0 {
		t.Fatalf("after shutdown: %v, want %d sent, %d queued, none sending", got, workerCount, backlog-workerCount)
	}
	restarted := New(pool, sender, fixedTagger{})
	restarted.Register("test", TestRenderer)
	if n, err := restarted.Drain(bg); err != nil || n != backlog-workerCount {
		t.Fatalf("drain after the restart: %d %v", n, err)
	}
	if got := statusCounts(t, q); got["sent"] != backlog {
		t.Fatalf("after the restart: %v", got)
	}
}
