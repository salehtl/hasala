package invites

import (
	"bytes"
	"encoding/base64"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

var inviteLink = regexp.MustCompile(`/i/([A-Z2-7]{24})#([A-Za-z0-9_-]{43})`)

func linkOf(t *testing.T, m mail.Message) (string, []byte) {
	t.Helper()
	got := inviteLink.FindStringSubmatch(m.Text)
	if got == nil {
		t.Fatal("no invite link in the email")
	}
	key, err := base64.RawURLEncoding.DecodeString(got[2])
	if err != nil {
		t.Fatal(err)
	}
	return got[1], key
}

func mintCount(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) int {
	t.Helper()
	var n int16
	if err := pool.QueryRow(bg, `SELECT mint_count FROM invite_codes WHERE id = $1`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return int(n)
}

func expiresAt(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) time.Time {
	t.Helper()
	var at time.Time
	if err := pool.QueryRow(bg, `SELECT expires_at FROM invite_codes WHERE id = $1`, id).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func TestARetriedInviteEmailCarriesTheSameCode(t *testing.T) {
	pool := pgtest.New(t)
	minter, err := authkeys.NewEmailTagger(bytes.Repeat([]byte{3}, authkeys.KeySize))
	if err != nil {
		t.Fatal(err)
	}
	var attempts []mail.Message
	fake := &mail.Fake{ErrFor: func(m mail.Message) error {
		attempts = append(attempts, m)
		if len(attempts) == 1 {
			return errors.New("provider timeout")
		}
		return nil
	}}
	q := mailq.New(pool, fake, testTagger{})
	q.Register("invite", Renderer{WebBase: "https://hasala.app", ManualTestFlight: true, Minter: minter})
	q.Unsent = MailUnsent(nil, nil)
	const addr = "retry@example.com"
	_, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	until := expiresAt(t, pool, invite)
	if _, err := pool.Exec(bg, `UPDATE mail_log SET next_attempt_at = now() WHERE invite_id = $1 AND status = 'queued'`,
		invite); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 2 || len(fake.Sent()) != 1 {
		t.Fatalf("%d attempts, %d sent", len(attempts), len(fake.Sent()))
	}
	firstCode, firstKey := linkOf(t, attempts[0])
	secondCode, secondKey := linkOf(t, attempts[1])
	if firstCode != secondCode || !bytes.Equal(firstKey, secondKey) {
		t.Fatal("the retry minted a new code")
	}
	if n := mintCount(t, pool, invite); n != 1 {
		t.Fatalf("mint_count %d, want 1", n)
	}
	if !expiresAt(t, pool, invite).Equal(until) {
		t.Fatal("the retry moved the expiry")
	}
	r, err := Resolve(bg, pool, firstCode, firstKey, testTagger{}.EmailTag(addr), time.Now())
	if err != nil || r.InviteID != invite || !r.Proven {
		t.Fatalf("the first email's code: %+v %v", r, err)
	}

	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return Resend(bg, tx, q, invite) }); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 3 {
		t.Fatalf("%d attempts", len(attempts))
	}
	if code, _ := linkOf(t, attempts[2]); code == firstCode {
		t.Fatal("a resend kept the old code")
	}
	if n := mintCount(t, pool, invite); n != 2 {
		t.Fatalf("mint_count %d, want 2", n)
	}
}

func TestARetryOfAReplacedInviteEmailLeavesTheNewerCodeLive(t *testing.T) {
	pool := pgtest.New(t)
	minter, err := authkeys.NewEmailTagger(bytes.Repeat([]byte{3}, authkeys.KeySize))
	if err != nil {
		t.Fatal(err)
	}
	var attempts []mail.Message
	fake := &mail.Fake{ErrFor: func(m mail.Message) error {
		attempts = append(attempts, m)
		if len(attempts) == 1 {
			return errors.New("provider timeout")
		}
		return nil
	}}
	q := mailq.New(pool, fake, testTagger{})
	q.Register("invite", Renderer{WebBase: "https://hasala.app", ManualTestFlight: true, Minter: minter})
	q.Unsent = MailUnsent(nil, nil)
	const addr = "replaced@example.com"
	_, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return Resend(bg, tx, q, invite) }); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 2 {
		t.Fatalf("%d attempts before the retry, want 2", len(attempts))
	}
	olderCode, olderKey := linkOf(t, attempts[0])
	newerCode, newerKey := linkOf(t, attempts[1])
	if olderCode == newerCode {
		t.Fatal("the resend kept the old code")
	}
	until := expiresAt(t, pool, invite)
	if _, err := pool.Exec(bg, `UPDATE mail_log SET next_attempt_at = now() WHERE invite_id = $1 AND status = 'queued'`,
		invite); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 2 {
		t.Fatalf("%d attempts: the replaced email was sent again", len(attempts))
	}
	if n := mintCount(t, pool, invite); n != 2 {
		t.Fatalf("mint_count %d, want 2", n)
	}
	if !expiresAt(t, pool, invite).Equal(until) {
		t.Fatal("the replaced email moved the expiry")
	}
	var failed, sent int
	if err := pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE status = 'failed'), count(*) FILTER (WHERE status = 'sent')
		FROM mail_log WHERE invite_id = $1`, invite).Scan(&failed, &sent); err != nil {
		t.Fatal(err)
	}
	if failed != 1 || sent != 1 {
		t.Fatalf("%d failed and %d sent, want one of each", failed, sent)
	}
	tag := testTagger{}.EmailTag(addr)
	r, err := Resolve(bg, pool, newerCode, newerKey, tag, time.Now())
	if err != nil || r.InviteID != invite || !r.Proven {
		t.Fatalf("the newer email's code: %+v %v", r, err)
	}
	if _, err := Resolve(bg, pool, olderCode, olderKey, tag, time.Now()); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("the replaced email's code: %v", err)
	}
	if s := inviteState(t, pool, invite); s != "active" {
		t.Fatalf("invite %s, want active", s)
	}
}

func TestResendRefusesACLIInviteWhoseAddressIsGone(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := unsentQueue(pool, fake)
	var invite uuid.UUID
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		var err error
		invite, err = EnqueueEmailed(bg, tx, mailq.New(pool, nil, nil), "later@example.com", "", MaxTTL)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	resend := func() error {
		return pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return Resend(bg, tx, q, invite) })
	}
	if err := resend(); err != nil {
		t.Fatalf("a resend within 7 days: %v", err)
	}
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 2 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	if _, err := pool.Exec(bg, `UPDATE mail_log SET final_at = now() - interval '8 days' WHERE invite_id = $1`,
		invite); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Sweep(bg); err != nil {
		t.Fatal(err)
	}
	if err := resend(); !errors.Is(err, ErrAddressGone) {
		t.Fatalf("resend after the address went: %v", err)
	}
	if s := inviteState(t, pool, invite); s != "active" {
		t.Fatalf("invite %s, want active", s)
	}
	var queued int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE invite_id = $1 AND status = 'queued'`, invite).
		Scan(&queued); err != nil || queued != 0 {
		t.Fatalf("%d queued rows, %v", queued, err)
	}
}

