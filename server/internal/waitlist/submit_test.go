package waitlist

import (
	"bytes"
	"context"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

var submitCtx = context.Background()

func submitRaw(pool *pgxpool.Pool, tag []byte, email string, bank, otherText, otherKey any) (string, error) {
	var out string
	err := pool.QueryRow(submitCtx, `SELECT waitlist_submit($1, $2, $3, $4, $5, $6, 'web')`,
		tag, email, mailq.Hint(email), bank, otherText, otherKey).Scan(&out)
	return out, err
}

func submit(t *testing.T, pool *pgxpool.Pool, tag []byte, email string, bank, otherText, otherKey any) string {
	t.Helper()
	out, err := submitRaw(pool, tag, email, bank, otherText, otherKey)
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	return out
}

func mustExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(submitCtx, sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func accountNotice(t *testing.T, pool *pgxpool.Pool, tag []byte, email string) {
	t.Helper()
	mustExec(t, pool, `INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, params, status,
		next_attempt_at, created_at) VALUES ('waitlist_has_account', 'waitlist', $1, $2, $3, '{}', 'queued', now(), now())`,
		email, tag, mailq.Hint(email))
}

func confirmations(t *testing.T, pool *pgxpool.Pool, tag []byte) (queued, suppressed, sentCount int) {
	t.Helper()
	if err := pool.QueryRow(submitCtx, `SELECT
		(SELECT count(*) FROM mail_log WHERE kind = 'waitlist' AND status = 'queued' AND recipient_tag = $1),
		(SELECT count(*) FROM mail_log WHERE kind = 'waitlist' AND status = 'suppressed' AND recipient_tag = $1),
		(SELECT confirm_sent_count FROM waitlist_entries WHERE email_tag = $1)`, tag).Scan(&queued, &suppressed, &sentCount); err != nil {
		t.Fatal(err)
	}
	return
}

func TestANewEntryGetsItsFirstConfirmationAfterAnAccountNotice(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{11}, 32)
	const email = "fresh@example.test"
	accountNotice(t, pool, tag, email)

	if got := submit(t, pool, tag, email, "fab", nil, nil); got != "new" {
		t.Fatalf("first submission after an account notice: %q, want new", got)
	}
	if q, s, n := confirmations(t, pool, tag); q != 1 || s != 0 || n != 1 {
		t.Fatalf("queued %d, suppressed %d, confirm_sent_count %d; want 1, 0, 1", q, s, n)
	}

	if got := submit(t, pool, tag, email, "fab", nil, nil); got != "pending_suppressed" {
		t.Fatalf("the next submission: %q, want pending_suppressed", got)
	}
	if q, s, n := confirmations(t, pool, tag); q != 1 || s != 1 || n != 1 {
		t.Fatalf("queued %d, suppressed %d, confirm_sent_count %d; want 1, 1, 1", q, s, n)
	}
}

func TestAResetEntryGetsItsFirstConfirmationAfterAnAccountNotice(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{12}, 32)
	const email = "back@example.test"
	mustExec(t, pool, `INSERT INTO waitlist_entries (email_tag, state, source, created_at, updated_at, confirmed_at,
		invited_at, joined_at) VALUES ($1, 'joined', 'web', now(), now(), now(), now(), now())`, tag)
	accountNotice(t, pool, tag, email)

	if got := submit(t, pool, tag, email, "fab", nil, nil); got != "reset" {
		t.Fatalf("submission after the account went: %q, want reset", got)
	}
	if q, s, n := confirmations(t, pool, tag); q != 1 || s != 0 || n != 1 {
		t.Fatalf("queued %d, suppressed %d, confirm_sent_count %d; want 1, 0, 1", q, s, n)
	}
}

func TestSimultaneousFirstSubmissionsQueueOneConfirmation(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{13}, 32)
	const email = "twice@example.test"
	const n = 6
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = submitRaw(pool, tag, email, "fab", nil, nil)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if q, _, sent := confirmations(t, pool, tag); q != 1 || sent != 1 {
		t.Fatalf("queued %d, confirm_sent_count %d; want 1 and 1", q, sent)
	}
}
