package mailq

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func expireLeases(t *testing.T, q *Queue) {
	t.Helper()
	if _, err := q.Pool.Exec(bg, `UPDATE mail_log SET lease_until = now() - interval '1 minute' WHERE status = 'sending'`); err != nil {
		t.Fatal(err)
	}
}

func hookDue(t *testing.T, q *Queue, id int64) bool {
	t.Helper()
	var due bool
	if err := q.Pool.QueryRow(bg, `SELECT hook_due FROM mail_log WHERE id = $1`, id).Scan(&due); err != nil {
		t.Fatal(err)
	}
	return due
}

func TestAHookErrorKeepsTheOutcomeAndTheHookRunsLater(t *testing.T) {
	for _, c := range []struct {
		name   string
		err    error
		status string
	}{
		{"bounced", mail.ErrBounced, "bounced"},
		{"failed for good", mail.ErrPermanent, "failed"},
	} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			fake := &mail.Fake{}
			q := New(pool, fake, fixedTagger{})
			q.Register("test", TestRenderer)
			var sends int
			fake.ErrFor = func(mail.Message) error { sends++; return c.err }
			q.Unsent = func(context.Context, pgx.Tx, Row) (func(), error) {
				return nil, errors.New("the hook cannot run yet")
			}
			id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com"})
			if n, err := q.Drain(bg); err != nil || n != 1 {
				t.Fatalf("drain %d %v", n, err)
			}
			if st, att, _, _ := row(t, pool, id); st != c.status || att != 1 {
				t.Fatalf("after the hook error: %s, attempt %d", st, att)
			}
			if !hookDue(t, q, id) {
				t.Fatal("the failed hook is not owed")
			}
			expireLeases(t, q)
			if _, err := q.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if sends != 1 {
				t.Fatalf("the address was mailed %d times", sends)
			}

			restarted := New(pool, fake, fixedTagger{})
			restarted.Register("test", TestRenderer)
			var ran []int64
			var after int
			restarted.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
				ran = append(ran, r.ID)
				return func() { after++ }, nil
			}
			if _, err := restarted.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if len(ran) != 1 || ran[0] != id || after != 1 || hookDue(t, q, id) {
				t.Fatalf("after a restart the hook ran for %v, after %d, still due %v", ran, after, hookDue(t, q, id))
			}
			if _, err := restarted.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if len(ran) != 1 {
				t.Fatalf("the hook ran %d times", len(ran))
			}
			if st, _, _, _ := row(t, pool, id); st != c.status {
				t.Fatalf("after the hook ran: %s", st)
			}
		})
	}
}

func TestABounceHookErrorIsRetriedWithTheRowsAddress(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, &mail.Fake{Err: mail.ErrBounced}, fixedTagger{})
	q.Register("test", TestRenderer)
	user := oplogtest.NewUserWithoutKeys(t, pool)
	fail := true
	var got []Row
	q.Bounced = func(_ context.Context, _ pgx.Tx, r Row) error {
		if fail {
			return errors.New("the hook cannot run yet")
		}
		got = append(got, r)
		return nil
	}
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com", UserID: &user})
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if st, _, _, _ := row(t, pool, id); st != "bounced" || !hookDue(t, q, id) {
		t.Fatalf("status %s due %v", st, hookDue(t, q, id))
	}
	fail = false
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != id || got[0].Recipient != "a@example.com" || got[0].UserID == nil || *got[0].UserID != user {
		t.Fatalf("hook rows %+v", got)
	}
}

func TestOneRowsHookErrorDoesNotStopTheOtherRows(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	broken := enqueue(t, pool, q, Enqueue{Kind: "test", To: "broken@example.com"})
	fine := enqueue(t, pool, q, Enqueue{Kind: "test", To: "fine@example.com"})
	if _, err := pool.Exec(bg, `UPDATE mail_log SET attempts = $1`, maxAttempts); err != nil {
		t.Fatal(err)
	}
	next := enqueue(t, pool, q, Enqueue{Kind: "test", To: "next@example.com"})
	var ran []int64
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
		if r.ID == broken {
			return nil, errors.New("this row's hook always fails")
		}
		ran = append(ran, r.ID)
		return nil, nil
	}
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain %d %v", n, err)
	}
	for _, id := range []int64{broken, fine} {
		if st, _, _, _ := row(t, pool, id); st != "failed" {
			t.Fatalf("row %d: %s", id, st)
		}
	}
	if st, _, _, _ := row(t, pool, next); st != "sent" {
		t.Fatalf("the row behind the failing hook: %s", st)
	}
	if len(ran) != 1 || ran[0] != fine {
		t.Fatalf("the hook ran for %v", ran)
	}
	if !hookDue(t, q, broken) || hookDue(t, q, fine) {
		t.Fatalf("due: broken %v fine %v", hookDue(t, q, broken), hookDue(t, q, fine))
	}
}

func TestTwoWorkersRunAHookOnce(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, &mail.Fake{Err: mail.ErrPermanent}, fixedTagger{})
	q.Register("test", TestRenderer)
	runs := 0
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
		runs++
		if err := q.settleTx(bg, r.ID); err != nil {
			t.Errorf("the second worker: %v", err)
		}
		return nil, nil
	}
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com"})
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if runs != 1 || hookDue(t, q, id) {
		t.Fatalf("the hook ran %d times, still due %v", runs, hookDue(t, q, id))
	}
}

