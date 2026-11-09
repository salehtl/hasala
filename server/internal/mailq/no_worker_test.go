package mailq

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMailNoWorkerWillSendFailsOnce(t *testing.T) {
	pool := pgtest.New(t)
	enqueuer := New(pool, nil, nil)
	untagged := enqueue(t, pool, enqueuer, Enqueue{Kind: "test", To: "later@example.com"})
	tagged := enqueue(t, pool, enqueuer, Enqueue{Kind: "test", To: "tagged@example.com", Tag: fixedTagger{}.EmailTag("tagged@example.com")})
	goodbye := enqueue(t, pool, enqueuer, Enqueue{Kind: "deleted", To: "gone@example.com", Params: map[string]any{"deleted_at": "x"}})
	expired := enqueue(t, pool, enqueuer, Enqueue{Kind: "test", To: "expired@example.com"})
	live := enqueue(t, pool, enqueuer, Enqueue{Kind: "test", To: "live@example.com"})
	sent := enqueue(t, pool, enqueuer, Enqueue{Kind: "test", To: "sent@example.com"})
	for _, u := range []struct {
		id  int64
		sql string
	}{
		{expired, `UPDATE mail_log SET status = 'sending', next_attempt_at = NULL, lease_until = now() - interval '1 minute' WHERE id = $1`},
		{live, `UPDATE mail_log SET status = 'sending', next_attempt_at = NULL, lease_until = now() + interval '1 minute' WHERE id = $1`},
		{sent, `UPDATE mail_log SET status = 'sent', next_attempt_at = NULL, sent_at = now(), final_at = now() WHERE id = $1`},
	} {
		if _, err := pool.Exec(bg, u.sql, u.id); err != nil {
			t.Fatal(err)
		}
	}
	var unsent []int64
	q := New(pool, mail.Unconfigured{}, nil)
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
		unsent = append(unsent, r.ID)
		return nil, nil
	}
	msg, err := q.FailWithoutWorker(bg)
	if err != nil || !strings.Contains(msg, "4") {
		t.Fatalf("first pass: %q %v", msg, err)
	}
	for _, id := range []int64{untagged, tagged, goodbye, expired} {
		st, att, _, e := row(t, pool, id)
		if st != "failed" || att != 0 || e == nil || !strings.Contains(*e, "not configured") {
			t.Fatalf("row %d: %s attempts %d error %v", id, st, att, e)
		}
	}
	if _, _, rcpt, _ := row(t, pool, goodbye); rcpt != nil {
		t.Fatal("the goodbye kept its address")
	}
	if _, _, rcpt, _ := row(t, pool, untagged); rcpt == nil {
		t.Fatal("an ordinary row lost its address")
	}
	if st, _, _, _ := row(t, pool, live); st != "sending" {
		t.Fatalf("a row under a live lease: %s", st)
	}
	if st, _, _, _ := row(t, pool, sent); st != "sent" {
		t.Fatalf("a sent row: %s", st)
	}
	slices.Sort(unsent)
	if !slices.Equal(unsent, []int64{untagged, tagged, goodbye, expired}) {
		t.Fatalf("unsent hook ran for %v", unsent)
	}
	msg, err = q.FailWithoutWorker(bg)
	if err != nil || msg != "" || len(unsent) != 4 {
		t.Fatalf("second pass: %q %v, hook ran %d times", msg, err, len(unsent))
	}
}

func TestAQueueWithAWorkerKeepsItsMail(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, &mail.Fake{}, fixedTagger{})
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "waiting@example.com"})
	if msg, err := q.FailWithoutWorker(bg); err != nil || msg != "" {
		t.Fatalf("%q %v", msg, err)
	}
	if st, _, _, _ := row(t, pool, id); st != "queued" {
		t.Fatalf("row %s", st)
	}
}

func TestFailingMailWithoutAWorkerRetriesAfterAnError(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, nil, nil)
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "later@example.com"})
	refused := errors.New("no database")
	q.Unsent = func(context.Context, pgx.Tx, Row) (func(), error) { return nil, refused }
	if _, err := q.FailWithoutWorker(bg); !errors.Is(err, refused) {
		t.Fatalf("err %v", err)
	}
	if st, _, _, _ := row(t, pool, id); st != "queued" {
		t.Fatalf("after the error: %s", st)
	}
	q.Unsent = nil
	if _, err := q.FailWithoutWorker(bg); err != nil {
		t.Fatal(err)
	}
	if st, _, _, _ := row(t, pool, id); st != "failed" {
		t.Fatalf("on the next pass: %s", st)
	}
}

func TestConcurrentPassesFailEachRowOnce(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, nil, nil)
	const rows = 8
	for range rows {
		enqueue(t, pool, q, Enqueue{Kind: "test", To: "later@example.com"})
	}
	var (
		mu    sync.Mutex
		hooks int
		dones int
	)
	q.Unsent = func(context.Context, pgx.Tx, Row) (func(), error) {
		mu.Lock()
		defer mu.Unlock()
		hooks++
		return func() {
			mu.Lock()
			defer mu.Unlock()
			dones++
		}, nil
	}
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := q.FailWithoutWorker(bg)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if hooks != rows || dones != rows {
		t.Fatalf("hook ran %d times, its follow-up %d, want %d", hooks, dones, rows)
	}
	var left int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE status <> 'failed'`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatalf("%d rows not failed", left)
	}
}