func mintingQueue(t *testing.T, pool *pgxpool.Pool, fake *mail.Fake) *mailq.Queue {
	t.Helper()
	minter, err := authkeys.NewEmailTagger(bytes.Repeat([]byte{3}, authkeys.KeySize))
	if err != nil {
		t.Fatal(err)
	}
	q := mailq.New(pool, fake, testTagger{})
	q.Register("invite", Renderer{WebBase: "https://hasala.app", ManualTestFlight: true, Minter: minter})
	q.Unsent = MailUnsent(nil)
	return q
}

func resendNow(pool *pgxpool.Pool, q *mailq.Queue, invite uuid.UUID) error {
	return pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return Resend(bg, tx, q, invite) })
}

func lapse(t *testing.T, pool *pgxpool.Pool, invite uuid.UUID) time.Time {
	t.Helper()
	var at time.Time
	if err := pool.QueryRow(bg, `UPDATE invite_codes SET minted_at = now() - interval '15 days', expires_at = now() - interval '1 hour'
		WHERE id = $1 AND state = 'active' RETURNING expires_at`, invite).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func retryNow(t *testing.T, pool *pgxpool.Pool, invite uuid.UUID) {
	t.Helper()
	if _, err := pool.Exec(bg, `UPDATE mail_log SET next_attempt_at = now() WHERE invite_id = $1 AND status = 'queued'`,
		invite); err != nil {
		t.Fatal(err)
	}
}

func TestResendRefusesAnInvitePastItsExpiryBeforeTheSweep(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mintingQueue(t, pool, fake)
	const addr = "lapsed@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	until := lapse(t, pool, invite)
	if err := resendNow(pool, q, invite); !errors.Is(err, ErrNoSuchInvite) {
		t.Fatalf("resend of a lapsed invite: %v", err)
	}
	var queued int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE invite_id = $1 AND status = 'queued'`, invite).
		Scan(&queued); err != nil || queued != 0 {
		t.Fatalf("%d queued rows, %v", queued, err)
	}
	if !expiresAt(t, pool, invite).Equal(until) {
		t.Fatal("the refused resend moved the expiry")
	}
	if _, err := Sweep(bg, pool, nil); err != nil {
		t.Fatal(err)
	}
	if s := inviteState(t, pool, invite); s != "expired" {
		t.Fatalf("invite %s, want expired", s)
	}
	assertEntryConfirmed(t, pool, entry, addr)
}

func TestAnEmailAlreadyQueuedDoesNotReviveALapsedInvite(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mintingQueue(t, pool, fake)
	const addr = "queued-resend@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	if err := resendNow(pool, q, invite); err != nil {
		t.Fatal(err)
	}
	until := lapse(t, pool, invite)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(fake.Sent()) != 1 {
		t.Fatalf("%d sent: the queued resend went out for a lapsed invite", len(fake.Sent()))
	}
	if !expiresAt(t, pool, invite).Equal(until) {
		t.Fatal("the queued resend moved the expiry")
	}
	if n := mintCount(t, pool, invite); n != 1 {
		t.Fatalf("mint_count %d, want 1", n)
	}
	if _, err := Sweep(bg, pool, nil); err != nil {
		t.Fatal(err)
	}
	if s := inviteState(t, pool, invite); s != "expired" {
		t.Fatalf("invite %s, want expired", s)
	}
	assertEntryConfirmed(t, pool, entry, addr)
}

func TestARetryOfAnEmailForALapsedInviteIsNotSent(t *testing.T) {
	pool := pgtest.New(t)
	attempts := 0
	fake := &mail.Fake{ErrFor: func(mail.Message) error {
		attempts++
		return errors.New("provider timeout")
	}}
	q := mintingQueue(t, pool, fake)
	const addr = "lapsed-retry@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil || attempts != 1 {
		t.Fatalf("%d attempts, %v", attempts, err)
	}
	until := lapse(t, pool, invite)
	retryNow(t, pool, invite)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if attempts != 1 {
		t.Fatalf("%d attempts: the retry went out for a lapsed invite", attempts)
	}
	if !expiresAt(t, pool, invite).Equal(until) {
		t.Fatal("the retry moved the expiry")
	}
	if s := inviteState(t, pool, invite); s != "revoked" {
		t.Fatalf("invite %s, want revoked", s)
	}
	assertEntryConfirmed(t, pool, entry, addr)
}

func TestResendStopsAtTheMintLimit(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mintingQueue(t, pool, fake)
	const addr = "limit@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	code, key := linkOf(t, fake.Sent()[0])
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET mint_count = $2 WHERE id = $1`, invite, MaxMints); err != nil {
		t.Fatal(err)
	}
	if err := resendNow(pool, q, invite); !errors.Is(err, ErrMintLimit) {
		t.Fatalf("resend at the limit: %v", err)
	}
	var queued int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE invite_id = $1 AND status = 'queued'`, invite).
		Scan(&queued); err != nil || queued != 0 {
		t.Fatalf("%d queued rows, %v", queued, err)
	}
	r, err := Resolve(bg, pool, code, key, testTagger{}.EmailTag(addr), time.Now())
	if err != nil || r.InviteID != invite || !r.Proven {
		t.Fatalf("the delivered code after the refusal: %+v %v", r, err)
	}
	if s := inviteState(t, pool, invite); s != "active" {
		t.Fatalf("invite %s, want active", s)
	}
	assertEntryInvited(t, pool, entry, addr)
}

func TestTheLastMintUnderTheLimitStillSends(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mintingQueue(t, pool, fake)
	_, invite := approved(t, pool, q, "last@example.com")
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET mint_count = $2 WHERE id = $1`, invite, MaxMints-1); err != nil {
		t.Fatal(err)
	}
	if err := resendNow(pool, q, invite); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 2 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	if n := mintCount(t, pool, invite); n != MaxMints {
		t.Fatalf("mint_count %d, want %d", n, MaxMints)
	}
}