func failOutcomeWrites(t *testing.T, owner *pgxpool.Pool, times int, code string) {
	t.Helper()
	for _, sql := range []string{
		`CREATE SEQUENCE outcome_failures`,
		`GRANT USAGE ON SEQUENCE outcome_failures TO hasala_runtime`,
		fmt.Sprintf(`CREATE FUNCTION fail_outcome() RETURNS trigger AS $$
		BEGIN
		  IF OLD.status = 'sending' AND NEW.status = 'sent' AND nextval('outcome_failures') <= %d THEN
		    RAISE EXCEPTION 'the database is busy' USING ERRCODE = '%s';
		  END IF;
		  RETURN NEW;
		END $$ LANGUAGE plpgsql`, times, code),
		`CREATE TRIGGER fail_outcome BEFORE UPDATE ON mail_log FOR EACH ROW EXECUTE FUNCTION fail_outcome()`,
	} {
		if _, err := owner.Exec(bg, sql); err != nil {
			t.Fatal(err)
		}
	}
}

func TestASentEmailIsNotSentAgainWhenItsOutcomeWriteFails(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	failOutcomeWrites(t, owner, 2, "40001")
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com"})
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	expireLeases(t, q)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if st, att, _, _ := row(t, pool, id); st != "sent" || att != 1 || len(fake.Sent()) != 1 {
		t.Fatalf("status %s, attempt %d, sent %d times", st, att, len(fake.Sent()))
	}
}

func TestAnOutcomeWriteRefusedForGoodIsNotRetried(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	q := New(pool, &mail.Fake{}, fixedTagger{})
	q.Register("test", TestRenderer)
	failOutcomeWrites(t, owner, 1000, "23514")
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com"})
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	var tries int64
	if err := owner.QueryRow(bg, `SELECT last_value FROM outcome_failures`).Scan(&tries); err != nil {
		t.Fatal(err)
	}
	if st, _, _, _ := row(t, pool, id); st != "sending" || tries != 1 {
		t.Fatalf("status %s after %d writes", st, tries)
	}
}

func TestOutcomeRetriesEndBeforeTheLease(t *testing.T) {
	total := renderFor + sendTimeout + time.Duration(len(outcomeRetries)+1)*outcomeTimeout
	for _, wait := range outcomeRetries {
		total += wait
	}
	if total >= leaseFor {
		t.Fatalf("render, send and every outcome write can take %s, the lease is %s", total, leaseFor)
	}
}

func TestAnOrphanedSendNowRowIsNotSentAgain(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	rendered := 0
	q.Register("code", RenderFunc(func(_ context.Context, _ pgx.Tx, r Row) (mail.Message, error) {
		rendered++
		return mail.Message{To: r.Recipient, Subject: "s", Text: "t"}, nil
	}))
	var ran []string
	q.Unsent = func(_ context.Context, _ pgx.Tx, r Row) (func(), error) {
		ran = append(ran, r.Kind)
		return nil, nil
	}
	died := make(chan struct{})
	go func() {
		defer close(died)
		_ = q.SendNow(bg, Enqueue{Kind: "code", To: "a@example.com", Params: map[string]any{"purpose": "email_verify"}},
			func() (mail.Message, error) {
				runtime.Goexit()
				return mail.Message{}, nil
			})
	}()
	<-died
	expireLeases(t, q)
	if n, err := q.Drain(bg); err != nil || n != 0 {
		t.Fatalf("drain %d %v", n, err)
	}
	var (
		st  string
		att int
	)
	if err := pool.QueryRow(bg, `SELECT status, attempts FROM mail_log`).Scan(&st, &att); err != nil {
		t.Fatal(err)
	}
	if st != "failed" || att != 1 || rendered != 0 || len(fake.Sent()) != 0 {
		t.Fatalf("status %s, attempts %d, rendered %d, sent %d", st, att, rendered, len(fake.Sent()))
	}
	if len(ran) != 1 || ran[0] != "code" {
		t.Fatalf("the hook ran for %v", ran)
	}
}

func TestALeaseRescueHonoursTheRetryWindow(t *testing.T) {
	for _, c := range []struct {
		name, kind, age string
		params          map[string]any
		status          string
		sent            int
	}{
		{"code inside its window", "code", "9 minutes", map[string]any{"purpose": "email_verify"}, "sent", 1},
		{"code past its window", "code", "11 minutes", map[string]any{"purpose": "email_verify"}, "failed", 0},
		{"other kind inside its window", "test", "11 minutes", nil, "sent", 1},
		{"other kind past its window", "test", "25 hours", nil, "failed", 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			fake := &mail.Fake{}
			q := New(pool, fake, fixedTagger{})
			q.Register(c.kind, RenderFunc(func(_ context.Context, _ pgx.Tx, r Row) (mail.Message, error) {
				return mail.Message{To: r.Recipient, Subject: "s", Text: "t"}, nil
			}))
			id := enqueue(t, pool, q, Enqueue{Kind: c.kind, To: "a@example.com", Params: c.params})
			if _, err := pool.Exec(bg, `UPDATE mail_log SET status = 'sending', attempts = 1, next_attempt_at = NULL,
				lease_until = now() - interval '1 minute', created_at = now() - $2::interval WHERE id = $1`, id, c.age); err != nil {
				t.Fatal(err)
			}
			if _, err := q.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if st, _, _, _ := row(t, pool, id); st != c.status || len(fake.Sent()) != c.sent {
				t.Fatalf("status %s, sent %d", st, len(fake.Sent()))
			}
		})
	}
}
