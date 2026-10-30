package auth

import (
	"errors"
	"testing"

	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestFiveWrongResetCodesPauseEveryAddressAlike(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	for name, addr := range map[string]string{"an account's address": m.addr, "a free address": newAddr()} {
		id, err := f.acct.ResetBegin(bgctx, addr)
		if err != nil {
			t.Fatalf("%s: begin: %v", name, err)
		}
		wrong := "000000"
		if addr == m.addr && f.lastCode(addr) == wrong {
			wrong = "111111"
		}
		for i := 0; i < 5; i++ {
			if _, err := f.acct.ResetVerify(bgctx, id, wrong); !errors.Is(err, ErrCodeRejected) {
				t.Fatalf("%s: guess %d: %v", name, i, err)
			}
		}
		if _, err := f.acct.ResetBegin(bgctx, addr); !errors.Is(err, ErrRateLimited) {
			t.Fatalf("%s: begin after five wrong codes: %v, want the pause", name, err)
		}
	}
}

func wrongCodeFor(code string) string {
	if code == "000000" {
		return "111111"
	}
	return "000000"
}

func TestAResetCodeWithNoAttemptLeftCountsNothing(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	counted := func() int {
		return f.count(`SELECT coalesce(sum(count), 0) FROM rate_counters WHERE scope = 'code-verify-email'`)
	}
	before := counted()
	wrong := wrongCodeFor(f.lastCode(m.addr))
	for i := 0; i < 20; i++ {
		if _, err := f.acct.ResetVerify(bgctx, id, wrong); !errors.Is(err, ErrCodeRejected) {
			t.Fatalf("guess %d: %v", i, err)
		}
	}
	if got := counted(); got != before+codeMaxAttempts {
		t.Fatalf("20 checks of one reset code counted %d, want %d", got-before, codeMaxAttempts)
	}
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password"); err != nil {
		t.Fatalf("the right recovery code after 20 reset checks: %v", err)
	}
}

func TestTheResetBudgetIsNotSharedWithStepUpOrRecovery(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	for n := 0; n < codeSendsPerHour; n++ {
		id, err := f.acct.ResetBegin(bgctx, m.addr)
		if err != nil {
			t.Fatal(err)
		}
		wrong := wrongCodeFor(f.lastCode(m.addr))
		for i := 0; i < codeMaxAttempts-1; i++ {
			if _, err := f.acct.ResetVerify(bgctx, id, wrong); !errors.Is(err, ErrCodeRejected) {
				t.Fatalf("ceremony %d, guess %d: %v", n, i, err)
			}
		}
		if n == codeSendsPerHour-1 {
			if _, err := f.acct.ResetVerify(bgctx, id, wrong); !errors.Is(err, ErrRateLimited) {
				t.Fatalf("the check over the reset budget: %v", err)
			}
		}
	}

	newS := f.stretch(m.addr, "an entirely new password")
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, sumBytes(newS))
	su, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceStepUpMessage(su.Challenge, m.device.WriterID)
	proof := &StepUpObject{Nonce: su.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
		Sig: m.device.SignDAK(t, msg), Code: f.lastCode(m.addr)}}
	if _, err := f.acct.ResetPasswordWithCode(bgctx, i, newS, proof); err != nil {
		t.Fatalf("the right C8 code over the reset budget: %v", err)
	}

	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password"); err != nil {
		t.Fatalf("the right recovery code over the reset budget: %v", err)
	}
}
