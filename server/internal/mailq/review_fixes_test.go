package mailq

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestARowAtTheAttemptCapFailsAndDoesNotBlockTheQueue(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	var unsent []int64
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) error {
		unsent = append(unsent, r.ID)
		return nil
	}

	stuck := enqueue(t, pool, q, Enqueue{Kind: "test", To: "stuck@example.com"})
	leased := enqueue(t, pool, q, Enqueue{Kind: "test", To: "leased@example.com"})
	if _, err := pool.Exec(bg, `UPDATE mail_log SET attempts = $2 WHERE id = $1`, stuck, maxAttempts); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `UPDATE mail_log SET attempts = $2, status = 'sending', lease_until = now() - interval '1 minute',
	        next_attempt_at = NULL WHERE id = $1`, leased, maxAttempts); err != nil {
		t.Fatal(err)
	}
	next := enqueue(t, pool, q, Enqueue{Kind: "test", To: "next@example.com"})
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain %d %v", n, err)
	}
	for _, id := range []int64{stuck, leased} {
		if st, att, _, _ := row(t, pool, id); st != "failed" || att != maxAttempts {
			t.Fatalf("row %d at the cap: %s %d", id, st, att)
		}
	}
	if st, _, _, _ := row(t, pool, next); st != "sent" {
		t.Fatalf("the row behind the stuck ones: %s", st)
	}
	if len(unsent) != 2 {
		t.Fatalf("the unsent hook ran for %v", unsent)
	}
}

func TestAnAuthRefusalDoesNotSpendAnAttempt(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{Err: mail.ErrAuth}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "auth@example.com"})
	for i := 0; i < maxAttempts+2; i++ {
		_, _ = q.Drain(bg)
		q.stopped.Store(false)
	}
	if st, att, _, _ := row(t, pool, id); st != "queued" || att != 0 {
		t.Fatalf("after repeated auth refusals: %s %d", st, att)
	}
	fake.Err = nil
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain after the credentials work again: %d %v", n, err)
	}
	if st, _, _, _ := row(t, pool, id); st != "sent" {
		t.Fatalf("the row was not sent: %s", st)
	}
}

func TestATransientRenderErrorRetries(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, &mail.Fake{}, fixedTagger{})
	q.Register("test", RenderFunc(func(context.Context, pgx.Tx, Row) (mail.Message, error) {
		return mail.Message{}, context.DeadlineExceeded
	}))
	q.Register("deleted", RenderFunc(func(context.Context, pgx.Tx, Row) (mail.Message, error) {
		return mail.Message{}, errors.New("the row does not render")
	}))
	busy := enqueue(t, pool, q, Enqueue{Kind: "test", To: "busy@example.com"})
	broken := enqueue(t, pool, q, Enqueue{Kind: "deleted", To: "broken@example.com", Params: map[string]any{"deleted_at": "x"}})
	_, _ = q.Drain(bg)
	if st, att, _, e := row(t, pool, busy); st != "queued" || att != 1 || e == nil || *e != errRenderRetry.Error() {
		t.Fatalf("a render that timed out: %s %d %v", st, att, e)
	}
	var wait bool
	_ = pool.QueryRow(bg, `SELECT next_attempt_at > now() + interval '50 seconds' FROM mail_log WHERE id = $1`, busy).Scan(&wait)
	if !wait {
		t.Fatal("no backoff after a transient render error")
	}
	if st, _, _, _ := row(t, pool, broken); st != "failed" {
		t.Fatalf("a render that can never succeed: %s", st)
	}
}

func TestAHintFitsTheLogForAnyDomain(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, &mail.Fake{}, fixedTagger{})
	q.Register("test", TestRenderer)
	domain := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + ".example.com"
	addr := "maya@" + domain
	h := Hint(addr)
	if n := utf8.RuneCountInString(h); n > hintMax || !strings.HasPrefix(h, "m•••@…") || !strings.HasSuffix(h, ".example.com") {
		t.Fatalf("Hint(%q) = %q (%d characters)", addr, h, n)
	}
	enqueue(t, pool, q, Enqueue{Kind: "test", To: addr})
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain %d %v", n, err)
	}
	if got := Hint("ñandu@example.com"); got != "ñ•••@example.com" || !utf8.ValidString(got) {
		t.Fatalf("a hint of a non-ASCII local part: %q", got)
	}
}
