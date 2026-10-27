package waitlist

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

func TestBankSupportedEmailForBothAudiences(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	s := &Service{Pool: pool, WebBase: "https://hasala.example"}
	var user, entry uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
		VALUES (decode(md5('a') || md5('b'), 'hex'), now(), 'maya@example.test', now(), 'Maya Test') RETURNING id`).
		Scan(&user); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at,
		updated_at, confirmed_at) VALUES (decode(repeat('ab', 32), 'hex'), 'guest@example.test', 'confirmed', 'fab', 'web',
		now(), now(), now()) RETURNING id`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO bank_requests (bank_slug, source, user_id, created_at) VALUES ('fab', 'app', $1, now())`,
		user); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at)
		VALUES ('fab', 'web_waitlist', $1, now())`, entry); err != nil {
		t.Fatal(err)
	}
	render := func(row mailq.Row) (string, error) {
		var out string
		err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
			m, err := s.renderBankSupported(ctx, tx, row)
			out = m.Subject + "\n" + m.Text + "\n" + m.Unsubscribe
			return err
		})
		return out, err
	}
	slug := "fab"
	if _, err := render(mailq.Row{Recipient: "maya@example.test", UserID: &user, BankSlug: &slug}); !errors.Is(err, ErrStale) {
		t.Fatalf("before supported: %v", err)
	}
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		if _, err := banks.SetStatus(ctx, tx, "fab", "supported", "", time.Now()); err != nil {
			return err
		}
		n, err := banks.NotifySupported(ctx, tx, mailq.New(pool, nil, nil), "fab", time.Now())
		if n != 2 {
			t.Errorf("%d queued, want 2", n)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	acct, err := render(mailq.Row{Recipient: "maya@example.test", UserID: &user, BankSlug: &slug})
	if err != nil || !strings.HasPrefix(acct, "First Abu Dhabi Bank works with Hasala now\n") ||
		!strings.Contains(acct, "Hi Maya,") || !strings.Contains(acct, "Update Hasala in TestFlight") ||
		strings.Contains(acct, "Leave the list") || strings.Contains(acct, UnsubscribeURL) {
		t.Fatalf("account email %v:\n%s", err, acct)
	}
	wl, err := render(mailq.Row{Recipient: "guest@example.test", EntryID: &entry, BankSlug: &slug})
	if err != nil || !strings.Contains(wl, "still on the list") || !strings.Contains(wl, "https://hasala.example/waitlist/leave#") ||
		!strings.Contains(wl, UnsubscribeURL+"?token=") {
		t.Fatalf("waitlist email %v:\n%s", err, wl)
	}
	if _, err := render(mailq.Row{Recipient: "other@example.test", UserID: &user, BankSlug: &slug}); !errors.Is(err, ErrStale) {
		t.Fatalf("an address the account no longer has: %v", err)
	}
}
