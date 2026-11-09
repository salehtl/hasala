package banks_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

var bg = context.Background()

type notifyRig struct {
	t    *testing.T
	pool *pgxpool.Pool
}

func newNotifyRig(t *testing.T) *notifyRig {
	t.Helper()
	return &notifyRig{t: t, pool: pgtest.New(t)}
}

func (r *notifyRig) exec(q string, args ...any) {
	r.t.Helper()
	if _, err := r.pool.Exec(bg, q, args...); err != nil {
		r.t.Fatal(err)
	}
}

const insertAccount = `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
	VALUES (decode(md5($1) || md5($1 || 'b'), 'hex'), now(), $1, now(), 'Maya Test') RETURNING id`

func (r *notifyRig) account(email string) uuid.UUID {
	r.t.Helper()
	var id uuid.UUID
	if err := r.pool.QueryRow(bg, insertAccount, email).Scan(&id); err != nil {
		r.t.Fatal(err)
	}
	r.exec(`INSERT INTO bank_requests (bank_slug, source, user_id, created_at) VALUES ('fab', 'app', $1, now())`, id)
	return id
}

func (r *notifyRig) entry(email, state string) uuid.UUID {
	r.t.Helper()
	var id uuid.UUID
	var confirmed any
	if state != "pending" {
		confirmed = time.Now()
	}
	if err := r.pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at,
		updated_at, confirmed_at) VALUES (sha256(convert_to($1::text, 'UTF8')), $1::text, $2, 'fab', 'web', now(), now(), $3) RETURNING id`,
		email, state, confirmed).Scan(&id); err != nil {
		r.t.Fatal(err)
	}
	r.exec(`INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at) VALUES ('fab', 'web_waitlist', $1, now())`, id)
	return id
}

func notifyIn(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	var n int
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		now := time.Now()
		if _, err := banks.SetStatus(ctx, tx, "fab", "supported", "", now); err != nil {
			return err
		}
		var err error
		n, err = banks.NotifySupported(ctx, tx, mailq.New(pool, nil, nil), "fab", now)
		return err
	})
	return n, err
}

func (r *notifyRig) notify() int {
	r.t.Helper()
	n, err := notifyIn(bg, r.pool)
	if err != nil {
		r.t.Fatal(err)
	}
	return n
}

func (r *notifyRig) finishMail(status string) {
	r.t.Helper()
	sentAt := "NULL"
	if status == "sent" {
		sentAt = "now()"
	}
	r.exec(`UPDATE mail_log SET status = $1, final_at = now(), next_attempt_at = NULL, sent_at = `+sentAt+`,
		recipient_tag = decode(repeat('cd', 32), 'hex') WHERE kind = 'bank_supported' AND status = 'queued'`, status)
}

func (r *notifyRig) mails() (n int) {
	r.t.Helper()
	if err := r.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE kind = 'bank_supported'`).Scan(&n); err != nil {
		r.t.Fatal(err)
	}
	return n
}

