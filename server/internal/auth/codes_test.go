package auth

import (
	"errors"
	"testing"
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
