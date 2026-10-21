package invites

import (
	"bytes"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

type testTagger struct{}

func (testTagger) EmailTag(s string) []byte {
	b := bytes.Repeat([]byte{7}, 32)
	copy(b, s)
	return b
}

func unsentQueue(pool *pgxpool.Pool, fake *mail.Fake) *mailq.Queue {
	q := mailq.New(pool, fake, testTagger{})
	q.Register("invite", Renderer{WebBase: "https://hasala.app", ManualTestFlight: true})
	q.Unsent = MailUnsent(nil)
	return q
}

func approved(t *testing.T, pool *pgxpool.Pool, q *mailq.Queue, addr string) (entry, invite uuid.UUID) {
	t.Helper()
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at) VALUES ($1, $2, 'confirmed', 'web', now(), now(), now()) RETURNING id`,
		testTagger{}.EmailTag(addr), addr).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		var err error
		invite, err = ApproveEntry(bg, tx, q, entry, "", DefaultTTL)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return entry, invite
}

func inviteState(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) string {
	t.Helper()
	var s string
	if err := pool.QueryRow(bg, `SELECT state FROM invite_codes WHERE id = $1`, id).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func assertEntryGone(t *testing.T, pool *pgxpool.Pool, entry uuid.UUID, addr string) {
	t.Helper()
	var n int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM waitlist_entries WHERE id = $1 OR email_norm = $2`, entry, addr).
		Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("the entry of an unsent invite is still kept")
	}
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE recipient = $1`, addr).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("%d mail rows still hold the address", n)
	}
}

func assertEntryConfirmed(t *testing.T, pool *pgxpool.Pool, entry uuid.UUID, addr string) {
	t.Helper()
	var (
		state string
		email *string
	)
	if err := pool.QueryRow(bg, `SELECT state, email_norm FROM waitlist_entries WHERE id = $1`, entry).
		Scan(&state, &email); err != nil {
		t.Fatal(err)
	}
	if state != "confirmed" || email == nil || *email != addr {
		t.Fatalf("entry %s %v, want confirmed with its address", state, email)
	}
}

func assertEntryInvited(t *testing.T, pool *pgxpool.Pool, entry uuid.UUID, addr string) {
	t.Helper()
	var (
		state string
		email *string
	)
	if err := pool.QueryRow(bg, `SELECT state, email_norm FROM waitlist_entries WHERE id = $1`, entry).
		Scan(&state, &email); err != nil {
		t.Fatal(err)
	}
	if state != "invited" || email == nil || *email != addr {
		t.Fatalf("entry %s %v, want invited with its address", state, email)
	}
}

func TestAnUnsentInviteEmailRevokesTheInvite(t *testing.T) {
	for _, c := range []struct {
		name   string
		err    error
		status string
		back   bool
	}{
		{"bounced", mail.ErrBounced, "bounced", false},
		{"failed permanently", mail.ErrPermanent, "failed", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			q := unsentQueue(pool, &mail.Fake{Err: c.err})
			const addr = "unsent@example.com"
			entry, invite := approved(t, pool, q, addr)
			if _, err := q.Drain(bg); err != nil {
				t.Fatal(err)
			}
			if s := inviteState(t, pool, invite); s != "revoked" {
				t.Fatalf("invite %s, want revoked", s)
			}
			if c.back {
				assertEntryConfirmed(t, pool, entry, addr)
				return
			}
			assertEntryGone(t, pool, entry, addr)
			var (
				status string
				linked *uuid.UUID
			)
			if err := pool.QueryRow(bg, `SELECT status, waitlist_entry_id FROM mail_log WHERE invite_id = $1`, invite).
				Scan(&status, &linked); err != nil {
				t.Fatal(err)
			}
			if status != c.status || linked != nil {
				t.Fatalf("mail row %s entry %v", status, linked)
			}
		})
	}
}

func TestAnUnsentCLIInviteEmailRevokesTheInvite(t *testing.T) {
	pool := pgtest.New(t)
	q := unsentQueue(pool, &mail.Fake{Err: mail.ErrBounced})
	var invite uuid.UUID
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		var err error
		invite, err = EnqueueEmailed(bg, tx, mailq.New(pool, nil, nil), "cli@example.com", "", DefaultTTL)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if s := inviteState(t, pool, invite); s != "revoked" {
		t.Fatalf("invite %s, want revoked", s)
	}
}

func TestTheMailSweepOfAQueuedInviteEmailRevokesTheInvite(t *testing.T) {
	pool := pgtest.New(t)
	q := unsentQueue(pool, &mail.Fake{})
	const addr = "swept@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := pool.Exec(bg, `UPDATE mail_log SET created_at = now() - interval '31 days' WHERE invite_id = $1`,
		invite); err != nil {
		t.Fatal(err)
	}
	if msg, err := q.Sweep(bg); err != nil || msg == "" {
		t.Fatalf("sweep %q %v", msg, err)
	}
	if s := inviteState(t, pool, invite); s != "revoked" {
		t.Fatalf("invite %s, want revoked", s)
	}
	assertEntryConfirmed(t, pool, entry, addr)
}

func TestTheInviteSweepCatchesAStaleQueuedInvite(t *testing.T) {
	for _, c := range []struct {
		name, sql string
	}{
		{"mail row gone", `DELETE FROM mail_log WHERE invite_id = $1`},
		{"mail row final unsent", `UPDATE mail_log SET status = 'failed', next_attempt_at = NULL, final_at = now(),
			error = 'x' WHERE invite_id = $1`},
	} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			q := unsentQueue(pool, &mail.Fake{})
			const addr = "stale@example.com"
			entry, invite := approved(t, pool, q, addr)
			if _, err := pool.Exec(bg, c.sql, invite); err != nil {
				t.Fatal(err)
			}
			if _, err := Sweep(bg, pool, nil); err != nil {
				t.Fatal(err)
			}
			if s := inviteState(t, pool, invite); s != "queued" {
				t.Fatalf("a fresh queued invite was swept: %s", s)
			}
			if _, err := pool.Exec(bg, `UPDATE invite_codes SET created_at = now() - interval '2 hours' WHERE id = $1`,
				invite); err != nil {
				t.Fatal(err)
			}
			if msg, err := Sweep(bg, pool, nil); err != nil || msg == "" {
				t.Fatalf("sweep %q %v", msg, err)
			}
			if s := inviteState(t, pool, invite); s != "revoked" {
				t.Fatalf("invite %s, want revoked", s)
			}
			assertEntryConfirmed(t, pool, entry, addr)
		})
	}
}

func TestTheInviteSweepLeavesAQueuedInviteWithMailToSend(t *testing.T) {
	pool := pgtest.New(t)
	q := unsentQueue(pool, &mail.Fake{})
	const addr = "waiting@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET created_at = now() - interval '2 days' WHERE id = $1`,
		invite); err != nil {
		t.Fatal(err)
	}
	if _, err := Sweep(bg, pool, nil); err != nil {
		t.Fatal(err)
	}
	if s := inviteState(t, pool, invite); s != "queued" {
		t.Fatalf("invite %s, want queued", s)
	}
	assertEntryInvited(t, pool, entry, addr)
}

