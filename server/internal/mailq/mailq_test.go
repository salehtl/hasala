package mailq

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

type fixture struct {
	t     *testing.T
	pool  *pgxpool.Pool
	c     *clock
	fake  *mail.Fake
	q     *Queue
	user  uuid.UUID
	bounc int
}

func newFixture(t *testing.T) *fixture {
	pool := pgtest.New(t)
	f := &fixture{t: t, pool: pool, c: &clock{t: time.Now().UTC()}, fake: &mail.Fake{}}
	f.user = oplogtest.NewUserWithoutKeys(t, pool)
	f.q = &Queue{Pool: pool, Sender: f.fake, Now: f.c.now, Logf: func(string, ...any) {},
		Renderers: map[string]Renderer{
			"alert": RendererFunc(func(_ context.Context, _ pgx.Tx, r Row) (mail.Message, error) {
				return mail.Message{Subject: "alert " + r.Subkind, Text: "text"}, nil
			}),
			"deleted": RendererFunc(func(_ context.Context, _ pgx.Tx, r Row) (mail.Message, error) {
				return mail.Deleted(r.Recipient, r.CreatedAt), nil
			}),
		},
		Bounced: func(context.Context, pgx.Tx, Row) error { f.bounc++; return nil },
	}
	return f
}

func (f *fixture) enqueue(e Enqueue) int64 {
	f.t.Helper()
	tx, err := f.pool.Begin(bg)
	if err != nil {
		f.t.Fatal(err)
	}
	id, err := f.q.EnqueueTx(bg, tx, e)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		f.t.Fatal(err)
	}
	return id
}

func (f *fixture) row(id int64) (status string, recipient *string, attempts int, next *time.Time) {
	f.t.Helper()
	if err := f.pool.QueryRow(bg, `SELECT status, recipient, attempts, next_attempt_at FROM mail_log WHERE id = $1`, id).
		Scan(&status, &recipient, &attempts, &next); err != nil {
		f.t.Fatal(err)
	}
	return
}

func tag() []byte { return make([]byte, 32) }

func TestAQueuedAlertIsRenderedSentAndFinalized(t *testing.T) {
	f := newFixture(t)
	id := f.enqueue(Enqueue{Kind: "alert", Subkind: "new_passkey", Lane: LaneTransactional, To: "maya@example.com",
		Tag: tag(), UserID: &f.user, Params: map[string]any{"event_at": "x"}})
	if n, err := f.q.RunOnce(bg); err != nil || n != 1 {
		t.Fatalf("RunOnce = %d, %v", n, err)
	}
	st, rcpt, attempts, _ := f.row(id)
	if st != "sent" || rcpt == nil || attempts != 1 {
		t.Fatalf("row %s %v %d", st, rcpt, attempts)
	}
	if got := f.fake.Sent(); len(got) != 1 || got[0].To != "maya@example.com" {
		t.Fatalf("sent %+v", got)
	}
	var hint string
	_ = f.pool.QueryRow(bg, `SELECT recipient_hint FROM mail_log WHERE id = $1`, id).Scan(&hint)
	if hint != "m•••@example.com" {
		t.Fatalf("hint %q", hint)
	}
}

func TestParamsOutsideTheAllowListAreRefused(t *testing.T) {
	f := newFixture(t)
	tx, _ := f.pool.Begin(bg)
	defer func() { _ = tx.Rollback(bg) }()
	if _, err := f.q.EnqueueTx(bg, tx, Enqueue{Kind: "alert", Lane: LaneTransactional, To: "m@example.com",
		Params: map[string]any{"name": "Maya"}}); err == nil {
		t.Fatal("a name in params was accepted")
	}
	if _, err := f.q.EnqueueTx(bg, tx, Enqueue{Kind: "carrier_pigeon", Lane: LaneTransactional, To: "m@example.com"}); err == nil {
		t.Fatal("an unknown kind was accepted")
	}
}

func TestTransientFailuresBackOffInsideTheKindsWindow(t *testing.T) {
	f := newFixture(t)
	f.fake.Err = func(mail.Message) error { return errors.New("upstream 503") }
	id := f.enqueue(Enqueue{Kind: "alert", Subkind: "new_passkey", Lane: LaneTransactional, To: "m@example.com", Tag: tag(), UserID: &f.user})
	_, _ = f.q.RunOnce(bg)
	st, _, attempts, next := f.row(id)
	if st != "queued" || attempts != 1 || next == nil || !next.Equal(f.c.now().Add(time.Minute)) {
		t.Fatalf("after one transient failure: %s %d %v", st, attempts, next)
	}
	// Not due yet.
	if n, _ := f.q.RunOnce(bg); n != 0 {
		t.Fatal("a row was retried before its backoff")
	}
	f.c.add(time.Minute)
	f.fake.Err = nil
	if n, _ := f.q.RunOnce(bg); n != 1 {
		t.Fatal("the retry did not send")
	}
	// A code row's window is ten minutes: a failure past it is final.
	f.fake.Err = func(mail.Message) error { return errors.New("upstream 503") }
	f.q.Renderers["code"] = RendererFunc(func(context.Context, pgx.Tx, Row) (mail.Message, error) { return mail.Message{}, nil })
	cid := f.enqueue(Enqueue{Kind: "code", Lane: LaneTransactional, To: "m@example.com", Tag: tag(), UserID: &f.user,
		Params: map[string]any{"purpose": "email_verify"}})
	for i := 0; i < 4; i++ {
		_, _ = f.q.RunOnce(bg)
		f.c.add(30 * time.Minute)
	}
	if st, _, _, _ := f.row(cid); st != "failed" {
		t.Fatalf("a code past its window is %s", st)
	}
}

