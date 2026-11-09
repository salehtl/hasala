package auth

import (
	"errors"
	"testing"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestADeviceCodeIsCountedInOnePlaceAndItsLastWrongGuessEndsTheStepUp(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	newS := f.stretch(m.addr, "an entirely new password")
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, sumBytes(newS))
	f.fake.Reset()
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
	su := &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
		Sig: m.device.SignDAK(t, msg), Code: wrongCodeFor(f.lastCode(m.addr))}}
	for n := 1; n <= codeMaxAttempts; n++ {
		if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
			t.Fatalf("guess %d: %v", n, err)
		}
		if got := f.count(`SELECT attempts FROM email_codes WHERE ceremony_kind = 'step_up'`); got != n {
			t.Fatalf("after guess %d the code counted %d", n, got)
		}
		if got := f.count(`SELECT code_attempts FROM step_up_challenges WHERE nonce = $1`, su.Nonce); got != 0 {
			t.Fatalf("after guess %d the challenge kept a second count of %d", n, got)
		}
		spent := f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NOT NULL`, su.Nonce) == 1
		if spent != (n == codeMaxAttempts) {
			t.Fatalf("after guess %d the challenge ended: %v", n, spent)
		}
	}
	if n := f.count(`SELECT count(*) FROM email_codes WHERE ceremony_kind = 'step_up' AND burned_at IS NOT NULL`); n != 1 {
		t.Fatal("the last wrong guess did not burn the code")
	}
}