func TestAQueuedEmailAtTheMintLimitNamesTheLimitAndKeepsTheCode(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := mintingQueue(t, pool, fake)
	const addr = "queued-limit@example.com"
	_, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil || len(fake.Sent()) != 1 {
		t.Fatalf("sent %d, %v", len(fake.Sent()), err)
	}
	code, key := linkOf(t, fake.Sent()[0])
	if err := resendNow(pool, q, invite); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET mint_count = $2 WHERE id = $1`, invite, MaxMints); err != nil {
		t.Fatal(err)
	}
	row := mailq.Row{Kind: "invite", Recipient: addr, InviteID: &invite}
	if err := pool.QueryRow(bg, `SELECT max(id) FROM mail_log WHERE invite_id = $1`, invite).Scan(&row.ID); err != nil {
		t.Fatal(err)
	}
	minter, err := authkeys.NewEmailTagger(bytes.Repeat([]byte{3}, authkeys.KeySize))
	if err != nil {
		t.Fatal(err)
	}
	r := Renderer{WebBase: "https://hasala.app", ManualTestFlight: true, Minter: minter}
	err = pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		_, err := r.Render(bg, tx, row)
		return err
	})
	if !errors.Is(err, ErrMintLimit) {
		t.Fatalf("render at the limit: %v", err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(fake.Sent()) != 1 {
		t.Fatalf("%d sent", len(fake.Sent()))
	}
	got, err := Resolve(bg, pool, code, key, testTagger{}.EmailTag(addr), time.Now())
	if err != nil || got.InviteID != invite || !got.Proven {
		t.Fatalf("the delivered code after the failed render: %+v %v", got, err)
	}
	if s := inviteState(t, pool, invite); s != "active" {
		t.Fatalf("invite %s, want active", s)
	}
}

func TestARetryAtTheMintLimitStillCarriesItsCode(t *testing.T) {
	pool := pgtest.New(t)
	var attempts []mail.Message
	fake := &mail.Fake{ErrFor: func(m mail.Message) error {
		attempts = append(attempts, m)
		if len(attempts) == 1 {
			return errors.New("provider timeout")
		}
		return nil
	}}
	q := mintingQueue(t, pool, fake)
	_, invite := approved(t, pool, q, "retry-limit@example.com")
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET mint_count = $2 WHERE id = $1`, invite, MaxMints); err != nil {
		t.Fatal(err)
	}
	retryNow(t, pool, invite)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 2 || len(fake.Sent()) != 1 {
		t.Fatalf("%d attempts, %d sent", len(attempts), len(fake.Sent()))
	}
	first, _ := linkOf(t, attempts[0])
	second, _ := linkOf(t, attempts[1])
	if first != second {
		t.Fatal("the retry minted a new code")
	}
	if n := mintCount(t, pool, invite); n != MaxMints {
		t.Fatalf("mint_count %d, want %d", n, MaxMints)
	}
}

