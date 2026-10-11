package mailq

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

type fixedTagger struct{}

func (fixedTagger) EmailTag(s string) []byte {
	b := bytes.Repeat([]byte{1}, 32)
	copy(b, s)
	return b
}

func enqueue(t *testing.T, pool *pgxpool.Pool, q *Queue, e Enqueue) int64 {
	t.Helper()
	var id int64
	err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		var err error
		id, err = q.EnqueueTx(bg, tx, e)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func row(t *testing.T, pool *pgxpool.Pool, id int64) (status string, attempts int, recipient *string, errText *string) {
	t.Helper()
	if err := pool.QueryRow(bg, `SELECT status, attempts, recipient, error FROM mail_log WHERE id = $1`, id).
		Scan(&status, &attempts, &recipient, &errText); err != nil {
		t.Fatal(err)
	}
	return
}

func TestHint(t *testing.T) {
	for in, want := range map[string]string{"maya@example.com": "m•••@example.com", "m@example.com": "•••@example.com"} {
		if got := Hint(in); got != want {
			t.Errorf("Hint(%q) = %q, want %q", in, got, want)
		}
	}
	if Greeting("Maya Rahman") != "Hi Maya," || Greeting("") != "Hi," || Greeting("Maya") != "Hi Maya," {
		t.Fatal("Greeting")
	}
}

// F7-6: no template carries a script, an inline style, an http:// link or a
// remote image, and every href is on https://hasala.app/.
func TestTemplatesAreContentFree(t *testing.T) {
	href := regexp.MustCompile(`href="([^"]*)"`)
	n := 0
	err := fs.WalkDir(templateFS, "templates", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, _ := templateFS.ReadFile(path)
		s := string(b)
		n++
		for _, bad := range []string{"<script", " style=", "http://", "<img"} {
			if strings.Contains(strings.ToLower(s), bad) {
				t.Errorf("%s contains %q", path, bad)
			}
		}
		for _, m := range href.FindAllStringSubmatch(s, -1) {
			if !strings.HasPrefix(m[1], "https://hasala.app/") && !strings.HasPrefix(m[1], "{{") {
				t.Errorf("%s links to %q", path, m[1])
			}
		}
		return nil
	})
	if err != nil || n < 10 {
		t.Fatalf("walked %d templates: %v", n, err)
	}
	for _, kind := range []string{"waitlist", "waitlist_already", "waitlist_has_account", "invite", "bank_supported", "test"} {
		r, err := RenderTemplate(kind, Content{Email: "a@example.com", BankName: "Emirates NBD",
			ConfirmURL: "https://hasala.app/waitlist/confirm#x", LeaveURL: "https://hasala.app/waitlist/leave#y",
			InviteURL: "https://hasala.app/i/X#y"})
		if err != nil || r.Subject == "" || !strings.Contains(r.Text, "Hasala never asks for your recovery phrase") {
			t.Errorf("%s: %+v %v", kind, r, err)
		}
		if strings.Contains(r.Subject, "\n") || strings.HasPrefix(r.Text, "\n") {
			t.Errorf("%s: subject/body split", kind)
		}
	}
}

