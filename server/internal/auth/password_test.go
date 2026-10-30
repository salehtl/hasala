package auth

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestPasswordSignInMintsASessionAndAlertsWithAFreezeLink(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya Rahman")
	f.fake.Reset()
	in, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !in.HasKeys || in.WriterID != "" || in.Restricted {
		t.Fatalf("%+v", in)
	}
	if n := f.count(`SELECT count(*) FROM auth_events WHERE kind = 'sign_in_new' AND method = 'password'`); n != 1 {
		t.Fatal("an unbound sign-in recorded no sign_in_new")
	}
	tok := f.freezeToken(m.addr)
	msg := f.fake.To(m.addr)[0]
	if !strings.HasPrefix(msg.Text, "Hi Maya,\n\n") || msg.Subject != "New sign-in to Hasala" ||
		!strings.Contains(msg.Text, "with your password on") {
		t.Fatalf("alert %q / %q", msg.Subject, msg.Text)
	}
	if n := f.count(`SELECT count(*) FROM freeze_tokens WHERE trigger_kind = 'new_sign_in'`); n != 1 || len(tok) != 43 {
		t.Fatal("the alert's freeze token was not minted at send time")
	}
	if n := f.count(`SELECT count(*) FROM mail_log WHERE status = 'sent' AND kind = 'alert'`); n != 1 {
		t.Fatal("the alert's mail_log row is not final")
	}
	// A bound sign-in records nothing.
	if _, err := m.loginPassword(m.s, m.device); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM auth_events WHERE kind = 'sign_in_new'`); n != 1 {
		t.Fatal("a bound sign-in recorded sign_in_new")
	}
}

// Every failure is the same password_rejected after the same one PBKDF2:
// unknown address, no password, wrong S, a spent ceremony (spec 02 E-09).
func TestPasswordSignInFailuresAreUniformAndCostOnePBKDF2(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	passkeyOnly := newAddr()
	s := f.provenSignup(passkeyOnly, "Pat")
	if _, _, err := f.registerPasskey(s.SignupID); err != nil {
		t.Fatal(err)
	}
	wrong := append([]byte(nil), m.s...)
	wrong[0] ^= 1
	for name, run := range map[string]func() error{
		"unknown address": func() error {
			b, _ := f.acct.PasswordLoginBegin(bgctx, newAddr())
			_, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, nil)
			return err
		},
		"no password": func() error {
			b, _ := f.acct.PasswordLoginBegin(bgctx, passkeyOnly)
			_, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, nil)
			return err
		},
		"wrong S": func() error { _, err := m.loginPassword(wrong, nil); return err },
		"unknown ceremony": func() error {
			_, err := f.acct.PasswordLoginFinish(bgctx, "nope", m.s, nil)
			return err
		},
		"a short verifier": func() error { _, err := m.loginPassword(m.s[:5], nil); return err },
	} {
		before := f.keys.HashCount()
		if err := run(); !errors.Is(err, ErrPasswordRejected) {
			t.Errorf("%s: %v", name, err)
		}
		if n := f.keys.HashCount() - before; n != 1 {
			t.Errorf("%s ran %d PBKDF2, want 1", name, n)
		}
	}
	// The begin answer has one shape for every valid address.
	a, _ := f.acct.PasswordLoginBegin(bgctx, m.addr)
	b, _ := f.acct.PasswordLoginBegin(bgctx, newAddr())
	if len(a.Salt) != len(b.Salt) || len(a.Nonce) != len(b.Nonce) || len(a.CeremonyID) != len(b.CeremonyID) {
		t.Fatal("password/login/begin's answer depends on the account")
	}
	if _, err := f.acct.PasswordLoginBegin(bgctx, "not-an-address"); !errors.Is(err, ErrBadEmail) {
		t.Fatalf("a bad address: %v", err)
	}
}

func TestConcurrentBoundPasswordAttemptsStayWithinTheWritersBudget(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	wrong := append([]byte(nil), m.s...)
	wrong[0] ^= 1
	const n = 8
	finish := make([]func() error, n)
	for i := range finish {
		b, err := f.acct.PasswordLoginBegin(bgctx, m.addr)
		if err != nil {
			t.Fatal(err)
		}
		msg, _ := keyproto.SessionBindMessage(b.Nonce, m.device.WriterID)
		d := &DeviceBinding{WriterID: m.device.WriterID, Sig: ed25519.Sign(m.device.DWK, msg)}
		finish[i] = func() error {
			_, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, wrong, d)
			return err
		}
	}
	g := authkeys.NewGate(1, 2*n, 30*time.Second)
	hold, err := g.Acquire(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	f.acct.Gate = g
	errs := make(chan error, n)
	for _, fn := range finish {
		go func() { errs <- fn() }()
	}
	limited, rejected := 0, 0
	deadline := time.After(2 * time.Second)
	collect := func(err error) {
		switch {
		case errors.Is(err, ErrRateLimited):
			limited++
		case errors.Is(err, ErrPasswordRejected):
			rejected++
		default:
			t.Errorf("an attempt: %v", err)
		}
	}
wait:
	for limited+rejected < n {
		select {
		case err := <-errs:
			collect(err)
		case <-deadline:
			break wait
		}
	}
	hold()
	for limited+rejected < n {
		collect(<-errs)
	}
	if rejected > passwordWriterFailMax {
		t.Fatalf("%d bound attempts reached the password check, want at most %d", rejected, passwordWriterFailMax)
	}
	if got := f.count(`SELECT password_failures FROM users WHERE id = $1`, m.user.UserID); got > passwordWriterFailMax {
		t.Fatalf("%d failures recorded, want at most %d", got, passwordWriterFailMax)
	}
}

func TestABoundPasswordSuccessGivesItsAttemptBack(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	for i := 0; i < 2*passwordWriterFailMax; i++ {
		if _, err := m.loginPassword(m.s, m.device); err != nil {
			t.Fatalf("bound success %d: %v", i+1, err)
		}
	}
	if got := f.count(`SELECT coalesce(sum(count), 0) FROM rate_counters WHERE scope = 'password-writer'`); got != 0 {
		t.Fatalf("the writer's counter is %d after only successes, want 0", got)
	}
}

// Five consecutive failures pause unbound attempts (1 min, doubling); a bound
// attempt ignores the pause and has its own per-writer budget (review 2 F-01).
func TestPasswordPauseStopsUnboundGuessesButNotABoundDevice(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	wrong := append([]byte(nil), m.s...)
	wrong[0] ^= 1
	for i := 0; i < 5; i++ {
		if _, err := m.loginPassword(wrong, nil); !errors.Is(err, ErrPasswordRejected) {
			t.Fatal(err)
		}
	}
	var paused *time.Time
	if err := f.pool.QueryRow(bgctx, `SELECT password_paused_until FROM users WHERE id = $1`, m.user.UserID).Scan(&paused); err != nil || paused == nil {
		t.Fatalf("no pause after five failures: %v", err)
	}
	if !paused.Equal(f.clock.now().Add(time.Minute)) {
		t.Fatalf("pause until %v, want a minute", paused)
	}
	if _, err := m.loginPassword(m.s, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("the right password while paused: %v", err)
	}
	if _, err := m.loginPassword(m.s, m.device); err != nil {
		t.Fatalf("a bound attempt while paused: %v", err)
	}
	// Success reset the counter.
	if n := f.count(`SELECT password_failures FROM users WHERE id = $1`, m.user.UserID); n != 0 {
		t.Fatalf("failures %d after a success", n)
	}
	// Five bound failures exhaust that writer's hour, before any PBKDF2.
	for i := 0; i < 5; i++ {
		if _, err := m.loginPassword(wrong, m.device); !errors.Is(err, ErrPasswordRejected) {
			t.Fatal(err)
		}
	}
	before := f.keys.HashCount()
	if _, err := m.loginPassword(m.s, m.device); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a sixth bound attempt: %v", err)
	}
	if f.keys.HashCount() != before {
		t.Fatal("a refused bound attempt ran PBKDF2")
	}
}

// The binding is checked before S: an invalid one is 400 bad_signature with no
// PBKDF2, a revoked writer is writer_revoked, and an unknown writer or no
// account is checked against a dummy key.
func TestPasswordSignInChecksTheBindingFirst(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	stranger := authtest.NewDevice(t)
	before := f.keys.HashCount()
	if _, err := m.loginPassword(m.s, stranger); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("an unknown writer: %v", err)
	}
	b, _ := f.acct.PasswordLoginBegin(bgctx, m.addr)
	msg, _ := keyproto.SessionBindMessage(b.Nonce, m.device.WriterID)
	sig := ed25519.Sign(m.device.DWK, msg)
	sig[0] ^= 1
	if _, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, &DeviceBinding{WriterID: m.device.WriterID, Sig: sig}); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a bad signature: %v", err)
	}
	if f.keys.HashCount() != before {
		t.Fatal("an invalid binding ran PBKDF2")
	}
	// The ceremony is spent by the invalid binding.
	if _, err := f.acct.PasswordLoginFinish(bgctx, b.CeremonyID, m.s, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("a ceremony after an invalid binding: %v", err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE writers SET revoked_at = now() WHERE writer_id = $1`, m.device.WriterID); err != nil {
		t.Fatal(err)
	}
	if _, err := m.loginPassword(m.s, m.device); !errors.Is(err, ErrWriterRevoked) {
		t.Fatalf("a revoked writer: %v", err)
	}
}