func TestARetryingEmailIsNotReplacedByANewerEmailThatFailed(t *testing.T) {
	for _, c := range []struct {
		name   string
		err    error
		status string
	}{
		{"failed", mail.ErrPermanent, "failed"},
		{"bounced", mail.ErrBounced, "bounced"},
	} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			var attempts []mail.Message
			fake := &mail.Fake{ErrFor: func(m mail.Message) error {
				attempts = append(attempts, m)
				switch len(attempts) {
				case 1:
					return errors.New("provider timeout")
				case 2:
					return c.err
				}
				return nil
			}}
			q := mintingQueue(t, pool, fake)
			const addr = "older-retry@example.com"
			entry, invite := approved(t, pool, q, addr)
			if _, err := q.Drain(bg); err != nil || len(attempts) != 1 {
				t.Fatalf("%d attempts, %v", len(attempts), err)
			}
			if err := resendNow(pool, q, invite); err != nil {
				t.Fatal(err)
			}
			if _, err := q.Drain(bg); err != nil || len(attempts) != 2 {
				t.Fatalf("%d attempts, %v", len(attempts), err)
			}
			var newer string
			if err := pool.QueryRow(bg, `SELECT status FROM mail_log WHERE invite_id = $1 ORDER BY id DESC LIMIT 1`, invite).
				Scan(&newer); err != nil || newer != c.status {
				t.Fatalf("the newer email is %s, %v", newer, err)
			}
			if s := inviteState(t, pool, invite); s != "active" {
				t.Fatalf("invite %s with an email still retrying, want active", s)
			}
			retryNow(t, pool, invite)
			if _, err := q.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if len(attempts) != 3 || len(fake.Sent()) != 1 {
				t.Fatalf("%d attempts, %d sent: the older email was discarded", len(attempts), len(fake.Sent()))
			}
			if s := inviteState(t, pool, invite); s != "active" {
				t.Fatalf("invite %s, want active", s)
			}
			assertEntryInvited(t, pool, entry, addr)
			code, key := linkOf(t, attempts[2])
			r, err := Resolve(bg, pool, code, key, testTagger{}.EmailTag(addr), time.Now())
			if err != nil || r.InviteID != invite || !r.Proven {
				t.Fatalf("the delivered code: %+v %v", r, err)
			}
			newerCode, newerKey := linkOf(t, attempts[1])
			if _, err := Resolve(bg, pool, newerCode, newerKey, testTagger{}.EmailTag(addr), time.Now()); !errors.Is(err, ErrNotInvited) {
				t.Fatalf("the undelivered code: %v", err)
			}
		})
	}
}