func TestWorkerOutcomes(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)

	// Sent.
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com"})
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain %d %v", n, err)
	}
	if st, att, _, _ := row(t, pool, id); st != "sent" || att != 1 || len(fake.Sent()) != 1 {
		t.Fatalf("sent row %s %d", st, att)
	}

	// Transient: back to queued with a backoff.
	fake.Err = errors.New("mail: upstream: http 503 code 0")
	id = enqueue(t, pool, q, Enqueue{Kind: "test", To: "b@example.com"})
	_, _ = q.Drain(bg)
	if st, att, _, e := row(t, pool, id); st != "queued" || att != 1 || e == nil {
		t.Fatalf("transient row %s %d", st, att)
	}
	var wait bool
	_ = pool.QueryRow(bg, `SELECT next_attempt_at > now() + interval '50 seconds' FROM mail_log WHERE id = $1`, id).Scan(&wait)
	if !wait {
		t.Fatal("no backoff after a transient failure")
	}
	if _, err := pool.Exec(bg, `DELETE FROM mail_log WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}

	// Permanent and bounced: final.
	fake.Err = mail.ErrPermanent
	id = enqueue(t, pool, q, Enqueue{Kind: "test", To: "c@example.com"})
	_, _ = q.Drain(bg)
	if st, _, _, _ := row(t, pool, id); st != "failed" {
		t.Fatalf("permanent %s", st)
	}
	fake.Err = mail.ErrBounced
	id = enqueue(t, pool, q, Enqueue{Kind: "test", To: "d@example.com"})
	_, _ = q.Drain(bg)
	if st, _, _, _ := row(t, pool, id); st != "bounced" {
		t.Fatalf("bounced %s", st)
	}

	// A `deleted` email loses its address the moment it is final (O-17).
	fake.Err = nil
	q.Register("deleted", RenderFunc(func(_ context.Context, _ pgx.Tx, r Row) (mail.Message, error) {
		return mail.Message{To: r.Recipient, Subject: "s", Text: "t"}, nil
	}))
	id = enqueue(t, pool, q, Enqueue{Kind: "deleted", To: "gone@example.com", Params: map[string]any{"deleted_at": "x"}})
	_, _ = q.Drain(bg)
	if st, _, rcp, _ := row(t, pool, id); st != "sent" || rcp != nil {
		t.Fatalf("deleted row %s keeps %v", st, rcp)
	}

	// Auth: the row goes back to queued and every lane stops.
	fake.Err = mail.ErrAuth
	id = enqueue(t, pool, q, Enqueue{Kind: "test", To: "e@example.com"})
	_, _ = q.Drain(bg)
	if st, _, _, _ := row(t, pool, id); st != "queued" || !q.Stopped() {
		t.Fatalf("auth: %s stopped=%v", st, q.Stopped())
	}
	fake.Err = nil
	if n, _ := q.Drain(bg); n != 0 {
		t.Fatal("a stopped worker sent")
	}

	// Params outside the allow-list are a programming error.
	err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		_, err := q.EnqueueTx(bg, tx, Enqueue{Kind: "test", To: "f@example.com", Params: map[string]any{"name": "Maya"}})
		return err
	})
	if err == nil {
		t.Fatal("a name in params was accepted")
	}
}

func TestLaneRateHoldsRowsQueued(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	q.Rates = map[Lane]int{LaneBulk: 1}
	q.Register("test", TestRenderer)
	a := enqueue(t, pool, q, Enqueue{Kind: "test", Lane: LaneBulk, To: "a@example.com"})
	b := enqueue(t, pool, q, Enqueue{Kind: "test", Lane: LaneBulk, To: "b@example.com"})
	c := enqueue(t, pool, q, Enqueue{Kind: "test", Lane: LaneTransactional, To: "c@example.com"})
	_, _ = q.Drain(bg)
	sa, _, _, _ := row(t, pool, a)
	sb, _, _, _ := row(t, pool, b)
	sc, _, _, _ := row(t, pool, c)
	if sa != "sent" || sb != "queued" || sc != "sent" {
		t.Fatalf("a=%s b=%s c=%s: the bulk lane's rate did not hold b, or held the transactional lane", sa, sb, sc)
	}
}

func TestSendNowAndSweep(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	err := q.SendNow(bg, Enqueue{Kind: "code", To: "a@example.com", Params: map[string]any{"purpose": "signup"}},
		func() (mail.Message, error) { return mail.Message{Subject: "Your Hasala code", Text: "123456"}, nil })
	if err != nil || len(fake.Sent()) != 1 || fake.Sent()[0].To != "a@example.com" {
		t.Fatalf("SendNow: %v %+v", err, fake.Sent())
	}
	var st string
	_ = pool.QueryRow(bg, `SELECT status FROM mail_log`).Scan(&st)
	if st != "sent" {
		t.Fatalf("SendNow row %s", st)
	}
	if _, err := pool.Exec(bg, `UPDATE mail_log SET created_at = now() - interval '31 days'`); err != nil {
		t.Fatal(err)
	}
	if msg, err := q.Sweep(bg); err != nil || msg == "" {
		t.Fatalf("sweep %q %v", msg, err)
	}
	var n int
	_ = pool.QueryRow(bg, `SELECT count(*) FROM mail_log`).Scan(&n)
	if n != 0 {
		t.Fatal("retention kept a 31-day-old row")
	}
}

// serve without [email]: a send fails for good at once, so the log never says
// `sent` for a message that went nowhere and the row is not retried.
func TestUnconfiguredSenderFailsRowsAtOnce(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, mail.Unconfigured{}, fixedTagger{})
	q.Register("test", TestRenderer)
	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "nowhere@example.com"})
	if n, err := q.Drain(bg); err != nil || n != 1 {
		t.Fatalf("drain %d %v", n, err)
	}
	st, att, _, e := row(t, pool, id)
	if st != "failed" || att != 1 || e == nil || !strings.Contains(*e, "not configured") {
		t.Fatalf("row %s attempts %d error %v", st, att, e)
	}
	if !errors.Is(mail.ErrNotConfigured, mail.ErrPermanent) || q.Stopped() {
		t.Fatal("not configured must be permanent and must not stop the worker")
	}
}

// Spec 02 §14.7: a bounce to an account's address runs the hook in the
// finalizing transaction, for a queued row and for a SendNow code alike; a
// bounce with no account runs nothing.
func TestABounceRunsTheHook(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUserWithoutKeys(t, pool)
	fake := &mail.Fake{Err: mail.ErrBounced}
	q := New(pool, fake, fixedTagger{})
	q.Register("test", TestRenderer)
	var hooked []Row
	q.Bounced = func(_ context.Context, _ pgx.Tx, r Row) error { hooked = append(hooked, r); return nil }

	id := enqueue(t, pool, q, Enqueue{Kind: "test", To: "a@example.com", UserID: &user})
	_, _ = q.Drain(bg)
	if st, _, _, _ := row(t, pool, id); st != "bounced" || len(hooked) != 1 || *hooked[0].UserID != user {
		t.Fatalf("queued: status %s, hook %+v", st, hooked)
	}
	_ = q.SendNow(bg, Enqueue{Kind: "code", To: "a@example.com", UserID: &user, Params: map[string]any{"purpose": "email_verify"}},
		func() (mail.Message, error) { return mail.Message{Subject: "s", Text: "t"}, nil })
	if len(hooked) != 2 {
		t.Fatalf("SendNow: the hook ran %d times", len(hooked))
	}
	_ = q.SendNow(bg, Enqueue{Kind: "code", To: "b@example.com", Params: map[string]any{"purpose": "signup"}},
		func() (mail.Message, error) { return mail.Message{Subject: "s", Text: "t"}, nil })
	if len(hooked) != 2 {
		t.Fatal("a bounce with no account ran the hook")
	}
}

// SendNow writes the row before the send, keeps no secret in it, and makes
// one attempt: a transient failure is final.
func TestSendNowLogsTheSendAndNeverTheSecret(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := New(pool, fake, fixedTagger{})
	if err := q.SendNow(bg, Enqueue{Kind: "code", To: "m@example.com", Params: map[string]any{"purpose": "signup"}},
		func() (mail.Message, error) { return mail.Code("m@example.com", "signup", "424242", "") }); err != nil {
		t.Fatal(err)
	}
	var status, params string
	if err := pool.QueryRow(bg, `SELECT status, params::text FROM mail_log`).Scan(&status, &params); err != nil {
		t.Fatal(err)
	}
	if status != "sent" || strings.Contains(params, "424242") {
		t.Fatalf("row %s %s", status, params)
	}
	fake.Err = errors.New("upstream")
	_ = q.SendNow(bg, Enqueue{Kind: "code", To: "m@example.com", Params: map[string]any{"purpose": "signup"}},
		func() (mail.Message, error) { return mail.Message{}, nil })
	var n int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE status = 'failed'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("a failed SendNow is not final: %d %v", n, err)
	}
}
