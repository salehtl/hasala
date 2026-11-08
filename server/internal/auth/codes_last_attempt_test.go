package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func (f *acctFixture) takeEveryAttempt(codeID uuid.UUID) {
	f.t.Helper()
	for i := 0; i < codeMaxAttempts; i++ {
		if err := limitCodeVerify(bgctx, f.pool, f.clock.now(), codeID); err != nil {
			f.t.Fatalf("attempt %d: %v", i, err)
		}
	}
}

func TestAnAddressPausesWhenItsCodesLastGuessWasNeverJudged(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	var codeID uuid.UUID
	if err := f.pool.QueryRow(bgctx, `SELECT code_id FROM password_reset_ceremonies WHERE id = $1`, id).Scan(&codeID); err != nil {
		t.Fatal(err)
	}
	f.takeEveryAttempt(codeID)
	if _, err := f.acct.ResetBegin(bgctx, m.addr); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a code right after the last guess was lost: %v, want the pause", err)
	}
	f.clock.advance(codePause - time.Second)
	if _, err := f.acct.ResetBegin(bgctx, m.addr); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a code just inside the pause: %v, want the pause", err)
	}
	f.clock.advance(2 * time.Second)
	if _, err := f.acct.ResetBegin(bgctx, m.addr); err != nil {
		t.Fatalf("a code after the pause: %v", err)
	}
}

func TestADeviceCodeWhoseLastGuessWasNeverJudgedPausesTheAccountsResets(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, sumBytes(f.stretch(m.addr, "an entirely new password")))
	begin := func() (Begun, error) {
		return f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
	}
	b, err := begin()
	if err != nil {
		t.Fatal(err)
	}
	var codeID uuid.UUID
	if err := f.pool.QueryRow(bgctx, `SELECT code_id FROM step_up_challenges WHERE nonce = $1`, b.Nonce).Scan(&codeID); err != nil {
		t.Fatal(err)
	}
	f.takeEveryAttempt(codeID)
	if _, err := begin(); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a device code right after the last guess was lost: %v, want the pause", err)
	}
	f.clock.advance(deviceCodeBurnPause + time.Second)
	if _, err := begin(); err != nil {
		t.Fatalf("a device code after the pause: %v", err)
	}
}

func TestAnEmailChangeRefusedAtItsOldCodeStillPausesTheAddressOfItsLastAttempt(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	next := newAddr()
	sNew := f.stretch(next, m.pw)
	begin := func() (EmailChangeBegun, error) {
		su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(next)), sumBytes(sNew))
		return f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
	}
	begun, err := begin()
	if err != nil {
		t.Fatal(err)
	}
	oldCode, newCode := f.lastCode(m.addr), f.lastCode(next)
	if _, err := f.pool.Exec(bgctx,
		`UPDATE email_codes SET attempts = CASE purpose WHEN 'email_change_old' THEN 5 ELSE 4 END WHERE ceremony_id = $1`,
		begun.ChangeID.String()); err != nil {
		t.Fatal(err)
	}
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, newCode, &oldCode, nil); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a finish whose old code has no attempt left: %v", err)
	}
	if _, err := begin(); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a new change after the new code's last attempt: %v, want the pause", err)
	}
}

func TestTheRightCodeOnTheLastAttemptPausesNothing(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	code := f.lastCode(m.addr)
	wrong := wrongCodeFor(code)
	for i := 0; i < codeMaxAttempts-1; i++ {
		if _, err := f.acct.ResetVerify(bgctx, id, wrong); !errors.Is(err, ErrCodeRejected) {
			t.Fatalf("guess %d: %v", i, err)
		}
	}
	if _, err := f.acct.ResetVerify(bgctx, id, code); err != nil {
		t.Fatalf("the right code on the last attempt: %v", err)
	}
	if _, err := f.acct.ResetBegin(bgctx, m.addr); err != nil {
		t.Fatalf("a code after the right guess: %v", err)
	}
}
