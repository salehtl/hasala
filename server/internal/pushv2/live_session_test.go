package pushv2

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

const (
	liveWriter    = "ios-11111111-1111-4111-8111-111111111111"
	expiredWriter = "ios-22222222-2222-4222-8222-222222222222"
	idleWriter    = "ios-33333333-3333-4333-8333-333333333333"
	revokedWriter = "ios-44444444-4444-4444-8444-444444444444"
)

func endSession(t *testing.T, pool *pgxpool.Pool, writer, set string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(bg, `UPDATE sessions SET `+set+` WHERE token_hash = sha256($1::bytea)`,
		append([]any{[]byte(writer)}, args...)...); err != nil {
		t.Fatal(err)
	}
}

func sessionFixture(t *testing.T) (*pgxpool.Pool, uuid.UUID, *clock) {
	t.Helper()
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	c := &clock{t: time.Now()}
	for i, w := range []string{liveWriter, expiredWriter, idleWriter, revokedWriter} {
		registerToken(t, pool, u, w, byte(i+1))
	}
	endSession(t, pool, expiredWriter, `created_at = $3, last_used_at = $3, expires_at = $2`, c.t.Add(-time.Minute), c.t.Add(-time.Hour))
	endSession(t, pool, idleWriter, `last_used_at = $2, created_at = $2`, c.t.Add(-2*time.Hour))
	endSession(t, pool, revokedWriter, `revoked_at = $2, revoked_reason = 'logout'`, c.t.Add(-time.Minute))
	return pool, u, c
}

func TestAWakeReachesOnlyTokensOfLiveSessions(t *testing.T) {
	pool, u, c := sessionFixture(t)
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	d.SessionIdle = time.Hour

	d.run(bg, job{user: u, others: true, r: ReasonSecurity, resolve: true})
	if s.count() != 1 || s.sent[0].TokenHex != tokenHex(1) {
		t.Fatalf("WakeOthers reached %v, want only the live session's token", s.sent)
	}
	for _, w := range []string{expiredWriter, idleWriter, revokedWriter} {
		confirmed := false
		d.run(bg, job{user: u, writer: w, r: ReasonSecurity, resolve: true, sent: func() { confirmed = true }})
		if s.count() != 1 || confirmed {
			t.Fatalf("WakeWriter(%s) reached %v, confirmed %v", w, s.sent, confirmed)
		}
	}
	var rows int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM apns_tokens WHERE user_id = $1`, u).Scan(&rows); err != nil || rows != 4 {
		t.Fatalf("%d rows (%v): skipping a wake must not delete a row", rows, err)
	}
}

func TestATokenCollectedForADeletionIsStillWoken(t *testing.T) {
	pool, u, c := sessionFixture(t)
	collected, err := CollectTokens(bg, pool, u, "")
	if err != nil || len(collected) != 4 {
		t.Fatalf("collected %d tokens (%v), want every row", len(collected), err)
	}
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	d.SessionIdle = time.Hour
	d.run(bg, job{tokens: collected, r: ReasonSecurity})
	if s.count() != 4 {
		t.Fatalf("%d of 4 collected tokens woken", s.count())
	}
}

func TestATrailingWakeSkipsASessionThatEndedInTheWindow(t *testing.T) {
	pool, u, c := sessionFixture(t)
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	d.SessionIdle = 24 * time.Hour
	d.run(bg, job{user: u, writer: idleWriter, r: ReasonMail, resolve: true})
	d.run(bg, job{user: u, writer: idleWriter, r: ReasonMail, resolve: true})
	if s.count() != 1 {
		t.Fatalf("%d leading sends, want 1", s.count())
	}
	endSession(t, pool, idleWriter, `expires_at = $2`, c.t.Add(time.Second))
	c.add(mailWindow + time.Second)
	d.Flush(bg)
	if s.count() != 1 {
		t.Fatalf("a trailing wake reached an ended session: %v", s.sent)
	}
	if d.Stats.Dropped[ReasonMail].Load() != 1 {
		t.Fatalf("dropped %d, want 1", d.Stats.Dropped[ReasonMail].Load())
	}
}

func TestAnUnsetIdleWindowChecksOnlyExpiryAndRevocation(t *testing.T) {
	pool, u, c := sessionFixture(t)
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	d.run(bg, job{user: u, others: true, r: ReasonSecurity, resolve: true})
	if s.count() != 2 {
		t.Fatalf("%d sends, want the live and the idle token: %v", s.count(), s.sent)
	}
}