// A device step-up: the DAK first, then S, bound (no pause), with its own
// failure effects; password.change then revokes every other session.
func TestDeviceStepUpChangesThePassword(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	other, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	newS := f.stretch(m.addr, "an entirely new password")
	vh := sumBytes(newS)
	wrong := append([]byte(nil), m.s...)
	wrong[0] ^= 1
	su := m.deviceStepUp(keyproto.ActionPasswordChange, wrong, vh)
	if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a wrong current password: %v", err)
	}
	if n := f.count(`SELECT password_failures FROM users WHERE id = $1`, m.user.UserID); n != 1 {
		t.Fatalf("a bound wrong S did not count: %d", n)
	}
	if n := f.count(`SELECT count(*) FROM rate_counters WHERE scope = 'password-writer'`); n != 1 {
		t.Fatal("the writer's counter did not rise")
	}
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE used_at IS NOT NULL`); n != 1 {
		t.Fatal("the failed proof did not burn its nonce")
	}
	f.fake.Reset()
	if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, m.deviceStepUp(keyproto.ActionPasswordChange, m.s, vh)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.sessions.Resolve(bgctx, other.Session.Token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("another session survived a password change: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		t.Fatalf("the changing session was revoked: %v", err)
	}
	if _, err := m.loginPassword(newS, nil); err != nil {
		t.Fatalf("the new password: %v", err)
	}
	f.sendQueued()
	if !strings.Contains(mailTexts(f.fake.To(m.addr)), "Your Hasala password was changed on") {
		t.Fatal("no password-changed alert")
	}
	// A step-up for another params hash (another S_new) fails.
	su = m.deviceStepUp(keyproto.ActionPasswordChange, newS, vh)
	if _, err := f.acct.ChangePassword(bgctx, m.info(), m.s, su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a step-up for another verifier: %v", err)
	}
}

// A password never authorizes a key action on its own: a device step-up
// without a valid DAK signature never reaches the password.
func TestADeviceStepUpWithoutTheDAKNeverReachesThePassword(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	newS := f.stretch(m.addr, "an entirely new password")
	su := m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(newS))
	su.Proof.Sig = authtest.NewDevice(t).SignDAK(t, []byte("anything"))
	before := f.keys.HashCount()
	if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatal(err)
	}
	// ChangePassword hashes S_new once before the proof; the proof ran none.
	if f.keys.HashCount()-before != 1 {
		t.Fatalf("PBKDF2 runs %d", f.keys.HashCount()-before)
	}
	if n := f.count(`SELECT password_failures FROM users WHERE id = $1`, m.user.UserID); n != 0 {
		t.Fatal("an invalid DAK signature moved a counter")
	}
}

// C8: the DAK plus an emailed code resets the password on a signed-in iPhone.
// Wrong codes keep the nonce until the fifth, which burns it and pauses only
// this account's C8 codes.
func TestC8ResetsThePasswordWithTheDAKAndAnEmailedCode(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	newS := f.stretch(m.addr, "an entirely new password")
	vh := sumBytes(newS)
	begin := func() *StepUpObject {
		i := m.info()
		ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, vh)
		b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
		if err != nil {
			t.Fatalf("C8 begin: %v", err)
		}
		msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
		return &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
			Sig: m.device.SignDAK(t, msg)}}
	}
	f.fake.Reset()
	su := begin()
	code := f.lastCode(m.addr)
	if !strings.HasPrefix(f.fake.To(m.addr)[0].Text, "Hi Maya,") {
		t.Fatal("C8's code does not greet the holder")
	}
	var ceremonyID string
	if err := f.pool.QueryRow(bgctx, `SELECT ceremony_id FROM email_codes WHERE ceremony_kind = 'step_up'`).Scan(&ceremonyID); err != nil || ceremonyID != hex.EncodeToString(su.Nonce) {
		t.Fatalf("the code is not bound to (step_up, hex(nonce)): %q %v", ceremonyID, err)
	}
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	// A malformed guess is a wrong guess like any other: it does not burn the
	// step-up.
	for i, guess := range []string{"12345", wrong, wrong, wrong} {
		su.Proof.Code = guess
		if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
			t.Fatalf("guess %d: %v", i, err)
		}
	}
	su.Proof.Code = code
	if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su); err != nil {
		t.Fatalf("the right code after four wrong ones: %v", err)
	}
	if _, err := m.loginPassword(newS, nil); err != nil {
		t.Fatal(err)
	}
	// Five wrong codes burn it and pause this account's C8 for 15 minutes,
	// never the address's password_reset sends.
	su = begin()
	su.Proof.Code = wrong
	for i := 0; i < 5; i++ {
		_, _ = f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su)
	}
	su.Proof.Code = f.lastCode(m.addr)
	if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("the nonce survived five wrong codes: %v", err)
	}
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, vh)
	if _, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("C8 right after a burn: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM email_code_pauses`); n != 0 {
		t.Fatal("a burned C8 code paused the address")
	}
	if _, err := f.acct.ResetBegin(bgctx, m.addr); err != nil {
		t.Fatalf("C9's begin after a C8 burn: %v", err)
	}
}