func TestAnAuthFailurePausesEveryLane(t *testing.T) {
	f := newFixture(t)
	f.fake.Err = func(mail.Message) error { return &mail.SendError{Class: mail.ErrAuth, Status: 401} }
	a := f.enqueue(Enqueue{Kind: "alert", Subkind: "new_passkey", Lane: LaneTransactional, To: "a@example.com", Tag: tag(), UserID: &f.user})
	b := f.enqueue(Enqueue{Kind: "alert", Subkind: "new_passkey", Lane: LaneTransactional, To: "b@example.com", Tag: tag(), UserID: &f.user})
	_, _ = f.q.RunOnce(bg)
	if !f.q.Paused() {
		t.Fatal("an auth failure did not pause the worker")
	}
	for _, id := range []int64{a, b} {
		if st, _, _, _ := f.row(id); st != "queued" {
			t.Fatalf("row %d is %s", id, st)
		}
	}
	f.fake.Err = nil
	if n, _ := f.q.RunOnce(bg); n != 0 || len(f.fake.Sent()) != 0 {
		t.Fatal("a paused worker sent")
	}
}

func TestADeletedRowLosesItsAddressWhenFinal(t *testing.T) {
	f := newFixture(t)
	id := f.enqueue(Enqueue{Kind: "deleted", Lane: LaneTransactional, To: "gone@example.com", Tag: tag(),
		Params: map[string]any{"deleted_at": "x"}})
	_, _ = f.q.RunOnce(bg)
	st, rcpt, _, _ := f.row(id)
	if st != "sent" || rcpt != nil {
		t.Fatalf("a final deleted row: %s, recipient kept %v", st, rcpt != nil)
	}
}

func TestSendNowLogsTheSendAndNeverTheSecret(t *testing.T) {
	f := newFixture(t)
	err := f.q.SendNow(bg, Enqueue{Kind: "code", Lane: LaneTransactional, To: "m@example.com", Tag: tag(), UserID: &f.user,
		Params: map[string]any{"purpose": "signup"}}, func() (mail.Message, error) {
		return mail.Code("m@example.com", "signup", "424242", "")
	})
	if err != nil {
		t.Fatal(err)
	}
	var (
		status string
		params string
	)
	if err := f.pool.QueryRow(bg, `SELECT status, params::text FROM mail_log`).Scan(&status, &params); err != nil {
		t.Fatal(err)
	}
	if status != "sent" || strings.Contains(params, "424242") {
		t.Fatalf("row %s %s", status, params)
	}
	// One attempt: a transient failure is final.
	f.fake.Err = func(mail.Message) error { return errors.New("upstream") }
	_ = f.q.SendNow(bg, Enqueue{Kind: "code", Lane: LaneTransactional, To: "m@example.com", Tag: tag(),
		Params: map[string]any{"purpose": "signup"}}, func() (mail.Message, error) { return mail.Message{}, nil })
	if n := 0; f.pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE status = 'failed'`).Scan(&n) != nil || n != 1 {
		t.Fatal("a failed SendNow is not final")
	}
}

func TestABounceRunsTheHook(t *testing.T) {
	f := newFixture(t)
	f.fake.Err = func(mail.Message) error { return &mail.SendError{Class: mail.ErrBounced, Status: 200} }
	id := f.enqueue(Enqueue{Kind: "alert", Subkind: "new_passkey", Lane: LaneTransactional, To: "m@example.com", Tag: tag(), UserID: &f.user})
	_, _ = f.q.RunOnce(bg)
	if st, _, _, _ := f.row(id); st != "bounced" || f.bounc != 1 {
		t.Fatalf("status %s, hook ran %d", st, f.bounc)
	}
}

func TestHint(t *testing.T) {
	for in, want := range map[string]string{"maya@example.com": "m•••@example.com", "m@example.com": "•••@example.com"} {
		if Hint(in) != want {
			t.Errorf("Hint(%q) = %q", in, Hint(in))
		}
	}
}
