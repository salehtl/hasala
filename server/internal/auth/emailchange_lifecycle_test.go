package auth

import (
	"crypto/ed25519"
	"errors"
	"testing"

	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

type begunChange struct {
	id           EmailChangeBegun
	next         string
	oldCode, new string
}

func (f *acctFixture) begunChange(m *member) begunChange {
	f.t.Helper()
	next := newAddr()
	sNew := f.stretch(next, m.pw)
	su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(next)), sumBytes(sNew))
	begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
	if err != nil {
		f.t.Fatal(err)
	}
	return begunChange{id: begun, next: next, oldCode: f.lastCode(m.addr), new: f.lastCode(next)}
}

func (f *acctFixture) addressOf(m *member) string {
	f.t.Helper()
	var addr string
	if err := f.pool.QueryRow(bgctx, `SELECT email_norm FROM users WHERE id = $1`, m.user.UserID).Scan(&addr); err != nil {
		f.t.Fatal(err)
	}
	return addr
}

func TestFinishingAnEmailChangeEndsTheOtherChanges(t *testing.T) {
	for name, proof := range map[string]func(*member, begunChange) (*string, []byte){
		"the old address's code": func(_ *member, c begunChange) (*string, []byte) { return &c.oldCode, nil },
		"the recovery key": func(m *member, c begunChange) (*string, []byte) {
			msg, _ := keyproto.EmailChangeMessage(c.id.Nonce, c.next)
			return nil, ed25519.Sign(cryptoref.RK(m.acct.E), msg)
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			first := f.begunChange(m)
			second := f.begunChange(m)
			if err := f.acct.EmailChangeFinish(bgctx, m.info(), first.id.ChangeID, first.new, &first.oldCode, nil); err != nil {
				t.Fatal(err)
			}
			oldCode, sig := proof(m, second)
			if err := f.acct.EmailChangeFinish(bgctx, m.info(), second.id.ChangeID, second.new, oldCode, sig); !errors.Is(err, ErrCodeRejected) {
				t.Fatalf("a change begun before the address moved: %v", err)
			}
			if got := f.addressOf(m); got != first.next {
				t.Fatalf("the address is %q, want the first change's", got)
			}
			if n := f.count(`SELECT count(*) FROM email_change_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, m.user.UserID); n != 0 {
				t.Fatalf("%d changes outlived the finished one", n)
			}
		})
	}
}

func TestOnlyOneOfTwoEmailChangesFinishingTogetherWins(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	changes := []begunChange{f.begunChange(m), f.begunChange(m)}
	info := m.info()

	hold, err := pgtx.BeginReadCommitted(bgctx, f.pool)
	if err != nil {
		t.Fatal(err)
	}
	defer pgtx.Rollback(bgctx, hold)
	if _, err := hold.Exec(bgctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	results := make(chan struct {
		next string
		err  error
	}, len(changes))
	for _, c := range changes {
		go func() {
			err := f.acct.EmailChangeFinish(bgctx, info, c.id.ChangeID, c.new, &c.oldCode, nil)
			results <- struct {
				next string
				err  error
			}{c.next, err}
		}()
	}
	waitForLockWaiters(t, f.count, 2)
	if err := hold.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	winner := ""
	for range changes {
		r := <-results
		switch {
		case r.err == nil && winner == "":
			winner = r.next
		case r.err == nil:
			t.Fatal("both changes finished")
		case !errors.Is(r.err, ErrCodeRejected):
			t.Fatalf("the losing change: %v", r.err)
		}
	}
	if winner == "" {
		t.Fatal("neither change finished")
	}
	if got := f.addressOf(m); got != winner {
		t.Fatalf("the address is %q, want the winner's %q", got, winner)
	}
}

func (f *acctFixture) finishChange(m *member) []byte {
	f.t.Helper()
	c := f.begunChange(m)
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), c.id.ChangeID, c.new, &c.oldCode, nil); err != nil {
		f.t.Fatal(err)
	}
	m.addr, m.s = c.next, f.stretch(c.next, m.pw)
	return m.s
}

func TestAnEmailChangeEndsAnApprovedResetMadeUnderTheOldAddress(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	r := f.approvedReset(m, "a password stretched for the old address")
	current := f.finishChange(m)
	if _, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a reset begun under the old address: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, m.user.UserID); n != 0 {
		t.Fatalf("%d resets outlived the change", n)
	}
	if _, err := m.loginPassword(current, nil); err != nil {
		t.Fatalf("the password re-keyed for the new address: %v", err)
	}
}

func TestAnEmailChangeEndsTheRecoveriesInFlight(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, v := f.verifiedRecovery(m, "password")
	req := f.passwordRecoveryRequest(m, id, v, f.stretch(m.addr, "a password stretched for the old address"))
	passkeyID, passkeyV := f.verifiedRecovery(m, "passkey")
	passkeyReq, _ := f.passkeyRecoveryRequest(m, passkeyID, passkeyV)
	current := f.finishChange(m)
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a password recovery begun under the old address: %v", err)
	}
	if _, err := f.acct.RecoverFinish(bgctx, passkeyReq); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a passkey recovery begun under the old address: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM recovery_ceremonies WHERE user_id = $1`, m.user.UserID); n != 0 {
		t.Fatalf("%d recoveries outlived the change", n)
	}
	if _, err := m.loginPassword(current, nil); err != nil {
		t.Fatalf("the password re-keyed for the new address: %v", err)
	}
}

func TestAnEmailChangeRefusedAtTheLastStepLeavesAResetRunning(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	c := f.begunChange(m)
	r := f.approvedReset(m, "a brand new password")
	wrong := "000000"
	if wrong == c.oldCode {
		wrong = "000001"
	}
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), c.id.ChangeID, c.new, &wrong, nil); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a change with the wrong code: %v", err)
	}
	if _, err := f.acct.ResetFinish(bgctx, r.id, r.newS, r.sig); err != nil {
		t.Fatalf("a reset beside a refused change: %v", err)
	}
}
