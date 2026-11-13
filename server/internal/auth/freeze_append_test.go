package auth

import (
	"testing"
	"time"
)

func TestAFreezeLinkWaitsForAnAppendAlreadyInFlight(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	f.fake.Reset()
	if _, err := m.loginPassword(m.s, nil); err != nil {
		t.Fatal(err)
	}
	tok := f.freezeToken(m.addr)
	f.clock.advance(time.Minute)

	inFlight, err := f.pool.Begin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = inFlight.Rollback(bgctx) }()
	if _, err := inFlight.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := f.acct.FreezeByLink(bgctx, tok)
		done <- err
	}()

	deadline := time.Now().Add(30 * time.Second)
	for f.count(`SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'`) == 0 {
		select {
		case err := <-done:
			t.Fatalf("the freeze finished while an append held the account: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("the freeze never waited on the account row")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 0 {
		t.Fatal("the account froze while an append held it")
	}
	if err := inFlight.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatalf("the freeze after the append: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 1 {
		t.Fatal("the freeze did not land after the append finished")
	}
}
