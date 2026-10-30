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
	q.Unsent = MailUnsent(nil)
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
	q.Unsent = MailUnsent(nil)
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
