package waitlist

import (
	"bytes"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type resetFixture struct {
	pool  *pgxpool.Pool
	svc   *Service
	tag   []byte
	email string
}

func newResetFixture(t *testing.T, seed byte, email string) resetFixture {
	t.Helper()
	pool := pgtest.New(t)
	return resetFixture{pool: pool, svc: New(pool, nil, "https://web.example.test"),
		tag: bytes.Repeat([]byte{seed}, 32), email: email}
}

func (f resetFixture) entry(t *testing.T) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := f.pool.QueryRow(submitCtx, `SELECT id FROM waitlist_entries WHERE email_tag = $1`, f.tag).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (f resetFixture) state(t *testing.T) string {
	t.Helper()
	var s string
	if err := f.pool.QueryRow(submitCtx, `SELECT state FROM waitlist_entries WHERE email_tag = $1`, f.tag).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func (f resetFixture) mint(t *testing.T, purpose string) string {
	t.Helper()
	var link string
	if err := pgx.BeginFunc(submitCtx, f.pool, func(tx pgx.Tx) (err error) {
		link, err = MintToken(submitCtx, tx, f.entry(t), purpose)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return link
}

func (f resetFixture) join(t *testing.T) {
	t.Helper()
	if err := pgx.BeginFunc(submitCtx, f.pool, func(tx pgx.Tx) error {
		return OnInviteRedeemedTx(submitCtx, tx, uuid.New(), uuid.New(), f.tag)
	}); err != nil {
		t.Fatal(err)
	}
	if got := f.state(t); got != "joined" {
		t.Fatalf("entry %s, want joined", got)
	}
}

func (f resetFixture) reset(t *testing.T) {
	t.Helper()
	if got := submit(t, f.pool, f.tag, f.email, "enbd", nil, nil); got != "reset" {
		t.Fatalf("submission after the account went: %q, want reset", got)
	}
}

func TestAUsedConfirmLinkDoesNotConfirmAResetEntry(t *testing.T) {
	f := newResetFixture(t, 31, "used@example.test")
	submit(t, f.pool, f.tag, f.email, "enbd", nil, nil)
	link := f.mint(t, "confirm")
	if got, err := f.svc.Confirm(submitCtx, link); err != nil || got != "confirmed" {
		t.Fatalf("first confirm: %q, %v", got, err)
	}
	if got, err := f.svc.Confirm(submitCtx, link); err != nil || got != "already_confirmed" {
		t.Fatalf("reopening the link: %q, %v; want already_confirmed", got, err)
	}
	f.join(t)
	f.reset(t)

	if got, err := f.svc.Confirm(submitCtx, link); !errors.Is(err, ErrLinkExpired) {
		t.Fatalf("the used link after a reset: %q, %v; want ErrLinkExpired", got, err)
	}
	if got := f.state(t); got != "pending" {
		t.Fatalf("entry %s, want pending", got)
	}

	fresh := f.mint(t, "confirm")
	if got, err := f.svc.Confirm(submitCtx, fresh); err != nil || got != "confirmed" {
		t.Fatalf("a link sent after the reset: %q, %v", got, err)
	}
}

func TestAnUnusedConfirmLinkDoesNotConfirmAResetEntry(t *testing.T) {
	f := newResetFixture(t, 32, "unused@example.test")
	submit(t, f.pool, f.tag, f.email, "enbd", nil, nil)
	link := f.mint(t, "confirm")
	f.join(t)
	f.reset(t)

	if got, err := f.svc.Confirm(submitCtx, link); !errors.Is(err, ErrLinkExpired) {
		t.Fatalf("the old link after a reset: %q, %v; want ErrLinkExpired", got, err)
	}
	if got := f.state(t); got != "pending" {
		t.Fatalf("entry %s, want pending", got)
	}
}

func TestALeaveLinkStillWorksAfterAReset(t *testing.T) {
	f := newResetFixture(t, 33, "leaves@example.test")
	submit(t, f.pool, f.tag, f.email, "enbd", nil, nil)
	link := f.mint(t, "leave")
	f.join(t)
	f.reset(t)

	if err := f.svc.Leave(submitCtx, link); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := f.pool.QueryRow(submitCtx, `SELECT count(*) FROM waitlist_entries WHERE email_tag = $1`, f.tag).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatalf("%d entries after leaving, want 0", left)
	}
}

func TestAConfirmWaitingOnAResetDoesNotConfirmTheFreshEntry(t *testing.T) {
	f := newResetFixture(t, 34, "race@example.test")
	submit(t, f.pool, f.tag, f.email, "enbd", nil, nil)
	f.join(t)
	link := f.mint(t, "confirm")

	tx, err := f.pool.Begin(submitCtx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(submitCtx)
	var outcome string
	if err := tx.QueryRow(submitCtx, `SELECT waitlist_submit($1, $2, $3, 'enbd', NULL, NULL, 'web')`,
		f.tag, f.email, mailq.Hint(f.email)).Scan(&outcome); err != nil || outcome != "reset" {
		t.Fatalf("reset: %q, %v", outcome, err)
	}

	type result struct {
		out string
		err error
	}
	done := make(chan result, 1)
	go func() {
		out, err := f.svc.Confirm(submitCtx, link)
		done <- result{out, err}
	}()

	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting int
		if err := f.pool.QueryRow(submitCtx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%waitlist_tokens t JOIN%'`).
			Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the confirm never waited on the entry")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := tx.Commit(submitCtx); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if !errors.Is(r.err, ErrLinkExpired) {
			t.Fatalf("confirm during the reset: %q, %v; want ErrLinkExpired", r.out, r.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the confirm did not finish")
	}
	if got := f.state(t); got != "pending" {
		t.Fatalf("entry %s, want pending", got)
	}
}
