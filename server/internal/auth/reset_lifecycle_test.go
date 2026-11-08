package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"

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
