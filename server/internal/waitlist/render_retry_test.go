package waitlist

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type retryTagger struct{}

func (retryTagger) EmailTag(s string) []byte {
	b := bytes.Repeat([]byte{9}, 32)
	copy(b, s)
	return b
}

type retryRig struct {
	pool *pgxpool.Pool
	fake *mail.Fake
	q    *mailq.Queue
}

func newRetryRig(t *testing.T) *retryRig {
	t.Helper()
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mailq.New(pool, fake, retryTagger{})
	New(pool, retryTagger{}, "https://hasala.example").Register(q)
	return &retryRig{pool: pool, fake: fake, q: q}
}

func (r *retryRig) entry(t *testing.T, addr, state string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := r.pool.QueryRow(context.Background(),
		`INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at, updated_at, confirmed_at)
		 VALUES ($1, $2, $3, 'fab', 'web', now(), now(), CASE WHEN $3 = 'pending' THEN NULL ELSE now() END) RETURNING id`,
		retryTagger{}.EmailTag(addr), addr, state).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (r *retryRig) enqueue(t *testing.T, e mailq.Enqueue) int64 {
	t.Helper()
	var id int64
	if err := pgx.BeginFunc(context.Background(), r.pool, func(tx pgx.Tx) error {
		var err error
		id, err = r.q.EnqueueTx(context.Background(), tx, e)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return id
}

func (r *retryRig) hold(t *testing.T, sql string, args ...any) pgx.Tx {
	t.Helper()
	tx, err := r.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	if _, err := tx.Exec(context.Background(), sql, args...); err != nil {
		t.Fatal(err)
	}
	return tx
}

func (r *retryRig) status(t *testing.T, id int64) (string, bool) {
	t.Helper()
	var (
		status string
		due    *time.Time
	)
	if err := r.pool.QueryRow(context.Background(), `SELECT status, next_attempt_at FROM mail_log WHERE id = $1`, id).
		Scan(&status, &due); err != nil {
		t.Fatal(err)
	}
	return status, due != nil
}

func (r *retryRig) retryNow(t *testing.T, id int64) {
	t.Helper()
	if _, err := r.pool.Exec(context.Background(), `UPDATE mail_log SET next_attempt_at = now() WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
}

func (r *retryRig) supported(t *testing.T) {
	t.Helper()
	if err := pgx.BeginFunc(context.Background(), r.pool, func(tx pgx.Tx) error {
		_, err := banks.SetStatus(context.Background(), tx, "fab", "supported", "", time.Now())
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

func TestAnEmailWhoseSubjectCouldNotBeReadIsRetried(t *testing.T) {
	const addr = "retry@example.test"
	const lockEntry = `SELECT 1 FROM waitlist_entries WHERE email_norm = $1 FOR UPDATE`
	slug := "fab"
	for _, c := range []struct {
		name, kind, state string
		lane              mailq.Lane
		params            map[string]any
		lock              string
		lockAddr          bool
		bank, account     bool
	}{
		{name: "confirmation", kind: "waitlist", state: "pending", lane: mailq.LaneWaitlist, lock: lockEntry, lockAddr: true},
		{name: "already on the list", kind: "waitlist_already", state: "confirmed", lane: mailq.LaneWaitlist,
			params: map[string]any{"variant": "confirmed"}, lock: lockEntry, lockAddr: true},
		{name: "bank works now, entry read", kind: "bank_supported", state: "confirmed", lane: mailq.LaneBulk,
			params: map[string]any{"audience": "waitlist"}, lock: lockEntry, lockAddr: true, bank: true},
		{name: "bank works now, catalog read", kind: "bank_supported", state: "confirmed", lane: mailq.LaneBulk,
			params: map[string]any{"audience": "waitlist"}, lock: `LOCK TABLE banks IN ACCESS EXCLUSIVE MODE`, bank: true},
		{name: "bank works now, account read", kind: "bank_supported", lane: mailq.LaneBulk,
			params: map[string]any{"audience": "account"}, lock: `LOCK TABLE users IN ACCESS EXCLUSIVE MODE`, bank: true, account: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			r := newRetryRig(t)
			e := mailq.Enqueue{Kind: c.kind, Lane: c.lane, To: addr, Params: c.params}
			if c.bank {
				e.BankSlug = &slug
				r.supported(t)
			}
			if c.account {
				var user uuid.UUID
				if err := r.pool.QueryRow(ctx, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
					VALUES (decode(md5('r') || md5('s'), 'hex'), now(), $1, now(), 'Retry Test') RETURNING id`, addr).Scan(&user); err != nil {
					t.Fatal(err)
				}
				e.UserID = &user
			} else {
				entry := r.entry(t, addr, c.state)
				e.EntryID = &entry
			}
			id := r.enqueue(t, e)
			var args []any
			if c.lockAddr {
				args = []any{addr}
			}
			blocker := r.hold(t, c.lock, args...)

			short, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
			defer cancel()
			if did, err := r.q.ProcessOne(short); err != nil || !did {
				t.Fatalf("process: %v %v", did, err)
			}
			if status, due := r.status(t, id); status != "queued" || !due {
				t.Fatalf("after a read that could not finish the row is %s (due %v), want queued for a retry", status, due)
			}
			if n := len(r.fake.Sent()); n != 0 {
				t.Fatalf("%d emails sent", n)
			}

			if err := blocker.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
			r.retryNow(t, id)
			if did, err := r.q.ProcessOne(ctx); err != nil || !did {
				t.Fatalf("process the retry: %v %v", did, err)
			}
			if status, _ := r.status(t, id); status != "sent" {
				t.Fatalf("the retry left the row %s, want sent", status)
			}
			if n := len(r.fake.Sent()); n != 1 {
				t.Fatalf("%d emails sent, want 1", n)
			}
		})
	}
}

