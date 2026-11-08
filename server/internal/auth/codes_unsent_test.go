package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/mailq"
)

func TestAnUnsentCodeStopsCountingWhenItsSendWindowEnds(t *testing.T) {
	for name, stopIt := range map[string]func(f *acctFixture){
		"the provider refused the email":   func(f *acctFixture) { f.fake.Err = errors.New("synthetic provider outage") },
		"the server ended before the send": func(f *acctFixture) { f.mailer.Async = func(func()) {} },
	} {
		t.Run(name, func(t *testing.T) {
			f := newAcctFixture(t)
			stopIt(f)
			addr := newAddr()
			invite := f.printedInvite(false)
			begin := func() error {
				_, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: invite, Email: addr, DisplayName: "Maya"})
				return err
			}
			for i := 0; i < codeSendsPerHour; i++ {
				if err := begin(); err != nil {
					t.Fatalf("request %d: %v", i, err)
				}
			}
			if err := begin(); !errors.Is(err, ErrRateLimited) {
				t.Fatalf("a sixth code while five may still be on their way: %v", err)
			}
			f.clock.advance(codeSendWindow + time.Second)
			f.fake.Err = nil
			f.mailer.Async = func(fn func()) { fn() }
			if err := begin(); err != nil {
				t.Fatalf("asking again once no email can still be on its way: %v", err)
			}
			if f.lastCode(addr) == "" {
				t.Fatal("no code arrived")
			}
		})
	}
}

func TestACodeThatWentOutCountsForTheWholeHour(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	invite := f.printedInvite(false)
	begin := func() error {
		_, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: invite, Email: addr, DisplayName: "Maya"})
		return err
	}
	for i := 0; i < codeSendsPerHour; i++ {
		if err := begin(); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	f.clock.advance(codeSendWindow + time.Second)
	if err := begin(); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a sixth code after five went out: %v", err)
	}
	f.clock.advance(time.Hour)
	if err := begin(); err != nil {
		t.Fatalf("the next hour: %v", err)
	}
}

func TestAFailedResetEmailSpendsItsSlotLikeAnAddressWithNoAccount(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.fake.Err = errors.New("synthetic provider outage")
	for _, addr := range []string{m.addr, newAddr()} {
		for i := 0; i < codeSendsPerHour; i++ {
			if _, err := f.acct.ResetBegin(bgctx, addr); err != nil {
				t.Fatalf("%s, request %d: %v", addr, i, err)
			}
		}
		f.clock.advance(codeSendWindow + time.Second)
		if _, err := f.acct.ResetBegin(bgctx, addr); !errors.Is(err, ErrRateLimited) {
			t.Fatalf("%s, a sixth reset: %v", addr, err)
		}
	}
}

func TestOnlyACodeThatAlwaysMailsSomethingWaitsForItsSend(t *testing.T) {
	for _, c := range []struct {
		purpose, kind string
		waits         bool
	}{
		{PurposeSignup, CeremonySignup, true},
		{PurposeEmailVerify, CeremonyEmailVerify, true},
		{PurposeEmailChangeOld, CeremonyEmailChange, true},
		{PurposeEmailChangeNew, CeremonyEmailChange, true},
		{PurposeRecovery, CeremonyRecovery, true},
		{PurposePasswordReset, CeremonyPasswordReset, false},
		{PurposePasswordReset, CeremonyStepUp, false},
	} {
		t.Run(c.purpose+"/"+c.kind, func(t *testing.T) {
			f := newAcctFixture(t)
			tx, err := f.pool.Begin(bgctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(bgctx)
			ic, err := issueCodeTx(bgctx, tx, f.keys, f.clock.now(), c.purpose, newAddr(), nil, c.kind, "ceremony", true)
			if err != nil {
				t.Fatal(err)
			}
			if err := tx.Commit(bgctx); err != nil {
				t.Fatal(err)
			}
			waiting := f.count(`SELECT count(*) FROM email_codes WHERE code_id = $1 AND awaiting_send_until IS NOT NULL`, ic.ID) == 1
			if waiting != c.waits {
				t.Fatalf("waiting for its send: %v, want %v", waiting, c.waits)
			}
		})
	}
}

func TestACodeTheWorkerRendersCountsAsBefore(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	id := m.user.UserID
	tx, err := f.pool.Begin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(bgctx)
	if _, err := f.mailer.renderQueuedCode(bgctx, tx, mailq.Row{Recipient: m.addr, UserID: &id,
		Params: map[string]any{"purpose": PurposeEmailVerify}}); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bgctx); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM email_codes WHERE user_id = $1 AND purpose = $2 AND awaiting_send_until IS NOT NULL`, id, PurposeEmailVerify); n != 0 {
		t.Fatalf("%d queued codes wait for a send that nothing settles", n)
	}
}

func TestASignupAnswersAlikeForAnAddressWithAnAccountAndOneWithout(t *testing.T) {
	for name, c := range map[string]struct {
		outage error
		want   error
	}{
		"the emails went out":  {nil, ErrRateLimited},
		"the provider refused": {errors.New("synthetic provider outage"), nil},
	} {
		t.Run(name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			invite := f.printedInvite(false)
			f.fake.Err = c.outage
			for _, addr := range []string{m.addr, newAddr()} {
				begin := func() error {
					_, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: invite, Email: addr, DisplayName: "Maya"})
					return err
				}
				for i := 0; i < codeSendsPerHour; i++ {
					if err := begin(); err != nil {
						t.Fatalf("%s, request %d: %v", addr, i, err)
					}
				}
				f.clock.advance(codeSendWindow + time.Second)
				if err := begin(); !errors.Is(err, c.want) {
					t.Fatalf("%s, a sixth request: %v, want %v", addr, err, c.want)
				}
			}
		})
	}
}
