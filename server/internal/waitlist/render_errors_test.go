package waitlist

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

const (
	renderRetrying = "mailq: render failed; retrying"
	renderRefused  = "mail: refused permanently: render"
)

type renderTagger struct{}

func (renderTagger) EmailTag(s string) []byte {
	b := bytes.Repeat([]byte{7}, 32)
	copy(b, s)
	return b
}

func entryInState(t *testing.T, pool *pgxpool.Pool, state string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(context.Background(), `INSERT INTO waitlist_entries (email_tag, email_norm, state, source,
		created_at, updated_at, confirmed_at) VALUES ($1, 'guest@example.test', $2::text, 'web', now(), now(),
		CASE WHEN $2::text = 'confirmed' THEN now() END) RETURNING id`,
		bytes.Repeat([]byte{9}, 32), state).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func accountForRender(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(context.Background(), `INSERT INTO users (user_handle, created_at, email_norm,
		email_verified_at, display_name) VALUES (decode(md5('r') || md5('s'), 'hex'), now(), 'maya@example.test', now(),
		'Maya Test') RETURNING id`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func markBankSupported(t *testing.T, pool *pgxpool.Pool) *string {
	t.Helper()
	if _, err := pool.Exec(context.Background(), `UPDATE banks SET status = 'supported' WHERE slug = 'fab'`); err != nil {
		t.Fatal(err)
	}
	slug := "fab"
	return &slug
}

func queueEmail(t *testing.T, pool *pgxpool.Pool, q *mailq.Queue, e mailq.Enqueue) int64 {
	t.Helper()
	var id int64
	if err := pgx.BeginFunc(context.Background(), pool, func(tx pgx.Tx) error {
		var err error
		id, err = q.EnqueueTx(context.Background(), tx, e)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return id
}

func emailOutcome(t *testing.T, pool *pgxpool.Pool, id int64) (status, text string) {
	t.Helper()
	var e *string
	if err := pool.QueryRow(context.Background(), `SELECT status, error FROM mail_log WHERE id = $1`, id).
		Scan(&status, &e); err != nil {
		t.Fatal(err)
	}
	if e != nil {
		text = *e
	}
	return status, text
}

func TestAnEntryReadThatTimesOutRetriesInsteadOfClosingTheEmail(t *testing.T) {
	for _, c := range []struct {
		kind, state string
		bank        bool
	}{
		{kind: "waitlist", state: "pending"},
		{kind: "waitlist_already", state: "confirmed"},
		{kind: "bank_supported", state: "confirmed", bank: true},
	} {
		t.Run(c.kind, func(t *testing.T) {
			ctx := context.Background()
			pool := pgtest.New(t)
			cfg := pool.Config()
			cfg.ConnConfig.RuntimeParams["statement_timeout"] = "500ms"
			short, err := pgxpool.NewWithConfig(ctx, cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer short.Close()
			fake := &mail.Fake{}
			q := mailq.New(short, fake, renderTagger{})
			(&Service{Pool: short, WebBase: "https://hasala.example"}).Register(q)
			entry := entryInState(t, pool, c.state)
			e := mailq.Enqueue{Kind: c.kind, To: "guest@example.test", EntryID: &entry}
			if c.bank {
				e.BankSlug = markBankSupported(t, pool)
			}
			id := queueEmail(t, pool, q, e)
			hold, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = hold.Rollback(ctx) }()
			if _, err := hold.Exec(ctx, `SELECT 1 FROM waitlist_entries WHERE id = $1 FOR UPDATE`, entry); err != nil {
				t.Fatal(err)
			}
			if _, err := q.Drain(ctx); err != nil {
				t.Fatal(err)
			}
			if st, text := emailOutcome(t, pool, id); st != "queued" || text != renderRetrying {
				t.Fatalf("while the entry could not be read: status %s, error %q", st, text)
			}
			if err := hold.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(ctx, `UPDATE mail_log SET next_attempt_at = now() WHERE id = $1`, id); err != nil {
				t.Fatal(err)
			}
			if _, err := q.Drain(ctx); err != nil {
				t.Fatal(err)
			}
			if st, text := emailOutcome(t, pool, id); st != "sent" || len(fake.Sent()) != 1 {
				t.Fatalf("after the entry could be read: status %s, error %q, sent %d", st, text, len(fake.Sent()))
			}
		})
	}
}

func TestABankOrAccountReadThatFailsIsNotLoggedAsNoLongerNeeded(t *testing.T) {
	for _, c := range []struct{ name, change string }{
		{"bank", `ALTER TABLE banks RENAME COLUMN status TO status_gone`},
		{"account", `ALTER TABLE users RENAME COLUMN display_name TO display_name_gone`},
	} {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			pool, owner := pgtest.NewWithOwner(t)
			fake := &mail.Fake{}
			q := mailq.New(pool, fake, renderTagger{})
			(&Service{Pool: pool, WebBase: "https://hasala.example"}).Register(q)
			user := accountForRender(t, pool)
			id := queueEmail(t, pool, q, mailq.Enqueue{Kind: "bank_supported", To: "maya@example.test", UserID: &user,
				BankSlug: markBankSupported(t, pool)})
			if _, err := owner.Exec(ctx, c.change); err != nil {
				t.Fatal(err)
			}
			if _, err := q.Drain(ctx); err != nil {
				t.Fatal(err)
			}
			if st, text := emailOutcome(t, pool, id); st != "failed" || text != renderRefused {
				t.Fatalf("status %s, error %q", st, text)
			}
			if len(fake.Sent()) != 0 {
				t.Fatalf("sent %d", len(fake.Sent()))
			}
		})
	}
}

func TestACancelledBankReadKeepsItsError(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	s := &Service{Pool: pool, WebBase: "https://hasala.example"}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	slug := "fab"
	_, err = s.renderBankSupported(cancelled, tx, mailq.Row{Recipient: "guest@example.test", BankSlug: &slug})
	if errors.Is(err, ErrStale) || !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestAnEmailWhoseSubjectIsGoneOrMovedOnIsStillNoLongerNeeded(t *testing.T) {
	for _, c := range []struct {
		kind, state string
		bank        bool
	}{
		{kind: "waitlist", state: "confirmed"},
		{kind: "waitlist_already", state: "pending"},
		{kind: "bank_supported", state: "pending", bank: true},
	} {
		t.Run(c.kind, func(t *testing.T) {
			ctx := context.Background()
			pool := pgtest.New(t)
			fake := &mail.Fake{}
			q := mailq.New(pool, fake, renderTagger{})
			(&Service{Pool: pool, WebBase: "https://hasala.example"}).Register(q)
			entry := entryInState(t, pool, c.state)
			e := mailq.Enqueue{Kind: c.kind, To: "guest@example.test", EntryID: &entry}
			if c.bank {
				e.BankSlug = markBankSupported(t, pool)
			}
			id := queueEmail(t, pool, q, e)
			if _, err := q.Drain(ctx); err != nil {
				t.Fatal(err)
			}
			if st, text := emailOutcome(t, pool, id); st != "failed" || text != ErrStale.Error() {
				t.Fatalf("status %s, error %q", st, text)
			}
			if len(fake.Sent()) != 0 {
				t.Fatalf("sent %d", len(fake.Sent()))
			}
		})
	}

	ctx := context.Background()
	pool := pgtest.New(t)
	s := &Service{Pool: pool, WebBase: "https://hasala.example"}
	missingEntry, missingUser := uuid.New(), uuid.New()
	fab, unknown := "fab", "no-such-bank"
	markBankSupported(t, pool)
	for name, row := range map[string]mailq.Row{
		"entry":   {Recipient: "guest@example.test", EntryID: &missingEntry, BankSlug: &fab},
		"account": {Recipient: "guest@example.test", UserID: &missingUser, BankSlug: &fab},
		"bank":    {Recipient: "guest@example.test", BankSlug: &unknown},
	} {
		err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
			_, err := s.renderBankSupported(ctx, tx, row)
			return err
		})
		if !errors.Is(err, ErrStale) {
			t.Fatalf("a missing %s: %v", name, err)
		}
	}
}