func TestC8CodeChecksAreCountedLikeEveryOtherCode(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	newS := f.stretch(m.addr, "an entirely new password")
	vh := sumBytes(newS)
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, vh)
	begin := func() *StepUpObject {
		b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
		if err != nil {
			t.Fatal(err)
		}
		msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
		return &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
			Sig: m.device.SignDAK(t, msg), Code: f.lastCode(m.addr)}}
	}
	counted := func() int {
		return f.count(`SELECT coalesce(sum(count), 0) FROM rate_counters WHERE scope = 'code-verify-email'`)
	}
	before := counted()
	su := begin()
	if _, err := f.pool.Exec(bgctx, `UPDATE email_codes SET attempts = $1 WHERE ceremony_kind = 'step_up'`, codeMaxAttempts); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("the right C8 code with no attempt left: %v", err)
	}
	if got := counted(); got != before {
		t.Fatalf("code-verify-email is %d after a C8 code with no attempt left, want %d", got, before)
	}
	if _, err := f.acct.ResetPasswordWithCode(bgctx, m.info(), newS, begin()); err != nil {
		t.Fatalf("the right C8 code: %v", err)
	}
	if got := counted(); got != before+1 {
		t.Fatalf("code-verify-email is %d after a C8 check, want %d", got, before+1)
	}
}