func TestASentInviteIsNotTouched(t *testing.T) {
	pool := pgtest.New(t)
	fake := &mail.Fake{}
	q := unsentQueue(pool, fake)
	const addr = "sent@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if len(fake.Sent()) != 1 {
		t.Fatalf("sent %d", len(fake.Sent()))
	}
	if _, err := pool.Exec(bg, `UPDATE invite_codes SET created_at = now() - interval '2 days' WHERE id = $1`,
		invite); err != nil {
		t.Fatal(err)
	}
	fake.Err = mail.ErrBounced
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return Resend(bg, tx, q, invite) }); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	if _, err := Sweep(bg, pool, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Sweep(bg); err != nil {
		t.Fatal(err)
	}
	if s := inviteState(t, pool, invite); s != "active" {
		t.Fatalf("invite %s, want active", s)
	}
	assertEntryInvited(t, pool, entry, addr)
}

func TestAnUnsentEmailDoesNotRevokeAnInviteBeingResent(t *testing.T) {
	pool := pgtest.New(t)
	q := unsentQueue(pool, &mail.Fake{})
	const addr = "resent@example.com"
	entry, invite := approved(t, pool, q, addr)
	if _, err := pool.Exec(bg, `UPDATE mail_log SET status = 'failed', next_attempt_at = NULL, final_at = now(),
		error = 'x' WHERE invite_id = $1`, invite); err != nil {
		t.Fatal(err)
	}
	resend, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resend.Rollback(bg) }()
	if err := Resend(bg, resend, q, invite); err != nil {
		t.Fatal(err)
	}
	type result struct {
		closed bool
		err    error
	}
	done := make(chan result, 1)
	go func() {
		tx, err := pool.Begin(bg)
		if err != nil {
			done <- result{err: err}
			return
		}
		defer func() { _ = tx.Rollback(bg) }()
		closed, _, err := closeUnsentTx(bg, tx, invite, []string{"queued", "active"})
		if err == nil {
			err = tx.Commit(bg)
		}
		done <- result{closed, err}
	}()
	for {
		var waiting bool
		if err := pool.QueryRow(bg, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock'
			AND datname = current_database())`).
			Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case r := <-done:
			t.Fatalf("the unsent hook did not wait for the resend: %+v", r)
		case <-time.After(10 * time.Millisecond):
		}
	}
	if err := resend.Commit(bg); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || r.closed {
		t.Fatalf("closed %v err %v", r.closed, r.err)
	}
	if s := inviteState(t, pool, invite); s != "queued" {
		t.Fatalf("invite %s, want queued", s)
	}
	assertEntryInvited(t, pool, entry, addr)
}

func TestABouncedInviteRecordsTheDeletedEntryAndTheReplayDeletesItAgain(t *testing.T) {
	for _, c := range []struct {
		name, before string
		sweep        bool
	}{{"mail queue", "active", false}, {"invite sweep", "queued", true}} {
		t.Run(c.name, func(t *testing.T) {
			pool := pgtest.New(t)
			var recorded []purgeledger.Entry
			record := func(e purgeledger.Entry) { recorded = append(recorded, e) }
			q := unsentQueue(pool, &mail.Fake{Err: mail.ErrBounced})
			q.Unsent = MailUnsent(record)
			const addr = "bounce@example.com"
			entry, invite := approved(t, pool, q, addr)
			var saved string
			if err := pool.QueryRow(bg, `SELECT row_to_json(e)::text FROM waitlist_entries e WHERE id = $1`, entry).Scan(&saved); err != nil {
				t.Fatal(err)
			}
			if c.sweep {
				if _, err := pool.Exec(bg, `UPDATE mail_log SET status = 'bounced', next_attempt_at = NULL, final_at = now(), error = 'x'
				    WHERE invite_id = $1`, invite); err != nil {
					t.Fatal(err)
				}
				if _, err := pool.Exec(bg, `UPDATE invite_codes SET created_at = now() - interval '2 hours' WHERE id = $1`, invite); err != nil {
					t.Fatal(err)
				}
				if _, err := Sweep(bg, pool, record); err != nil {
					t.Fatal(err)
				}
			} else if _, err := q.Drain(bg); err != nil {
				t.Fatal(err)
			}
			assertEntryGone(t, pool, entry, addr)
			if len(recorded) != 1 || recorded[0].ID != entry || recorded[0].Kind != purgeledger.KindWaitlistUnsent ||
				time.Since(recorded[0].At) > time.Minute {
				t.Fatalf("recorded %+v, want the entry's id", recorded)
			}

			if _, err := pool.Exec(bg, `INSERT INTO waitlist_entries SELECT * FROM json_populate_record(NULL::waitlist_entries, $1::json)`,
				saved); err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(bg, `UPDATE invite_codes SET state = $2, closed_at = NULL, waitlist_entry_id = $3 WHERE id = $1`,
				invite, c.before, entry); err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(bg, `UPDATE mail_log SET waitlist_entry_id = $2, recipient = $3 WHERE invite_id = $1`,
				invite, entry, addr); err != nil {
				t.Fatal(err)
			}
			n, err := waitlist.ReapplyUnsent(bg, pool, append(recorded, purgeledger.Entry{ID: entry, At: time.Now(), Kind: purgeledger.KindPassword}))
			if err != nil || n != 1 {
				t.Fatalf("reapply %d %v, want 1", n, err)
			}
			assertEntryGone(t, pool, entry, addr)
			if s := inviteState(t, pool, invite); s != "revoked" {
				t.Fatalf("the restored invite is %s, want revoked", s)
			}
			var rows int
			if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE invite_id = $1 AND waitlist_entry_id IS NULL`, invite).
				Scan(&rows); err != nil || rows != 1 {
				t.Fatalf("%d detached invite mail rows (%v), want 1", rows, err)
			}
			if n, err := waitlist.ReapplyUnsent(bg, pool, recorded); err != nil || n != 0 {
				t.Fatalf("a second replay %d %v", n, err)
			}
			if n, err := waitlist.ReapplyLeaves(bg, pool, recorded); err != nil || n != 0 {
				t.Fatalf("the leave replay took an unsent deletion: %d %v", n, err)
			}
		})
	}
}

func TestAnInviteWhoseEntryGoesBackToTheListRecordsNothing(t *testing.T) {
	pool := pgtest.New(t)
	var recorded []purgeledger.Entry
	q := unsentQueue(pool, &mail.Fake{Err: mail.ErrPermanent})
	q.Unsent = MailUnsent(func(e purgeledger.Entry) { recorded = append(recorded, e) })
	const addr = "back@example.com"
	entry, _ := approved(t, pool, q, addr)
	if _, err := q.Drain(bg); err != nil {
		t.Fatal(err)
	}
	assertEntryConfirmed(t, pool, entry, addr)
	if len(recorded) != 0 {
		t.Fatalf("recorded %+v for an entry that stayed", recorded)
	}
}
