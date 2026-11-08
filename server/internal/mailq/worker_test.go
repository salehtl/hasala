package mailq

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

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

func TestAHaltedQueueStillSettlesExpiredLeasesAndSendsNothing(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{Err: mail.ErrAuth}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	var unsent []int64
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
		unsent = append(unsent, r.ID)
		return nil, nil
	}
	enqueue(t, pool, q, Enqueue{Kind: "test", To: "halts@example.com"})
	if _, err := q.Drain(bg); err != nil || !q.Stopped() {
		t.Fatalf("drain %v, stopped %v", err, q.Stopped())
	}
	lease := func(to string, attempts int, oneShot bool) int64 {
		t.Helper()
		id := enqueue(t, pool, q, Enqueue{Kind: "test", To: to})
		if _, err := pool.Exec(bg, `UPDATE mail_log SET status = 'sending', next_attempt_at = NULL, attempts = $2, one_shot = $3,
			lease_until = now() - interval '1 minute' WHERE id = $1`, id, attempts, oneShot); err != nil {
			t.Fatal(err)
		}
		return id
	}
	retry := lease("retry@example.com", 1, false)
	oneShot := lease("oneshot@example.com", 1, true)
	exhausted := lease("exhausted@example.com", maxAttempts, false)
	fake.Err = nil
	if n, err := q.Drain(bg); err != nil || n != 0 {
		t.Fatalf("drain while halted: %d %v", n, err)
	}
	if st, att, _, _ := row(t, pool, retry); st != "queued" || att != 1 {
		t.Fatalf("the expired lease: %s %d", st, att)
	}
	for _, id := range []int64{oneShot, exhausted} {
		if st, _, _, _ := row(t, pool, id); st != "failed" {
			t.Fatalf("row %d: %s", id, st)
		}
		if hookDue(t, q, id) {
			t.Fatalf("row %d still owes its hook", id)
		}
	}
	if len(unsent) != 2 {
		t.Fatalf("the unsent hook ran for %v", unsent)
	}
	if len(fake.Sent()) != 0 || !q.Stopped() {
		t.Fatalf("sent %d, stopped %v", len(fake.Sent()), q.Stopped())
	}
}
