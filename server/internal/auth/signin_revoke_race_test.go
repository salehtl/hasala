package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

func TestASessionIsNotMintedForAWriterAlreadyRevoked(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	if _, err := f.pool.Exec(bgctx, `UPDATE writers SET revoked_at = $3 WHERE user_id = $1 AND writer_id = $2`,
		m.user.UserID, m.device.WriterID, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.sessions.IssueTx(bgctx, f.pool, Mint{UserID: m.user.UserID, MintedBy: MintedLogin, WriterID: m.device.WriterID}); !errors.Is(err, ErrWriterRevoked) {
		t.Fatalf("a session for a revoked writer: %v, want ErrWriterRevoked", err)
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL AND token_hash <> $3`,
		m.user.UserID, m.device.WriterID, SessionHash(m.token)); n != 0 {
		t.Fatalf("%d new live sessions on a revoked writer", n)
	}
}

func TestASignInThatRacesARevocationEndsWithNoLiveSession(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")

	tx, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, tx)
	if err := lockUser(bgctx, tx, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(bgctx, `UPDATE writers SET revoked_at = $3 WHERE user_id = $1 AND writer_id = $2`,
		m.user.UserID, m.device.WriterID, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(bgctx, `UPDATE sessions SET revoked_at = $3, revoked_reason = 'writer'
	        WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`, m.user.UserID, m.device.WriterID, f.clock.now()); err != nil {
		t.Fatal(err)
	}

	type result struct {
		in  SignedIn
		err error
	}
	done := make(chan result, 1)
	go func() {
		stx, err := pgtx.BeginReadCommitted(bgctx, f.pool)
		if err != nil {
			done <- result{err: err}
			return
		}
		defer pgtx.Rollback(bgctx, stx)
		st, err := readAccount(bgctx, stx, m.user.UserID, true)
		if err != nil {
			done <- result{err: err}
			return
		}
		in, err := f.acct.signInTx(bgctx, stx, st, MintedLogin, MethodPasskey, nil, m.device.WriterID)
		if err == nil {
			err = stx.Commit(bgctx)
		}
		done <- result{in, err}
	}()
	waitForLockWait(t, f.count)
	if err := tx.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if !errors.Is(r.err, ErrWriterRevoked) {
		t.Fatalf("a sign-in that lost the race: %v, want ErrWriterRevoked", r.err)
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
		m.user.UserID, m.device.WriterID); n != 0 {
		t.Fatalf("%d live sessions on the revoked writer", n)
	}
}

func TestARevocationWaitsForASignInThatGotThereFirst(t *testing.T) {
	f := newKeyFixture(t)
	target := authtest.NewDevice(t)
	f.enrol(target)

	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(target.WriterID))
	rev := f.revocation(target.WriterID, f.device, 0, make([]byte, 32), su)
	info := f.info(f.token)

	tx, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, tx)
	if _, err := readAccount(bgctx, tx, f.user, true); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- f.writers.Revoke(bgctx, f.user, info, rev) }()
	waitForLockWait(t, f.count)

	minted, err := f.sessions.IssueTx(bgctx, tx, Mint{UserID: f.user, MintedBy: MintedLogin, WriterID: target.WriterID})
	if err != nil {
		t.Fatalf("the sign-in that got there first: %v", err)
	}
	if err := tx.Commit(bgctx); err != nil {
		t.Fatalf("commit of the sign-in that got there first: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("the revocation behind it: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, minted.Token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("a session minted just before the revocation: %v, want ErrSessionRevoked", err)
	}
}

func waitForLockWait(t *testing.T, count func(string, ...any) int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if count(`SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()`) > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("nothing ever waited on the row lock")
}
