package mailq

import (
	"context"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func stoppedSendNow(t *testing.T, q *Queue, e Enqueue) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = q.SendNow(bg, e, func() (mail.Message, error) {
			runtime.Goexit()
			return mail.Message{}, nil
		})
	}()
	<-done
}

func TestASendNowRowInterruptedByAStopIsNeverSentAgain(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	var rendered atomic.Int32
	q.Register("code", RenderFunc(func(context.Context, pgx.Tx, Row) (mail.Message, error) {
		rendered.Add(1)
		return mail.Message{Subject: "s", Text: "a second code"}, nil
	}))

	stoppedSendNow(t, q, Enqueue{Kind: "code", To: "stopped@example.com", Params: map[string]any{"purpose": "email_verify"}})
	var id int64
	var st string
	if err := pool.QueryRow(bg, `SELECT id, status FROM mail_log`).Scan(&id, &st); err != nil {
		t.Fatal(err)
	}
	if st != "sending" {
		t.Fatalf("the interrupted row is %s, want sending", st)
	}

	if n, err := q.Drain(bg); err != nil || n != 0 {
		t.Fatalf("drain with a live lease: %d %v", n, err)
	}
	if st, _, _, _ := row(t, pool, id); st != "sending" {
		t.Fatalf("a row with a live lease moved to %s", st)
	}

	if _, err := pool.Exec(bg, `UPDATE mail_log SET lease_until = now() - interval '1 minute' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if n, err := q.Drain(bg); err != nil || n != 0 {
		t.Fatalf("drain after the lease ended: %d %v", n, err)
	}
	st, att, _, e := row(t, pool, id)
	if st != "failed" || att != 1 || e == nil || !strings.Contains(*e, "interrupted") {
		t.Fatalf("the interrupted row: %s attempts %d error %v, want failed after one attempt", st, att, e)
	}
	if rendered.Load() != 0 || len(fake.Sent()) != 0 {
		t.Fatalf("the interrupted row was rendered %d times and sent %d times", rendered.Load(), len(fake.Sent()))
	}
}

func TestAQueuedRowWithAnExpiredLeaseStillRetries(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "leased@example.com"})
	if _, err := pool.Exec(bg, `UPDATE mail_log SET attempts = 1, status = 'sending', lease_until = now() - interval '1 minute',
	        next_attempt_at = NULL WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain: %d %v", n, err)
	}
	if st, att, _, _ := row(t, pool, id); st != "sent" || att != 2 || len(fake.Sent()) != 1 {
		t.Fatalf("a queued row after its lease ended: %s attempts %d, sent %d", st, att, len(fake.Sent()))
	}
}
