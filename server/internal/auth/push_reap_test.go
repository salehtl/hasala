package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestTheSweepForgetsThePushTokensOfEndedSessions(t *testing.T) {
	pool := pgtest.New(t)
	c := newClock()
	sessions := &Sessions{Pool: pool, TTL: time.Hour, Max: 24 * time.Hour, Now: c.now}
	u := newTestUser(t, pool)

	plant := func(name string) (string, string) {
		t.Helper()
		writer := plantWriter(t, pool, u)
		sess, err := sessions.Issue(bgctx, u)
		if err != nil {
			t.Fatal(err)
		}
		registerPushToken(t, pool, u, writer, sess, "synthetic-device-"+name)
		return writer, sess
	}
	tokenOf := func(writer string) int {
		t.Helper()
		return countRows(t, pool, `SELECT count(*) FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, u, writer)
	}

	idleWriter, idleSess := plant("idle")
	c.advance(30 * time.Minute)
	liveWriter, liveSess := plant("live")
	expiredWriter, expiredSess := plant("expired")
	revokedWriter, revokedSess := plant("revoked")
	if _, err := pool.Exec(bgctx, `UPDATE sessions SET expires_at = $2 WHERE token_hash = $1`,
		SessionHash(expiredSess), c.now().Add(10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bgctx, `UPDATE sessions SET revoked_at = $2, revoked_reason = 'logout' WHERE token_hash = $1`,
		SessionHash(revokedSess), c.now()); err != nil {
		t.Fatal(err)
	}
	c.advance(30 * time.Minute)

	if _, err := sessions.Info(bgctx, idleSess); !errors.Is(err, ErrSessionIdle) {
		t.Fatalf("the idle session answers %v, want it idle at this instant", err)
	}
	if _, err := sessions.ReapSessions(bgctx); err != nil {
		t.Fatal(err)
	}

	for name, writer := range map[string]string{"idle": idleWriter, "expired": expiredWriter, "revoked": revokedWriter} {
		if n := tokenOf(writer); n != 0 {
			t.Errorf("the %s session's device still has %d push token(s)", name, n)
		}
	}
	if n := tokenOf(liveWriter); n != 1 {
		t.Errorf("the live session's device has %d push token(s), want 1", n)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM sessions WHERE user_id = $1`, u); n != 4 {
		t.Errorf("%d sessions left, want all 4 still held for the reap window", n)
	}
	if _, err := sessions.Info(bgctx, liveSess); err != nil {
		t.Errorf("the live session answers %v", err)
	}
}
