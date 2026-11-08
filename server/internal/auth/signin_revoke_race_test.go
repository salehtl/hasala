package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
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
	if _, err := tx.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE`, m.user.UserID); err != nil {
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
	go func() {
		_, err := f.writers.Revoke(bgctx, f.user, info, rev)
		done <- err
	}()
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

func TestARevocationAndAPasskeyAddOnThatDeviceBothFinish(t *testing.T) {
	f := newKeyFixture(t).guarded()
	target := authtest.NewDevice(t)
	tok := f.enrol(target)
	targetInfo := f.info(tok)

	addProof := f.stepUpPasskey(tok, keyproto.ActionPasskeyAdd)
	id, opts, err := f.passkeys.AddBegin(bgctx, targetInfo, addProof)
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	add := PasskeyAdd{CeremonyID: id, Credential: a.Create(t, opts)}
	add.DWKSig = addSig(t, target, addProof.Nonce, a, nil)

	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(target.WriterID))
	rev := f.revocation(target.WriterID, f.device, 0, make([]byte, 32), su)
	info := f.info(f.token)

	gate, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, gate)
	if err := lockUser(bgctx, gate, f.user); err != nil {
		t.Fatal(err)
	}

	revoked := make(chan error, 1)
	go func() {
		_, err := f.writers.Revoke(bgctx, f.user, info, rev)
		revoked <- err
	}()
	waitForLockWaiters(t, f.count, 1)
	added := make(chan error, 1)
	go func() {
		_, err := f.passkeys.AddFinish(bgctx, targetInfo, add)
		added <- err
	}()
	waitForLockWaiters(t, f.count, 2)
	if err := gate.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if err := <-added; err != nil {
		t.Fatalf("the passkey add: %v", err)
	}
	if err := <-revoked; err != nil {
		t.Fatalf("the revocation: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM writers WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NOT NULL`,
		f.user, target.WriterID); n != 1 {
		t.Fatalf("%d revoked rows for the device, want 1", n)
	}
}

func TestARevocationWaitsForAMailboxUnlinkThatHoldsTheLink(t *testing.T) {
	f := newKeyFixture(t)
	target := authtest.NewDevice(t)
	f.enrol(target)
	plantMailboxLink(t, f.pool, f.user, target.WriterID, 9)

	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(target.WriterID))
	rev := f.revocation(target.WriterID, f.device, 0, make([]byte, 32), su)
	info := f.info(f.token)

	unlink, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, unlink)
	if _, err := unlink.Exec(bgctx, `DELETE FROM mailbox_links WHERE user_id = $1`, f.user); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := f.writers.Revoke(bgctx, f.user, info, rev)
		done <- err
	}()
	waitForLockWait(t, f.count)

	if err := RecordQuietEventTx(bgctx, unlink, f.user, AuthEvent{Kind: EventMailboxUnlinked, WriterID: f.device.WriterID}, f.clock.now()); err != nil {
		t.Fatalf("the unlink behind the revocation: %v", err)
	}
	if err := unlink.Commit(bgctx); err != nil {
		t.Fatalf("commit of the unlink: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("the revocation: %v", err)
	}
}

func TestAResetFinishWaitsForTheAccountBeforeItTakesTheCeremony(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.fake.Reset()

	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	v, err := f.acct.ResetVerify(bgctx, id, f.lastCode(m.addr))
	if err != nil {
		t.Fatal(err)
	}
	ekPub, ek, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := f.acct.ResetRequest(bgctx, id, ekPub); err != nil {
		t.Fatal(err)
	}
	approval, _ := keyproto.ResetApproveMessage(v.Nonce, m.user.UserID, ekPub, m.device.WriterID)
	if err := f.acct.ResetApprove(bgctx, m.info(), id, m.device.WriterID, m.device.SignDAK(t, approval)); err != nil {
		t.Fatal(err)
	}
	newS := f.stretch(m.addr, "a brand new password")
	finish, _ := keyproto.ResetFinishMessage(v.Nonce, newS)
	sig := ed25519.Sign(ek, finish)

	revoke, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, revoke)
	if _, err := revoke.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := f.acct.ResetFinish(bgctx, id, newS, sig)
		done <- err
	}()
	waitForLockWait(t, f.count)

	tag, err := revoke.Exec(bgctx,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND approved_by_writer = $2 AND consumed_at IS NULL`,
		m.user.UserID, m.device.WriterID)
	if err != nil {
		t.Fatalf("the revocation behind the reset: %v", err)
	}
	if tag.RowsAffected() != 1 {
		t.Fatalf("the revocation dropped %d approvals, want 1", tag.RowsAffected())
	}
	if err := revoke.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrResetRefused) || !strings.Contains(err.Error(), "already consumed") {
		t.Fatalf("a reset whose approver was removed first: %v, want the ceremony to be gone", err)
	}
}

func waitForLockWait(t *testing.T, count func(string, ...any) int) {
	t.Helper()
	waitForLockWaiters(t, count, 1)
}

func waitForLockWaiters(t *testing.T, count func(string, ...any) int, want int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if count(`SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()`) >= want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("fewer than %d transactions ever waited on a row lock", want)
}
