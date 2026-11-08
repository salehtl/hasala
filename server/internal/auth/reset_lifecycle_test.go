package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

type approvedReset struct {
	id   string
	newS []byte
	sig  []byte
}

func (f *acctFixture) approvedReset(m *member, password string) approvedReset {
	f.t.Helper()
	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		f.t.Fatal(err)
	}
	v, err := f.acct.ResetVerify(bgctx, id, f.lastCode(m.addr))
	if err != nil {
		f.t.Fatal(err)
	}
	ekPub, ek, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := f.acct.ResetRequest(bgctx, id, ekPub); err != nil {
		f.t.Fatal(err)
	}
	approval, _ := keyproto.ResetApproveMessage(v.Nonce, m.user.UserID, ekPub, m.device.WriterID)
	if err := f.acct.ResetApprove(bgctx, m.info(), id, m.device.WriterID, m.device.SignDAK(f.t, approval)); err != nil {
		f.t.Fatal(err)
	}
	newS := f.stretch(m.addr, password)
	finish, _ := keyproto.ResetFinishMessage(v.Nonce, newS)
	return approvedReset{id: id, newS: newS, sig: ed25519.Sign(ek, finish)}
}

func (f *acctFixture) assertResetDidNotFinish(m *member, r approvedReset) {
	f.t.Helper()
	if n := f.count(`SELECT count(*) FROM sessions WHERE user_id = $1 AND minted_by = 'password_reset'`, m.user.UserID); n != 0 {
		f.t.Fatalf("%d sessions minted by a refused reset", n)
	}
	if n := f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE id = $1 AND consumed_at IS NOT NULL`, r.id); n != 0 {
		f.t.Fatal("a refused reset consumed its ceremony")
	}
	if _, err := m.loginPassword(m.s, nil); err != nil {
		f.t.Fatalf("the password from before the reset: %v", err)
	}
}

func TestAResetCannotFinishOnceTheApprovingSessionSignedOut(t *testing.T) {
	for name, signOut := range map[string]func(*acctFixture, *member){
		"a sign-out": func(f *acctFixture, m *member) {
			if err := f.sessions.Revoke(bgctx, m.token); err != nil {
				f.t.Fatal(err)
			}
		},
		"a sign-out of all sessions": func(f *acctFixture, m *member) {
			if err := f.acct.LogoutAll(bgctx, m.info(), m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)); err != nil {
				f.t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			r := f.approvedReset(m, "a brand new password")
			signOut(f, m)
			if _, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig); !errors.Is(err, ErrResetRefused) || !strings.Contains(err.Error(), "approver") {
				t.Fatalf("a reset whose approving session ended: %v", err)
			}
			f.assertResetDidNotFinish(m, r)
		})
	}
}

func TestAResetFinishWaitsForASignOutOfTheApprovingSession(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	r := f.approvedReset(m, "a brand new password")

	logout, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, logout)
	if _, err := logout.Exec(bgctx, `UPDATE sessions SET revoked_at = $2, revoked_reason = 'logout' WHERE token_hash = $1`,
		SessionHash(m.token), f.clock.now()); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig)
		done <- err
	}()
	waitForLockWait(t, f.count)
	if err := logout.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrResetRefused) || !strings.Contains(err.Error(), "approver") {
		t.Fatalf("a reset that lost to the sign-out: %v", err)
	}
}

func TestFinishingAResetEndsTheOtherResets(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	first := f.approvedReset(m, "the first new password")
	second := f.approvedReset(m, "the second new password")
	if _, err := f.acct.ResetFinish(bgctx, first.id, first.newS, first.sig); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.ResetFinish(bgctx, second.id, second.newS, second.sig); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a second reset after the first finished: %v", err)
	}
	if _, err := m.loginPassword(first.newS, nil); err != nil {
		t.Fatalf("the first reset's password: %v", err)
	}
	if _, err := m.loginPassword(second.newS, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("the second reset's password: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, m.user.UserID); n != 0 {
		t.Fatalf("%d resets outlived the finished one", n)
	}
}

func TestChangingThePasswordEndsAPendingReset(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	r := f.approvedReset(m, "a brand new password")
	changed := f.stretch(m.addr, "the password the holder chose")
	if _, err := f.acct.ChangePassword(bgctx, m.info(), changed,
		m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(changed))); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a reset begun before the change: %v", err)
	}
	if _, err := m.loginPassword(changed, nil); err != nil {
		t.Fatalf("the changed password: %v", err)
	}
}

func TestTwoResetsFinishingTogetherLeaveOnePassword(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	first := f.approvedReset(m, "the first new password")
	second := f.approvedReset(m, "the second new password")

	holder, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, holder)
	if _, err := holder.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	type result struct {
		r   approvedReset
		err error
	}
	done := make(chan result, 2)
	for _, r := range []approvedReset{first, second} {
		go func() {
			_, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig)
			done <- result{r, err}
		}()
	}
	waitForLockWaiters(t, f.count, 2)
	pgtx.Rollback(bgctx, holder)
	a, b := <-done, <-done
	if (a.err == nil) == (b.err == nil) {
		t.Fatalf("two resets: %v and %v, want one to finish", a.err, b.err)
	}
	won, lost := a, b
	if a.err != nil {
		won, lost = b, a
	}
	if !errors.Is(lost.err, ErrResetRefused) {
		t.Fatalf("the reset that lost: %v", lost.err)
	}
	if _, err := m.loginPassword(won.r.newS, nil); err != nil {
		t.Fatalf("the winning password: %v", err)
	}
	if _, err := m.loginPassword(lost.r.newS, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("the losing password: %v", err)
	}
}

func TestAResetThatExpiresWhileItWaitsIsRefused(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	r := f.approvedReset(m, "a brand new password")

	holder, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, holder)
	if _, err := holder.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig)
		done <- err
	}()
	waitForLockWait(t, f.count)
	f.clock.advance(ResetTTL + time.Second)
	pgtx.Rollback(bgctx, holder)
	if err := <-done; !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a reset past its expiry: %v", err)
	}
	f.assertResetDidNotFinish(m, r)
}