func TestAnEmailWaitingOnALockPastTheTimeoutIsRetried(t *testing.T) {
	for _, c := range []struct {
		name, kind string
		lock       string
		entry      bool
	}{
		{name: "confirmation", kind: "waitlist", lock: `SELECT 1 FROM waitlist_entries FOR UPDATE`, entry: true},
		{name: "has an account", kind: "waitlist_has_account", lock: `LOCK TABLE users IN ACCESS EXCLUSIVE MODE`},
	} {
		t.Run(c.name, func(t *testing.T) {
			const addr = "locked@example.test"
			r := newRetryRig(t)
			e := mailq.Enqueue{Kind: c.kind, Lane: mailq.LaneWaitlist, To: addr}
			if c.entry {
				entry := r.entry(t, addr, "pending")
				e.EntryID = &entry
			}
			id := r.enqueue(t, e)
			r.hold(t, c.lock)
			if did, err := r.q.ProcessOne(context.Background()); err != nil || !did {
				t.Fatalf("process: %v %v", did, err)
			}
			if status, due := r.status(t, id); status != "queued" || !due {
				t.Fatalf("after a lock timeout the row is %s (due %v), want queued for a retry", status, due)
			}
			if n := len(r.fake.Sent()); n != 0 {
				t.Fatalf("%d emails sent", n)
			}
		})
	}
}

func TestAnEmailWhoseSubjectMovedOnFailsWithoutARetry(t *testing.T) {
	ctx := context.Background()
	slug := "fab"
	for _, c := range []struct {
		name, kind, from, to string
		lane                 mailq.Lane
		params               map[string]any
		bank                 bool
	}{
		{name: "confirmation", kind: "waitlist", from: "pending", to: "confirmed", lane: mailq.LaneWaitlist},
		{name: "already on the list", kind: "waitlist_already", from: "confirmed", to: "joined", lane: mailq.LaneWaitlist,
			params: map[string]any{"variant": "confirmed"}},
		{name: "bank works now", kind: "bank_supported", from: "confirmed", to: "joined", lane: mailq.LaneBulk,
			params: map[string]any{"audience": "waitlist"}, bank: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			const addr = "moved@example.test"
			r := newRetryRig(t)
			entry := r.entry(t, addr, c.from)
			e := mailq.Enqueue{Kind: c.kind, Lane: c.lane, To: addr, EntryID: &entry, Params: c.params}
			if c.bank {
				e.BankSlug = &slug
				r.supported(t)
			}
			id := r.enqueue(t, e)
			if _, err := r.pool.Exec(ctx, `UPDATE waitlist_entries SET state = $2, confirmed_at = now(), invited_at = now(),
				joined_at = CASE WHEN $2 = 'joined' THEN now() END,
				email_norm = CASE WHEN $2 = 'joined' THEN NULL ELSE email_norm END WHERE id = $1`, entry, c.to); err != nil {
				t.Fatal(err)
			}
			if did, err := r.q.ProcessOne(ctx); err != nil || !did {
				t.Fatalf("process: %v %v", did, err)
			}
			if status, due := r.status(t, id); status != "failed" || due {
				t.Fatalf("the row is %s (due %v), want failed", status, due)
			}
			if n := len(r.fake.Sent()); n != 0 {
				t.Fatalf("%d emails sent", n)
			}
		})
	}
}