func TestSetAndRemoveAPasswordNeedAPasskey(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	r, a, err := f.registerPasskey(f.provenSignup(addr, "Pat").SignupID)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := f.sessions.Info(bgctx, r.Session.Token)
	counter := uint32(2)
	stepUp := func(action keyproto.Action, fields ...[]byte) *StepUpObject {
		ph, _ := keyproto.ParamsHash(action, fields...)
		b, err := f.stepUp.Begin(bgctx, info.UserID, info.Hash, "", action, ph[:], keyproto.ProofPasskey)
		if err != nil {
			t.Fatal(err)
		}
		counter++
		return &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "passkey",
			Assertion: a.AssertChallenge(t, authtest.RPID, b.Challenge[:], counter)}}
	}
	s := f.stretch(addr, "my first password here")
	if _, err := f.acct.RemovePassword(bgctx, info, stepUp(keyproto.ActionPasswordRemove)); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("removing an absent password: %v", err)
	}
	if _, err := f.acct.SetPassword(bgctx, info, s, stepUp(keyproto.ActionPasswordSet, sumBytes(s))); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.SetPassword(bgctx, info, s, stepUp(keyproto.ActionPasswordSet, sumBytes(s))); !errors.Is(err, ErrConflict) {
		t.Fatalf("a second set: %v", err)
	}
	if _, err := f.acct.RemovePassword(bgctx, info, stepUp(keyproto.ActionPasswordRemove)); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NULL`, info.UserID); n != 1 {
		t.Fatal("the password is still there")
	}
	// The last passkey of an account without a password stays.
	if _, err := f.passkeys.DeletePasskey(bgctx, info, a.CredID, stepUp(keyproto.ActionPasskeyDelete, a.CredID)); !errors.Is(err, ErrLastPasskey) {
		t.Fatalf("deleting the last authenticator: %v", err)
	}
}