func TestARetryingEmailStaysReplacedWhileANewerEmailCanStillGo(t *testing.T) {
	for _, status := range []string{"queued", "sending"} {
		t.Run(status, func(t *testing.T) {
			pool := pgtest.New(t)
			attempts := 0
			fake := &mail.Fake{ErrFor: func(mail.Message) error {
				attempts++
				return errors.New("provider timeout")
			}}
			q := mintingQueue(t, pool, fake)
			_, invite := approved(t, pool, q, "both@example.com")
			if _, err := q.Drain(bg); err != nil || attempts != 1 {
				t.Fatalf("%d attempts, %v", attempts, err)
			}
			if err := resendNow(pool, q, invite); err != nil {
				t.Fatal(err)
			}
			var older int64
			if err := pool.QueryRow(bg, `SELECT min(id) FROM mail_log WHERE invite_id = $1`, invite).Scan(&older); err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(bg, `UPDATE mail_log SET status = $2, next_attempt_at = CASE WHEN $2 = 'queued' THEN now() END,
				lease_until = CASE WHEN $2 = 'sending' THEN now() + interval '1 minute' END
				WHERE invite_id = $1 AND id > $3`, invite, status, older); err != nil {
				t.Fatal(err)
			}
			r := Renderer{WebBase: "https://hasala.app", ManualTestFlight: true}
			row := mailq.Row{ID: older, Kind: "invite", Recipient: "both@example.com", InviteID: &invite}
			err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
				_, err := r.Render(bg, tx, row)
				return err
			})
			if !errors.Is(err, ErrStale) {
				t.Fatalf("render of the older email: %v", err)
			}
		})
	}
}