func (r *notifyRig) stamped() (n int) {
	r.t.Helper()
	if err := r.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE notified_at IS NOT NULL`).Scan(&n); err != nil {
		r.t.Fatal(err)
	}
	return n
}

func TestAFailedBankEmailIsSentAgainByTheNextNotify(t *testing.T) {
	r := newNotifyRig(t)
	r.account("maya@example.test")
	r.entry("guest@example.test", "confirmed")
	if n := r.notify(); n != 2 {
		t.Fatalf("%d queued, want 2", n)
	}
	r.finishMail("failed")
	if n := r.notify(); n != 2 {
		t.Fatalf("%d queued after both failed, want 2 again", n)
	}
	if n := r.notify(); n != 0 || r.mails() != 4 {
		t.Fatalf("%d queued while the retries wait, %d rows", n, r.mails())
	}
	r.finishMail("failed")
	if n := r.notify(); n != 2 || r.mails() != 6 {
		t.Fatalf("%d queued after the retries failed, %d rows", n, r.mails())
	}
	r.finishMail("sent")
	if n := r.notify(); n != 0 || r.mails() != 6 {
		t.Fatalf("%d queued after the retries were sent, %d rows", n, r.mails())
	}
}

func TestABankEmailThatEndedAnyOtherWayIsNotSentAgain(t *testing.T) {
	for _, status := range []string{"sent", "bounced", "suppressed"} {
		t.Run(status, func(t *testing.T) {
			r := newNotifyRig(t)
			r.account("maya@example.test")
			if n := r.notify(); n != 1 {
				t.Fatalf("%d queued, want 1", n)
			}
			r.finishMail(status)
			if n := r.notify(); n != 0 || r.mails() != 1 {
				t.Fatalf("%d queued, %d rows after a %s email", n, r.mails(), status)
			}
		})
	}
}

func TestARetriedBankEmailGoesToTheAddressTheAccountHasNow(t *testing.T) {
	r := newNotifyRig(t)
	u := r.account("maya@example.test")
	r.notify()
	r.finishMail("failed")
	r.exec(`UPDATE users SET email_norm = 'moved@example.test' WHERE id = $1`, u)
	if n := r.notify(); n != 1 {
		t.Fatalf("%d queued, want 1", n)
	}
	var to string
	if err := r.pool.QueryRow(bg, `SELECT recipient FROM mail_log WHERE status = 'queued'`).Scan(&to); err != nil || to != "moved@example.test" {
		t.Fatalf("retry to %q (%v)", to, err)
	}
}

func TestOneFailedEmailDoesNotReopenAnotherPersonsRequest(t *testing.T) {
	r := newNotifyRig(t)
	r.account("maya@example.test")
	r.notify()
	r.finishMail("sent")
	other := r.account("sara@example.test")
	r.notify()
	r.exec(`UPDATE mail_log SET status = 'failed', final_at = now(), next_attempt_at = NULL,
		recipient_tag = decode(repeat('cd', 32), 'hex') WHERE user_id = $1`, other)
	if n := r.notify(); n != 1 || r.mails() != 3 {
		t.Fatalf("%d queued, %d rows, want only the failed person retried", n, r.mails())
	}
}

func TestARequestWithNoAddressIsNotMarkedTold(t *testing.T) {
	r := newNotifyRig(t)
	e := r.entry("waiting@example.test", "pending")
	if n := r.notify(); n != 0 || r.stamped() != 0 {
		t.Fatalf("%d queued, %d marked told with no address to write to", n, r.stamped())
	}
	r.exec(`UPDATE waitlist_entries SET state = 'confirmed', confirmed_at = now() WHERE id = $1`, e)
	if n := r.notify(); n != 1 || r.stamped() != 1 {
		t.Fatalf("%d queued, %d marked told once the entry could be written to", n, r.stamped())
	}
}

func TestAJoinDuringNotifyLeavesTheRequestToBeTold(t *testing.T) {
	r := newNotifyRig(t)
	e := r.entry("joining@example.test", "confirmed")
	tx, err := r.pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(bg) }()
	var u uuid.UUID
	if err := tx.QueryRow(bg, insertAccount, "joining@example.test").Scan(&u); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(bg, `UPDATE waitlist_entries SET state = 'joined', joined_at = now(), invited_at = now(), email_norm = NULL
		WHERE id = $1`, e); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(bg, `UPDATE bank_requests SET user_id = $1, waitlist_entry_id = NULL, source = 'app' WHERE waitlist_entry_id = $2`, u, e); err != nil {
		t.Fatal(err)
	}
	type result struct {
		n   int
		err error
	}
	done := make(chan result, 1)
	go func() {
		n, err := notifyIn(bg, r.pool)
		done <- result{n, err}
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting int
		if err := r.pool.QueryRow(bg, `SELECT count(*) FROM pg_stat_activity
			WHERE wait_event_type = 'Lock' AND query LIKE '%FOR UPDATE OF r%'`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("notify never waited on the request")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	res := <-done
	if res.err != nil {
		t.Fatal(res.err)
	}
	if res.n != 0 || r.stamped() != 0 {
		t.Fatalf("%d queued, %d marked told for a request whose address was unreadable", res.n, r.stamped())
	}
	if n := r.notify(); n != 1 || r.stamped() != 1 {
		t.Fatalf("the next notify queued %d and marked %d", n, r.stamped())
	}
}
