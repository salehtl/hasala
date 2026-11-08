package auth

import (
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestADeviceFreezeFindsTheWriterThatSigned(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	other := f.passwordMember("Pat")
	twin := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, now())`, other.user.UserID, m.device.WriterID, twin.DWKPub(), twin.DAKPub()); err != nil {
		t.Fatal(err)
	}
	var admitted []uuid.UUID
	admit := func(u uuid.UUID) bool {
		admitted = append(admitted, u)
		return len(admitted) < 2
	}
	freeze := func() error {
		nonce, _, err := f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
		if err != nil {
			t.Fatal(err)
		}
		msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
		bad := m.device.SignDAK(t, msg)
		bad[40] ^= 1
		if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, bad, admit); !errors.Is(err, ErrFreezeRefused) {
			t.Fatalf("a bad signature: %v", err)
		}
		nonce, _, _ = f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
		msg, _ = keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
		_, err = f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), admit)
		return err
	}
	if err := freeze(); err != nil {
		t.Fatalf("a freeze by a writer id another account also holds: %v", err)
	}
	if len(admitted) != 1 || admitted[0] != m.user.UserID {
		t.Fatalf("the limiter was asked for %v, want only the signing account", admitted)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, m.user.UserID); n != 1 {
		t.Fatal("the signing account is not frozen")
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL`, other.user.UserID); n != 0 {
		t.Fatal("the other account was frozen")
	}
	if err := freeze(); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("a freeze over the limit: %v", err)
	}
}

func TestTheLiftAnswerAgreesWithTheLiftItself(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	older := m.device
	f.clock.advance(time.Hour)
	trigger := f.clock.now()
	f.clock.advance(time.Hour)
	newer := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, $5)`, m.user.UserID, newer.WriterID, newer.DWKPub(), newer.DAKPub(), f.clock.now()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = $2, freeze_trigger_at = $3, frozen_by = 'holder' WHERE id = $1`,
		m.user.UserID, f.clock.now(), trigger); err != nil {
		t.Fatal(err)
	}

	on := func(d *authtest.Device) bool {
		t.Helper()
		in, err := m.loginPassword(m.s, d)
		if err != nil {
			t.Fatal(err)
		}
		m.token, m.device = in.Session.Token, d
		can, err := HolderCanLift(bgctx, f.pool, m.user.UserID, d.WriterID)
		if err != nil {
			t.Fatal(err)
		}
		_, err = f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s))
		if can != (err == nil) {
			t.Fatalf("the answer for this device is %v, the lift said %v", can, err)
		}
		if err != nil && !errors.Is(err, ErrStepUpFailed) {
			t.Fatalf("a lift by a device newer than the freeze: %v", err)
		}
		return can
	}
	if on(newer) {
		t.Fatal("a device newer than the freeze was told it can lift it")
	}
	if !on(older) {
		t.Fatal("the device older than the freeze was told it cannot lift it")
	}
}

func (m *member) deviceFreezeTrigger() time.Time {
	m.f.t.Helper()
	nonce, _, err := m.f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
	if err != nil {
		m.f.t.Fatal(err)
	}
	msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
	if _, err := m.f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(m.f.t, msg), nil); err != nil {
		m.f.t.Fatal(err)
	}
	var trigger time.Time
	if err := m.f.pool.QueryRow(bgctx, `SELECT freeze_trigger_at FROM users WHERE id = $1`, m.user.UserID).Scan(&trigger); err != nil {
		m.f.t.Fatal(err)
	}
	return trigger
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnSignOut(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if err := f.acct.LogoutAll(bgctx, m.info(), m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	want := f.clock.now()
	if got := m.deviceFreezeTrigger(); !got.Equal(want) {
		t.Fatalf("trigger %v, want the freeze itself %v and not the device's own sign-out", got, want)
	}
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnEarlierFreeze(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	in, err := m.loginPassword(m.s, m.device)
	if err != nil {
		t.Fatal(err)
	}
	m.token = in.Session.Token
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET password_set_at = $2 WHERE id = $1`, m.user.UserID, f.clock.now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	want := f.clock.now()
	if got := m.deviceFreezeTrigger(); !got.Equal(want) {
		t.Fatalf("trigger %v, want the second freeze %v and not the device's own first freeze", got, want)
	}
}

func TestADeviceFreezeIsDatedToASignOutAnotherDeviceAskedFor(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	victim := m.device
	f.clock.advance(time.Hour)
	other := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, $5)`, m.user.UserID, other.WriterID, other.DWKPub(), other.DAKPub(), f.clock.now()); err != nil {
		t.Fatal(err)
	}
	in, err := m.loginPassword(m.s, other)
	if err != nil {
		t.Fatal(err)
	}
	m.token, m.device = in.Session.Token, other
	f.clock.advance(time.Hour)
	signedOut := f.clock.now()
	if err := f.acct.LogoutAll(bgctx, m.info(), m.deviceStepUp(keyproto.ActionSessionLogoutAll, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	m.device = victim
	if got := m.deviceFreezeTrigger(); !got.Equal(signedOut) {
		t.Fatalf("trigger %v, want the sign-out another device asked for %v", got, signedOut)
	}
}

func TestADeviceFreezeStaysDatedToASignOutProvedOnlyByAPasskey(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	a := f.enrolPasskey(m.user.UserID)
	f.clock.advance(time.Hour)
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionSessionLogoutAll)
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionSessionLogoutAll, ph[:], keyproto.ProofPasskey)
	if err != nil {
		t.Fatal(err)
	}
	signedOut := f.clock.now()
	if err := f.acct.LogoutAll(bgctx, i, &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "passkey",
		Assertion: a.AssertChallenge(t, authtest.RPID, b.Challenge[:], 2)}}); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	if got := m.deviceFreezeTrigger(); !got.Equal(signedOut) {
		t.Fatalf("trigger %v, want the sign-out %v: a passkey does not show this device asked", got, signedOut)
	}
}

func (m *member) signInAgainOnThisDevice() {
	m.f.t.Helper()
	if _, err := m.loginPassword(m.s, m.device); err != nil {
		m.f.t.Fatal(err)
	}
}

func (m *member) deviceFreezeIsDatedNowAndLifts() {
	m.f.t.Helper()
	want := m.f.clock.now()
	if got := m.deviceFreezeTrigger(); !got.Equal(want) {
		m.f.t.Fatalf("trigger %v, want the freeze itself %v and not the device's own action", got, want)
	}
	in, err := m.loginPassword(m.s, m.device)
	if err != nil {
		m.f.t.Fatal(err)
	}
	m.token = in.Session.Token
	can, err := HolderCanLift(bgctx, m.f.pool, m.user.UserID, m.device.WriterID)
	if err != nil {
		m.f.t.Fatal(err)
	}
	if !can {
		m.f.t.Fatal("the device was told it cannot lift its own freeze")
	}
	if _, err := m.f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		m.f.t.Fatalf("the device could not lift its own freeze: %v", err)
	}
}

func (m *member) changePasswordWithThisDevice() {
	m.f.t.Helper()
	next := m.f.stretch(m.addr, "an entirely new password")
	su := m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(next))
	if _, err := m.f.acct.ChangePassword(bgctx, m.info(), next, su); err != nil {
		m.f.t.Fatal(err)
	}
	m.s = next
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnPasswordChange(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	m.signInAgainOnThisDevice()
	f.clock.advance(time.Hour)
	m.changePasswordWithThisDevice()
	f.clock.advance(2 * time.Hour)
	m.deviceFreezeIsDatedNowAndLifts()
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnPasswordReset(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	m.signInAgainOnThisDevice()
	f.clock.advance(time.Hour)
	next := f.stretch(m.addr, "an entirely new password")
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordReset, sumBytes(next))
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordReset, ph[:], keyproto.ProofDeviceCode)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceStepUpMessage(b.Challenge, m.device.WriterID)
	su := &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "device_code", WriterID: m.device.WriterID,
		Sig: m.device.SignDAK(t, msg), Code: f.lastCode(m.addr)}}
	if _, err := f.acct.ResetPasswordWithCode(bgctx, i, next, su); err != nil {
		t.Fatal(err)
	}
	m.s = next
	f.clock.advance(2 * time.Hour)
	m.deviceFreezeIsDatedNowAndLifts()
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnUnfreeze(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	in, err := m.loginPassword(m.s, m.device)
	if err != nil {
		t.Fatal(err)
	}
	m.token = in.Session.Token
	m.signInAgainOnThisDevice()
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET password_set_at = $2 WHERE id = $1`, m.user.UserID, f.clock.now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	m.deviceFreezeIsDatedNowAndLifts()
}

func TestADeviceFreezeIsNotDatedToTheDevicesOwnPasskeyRemoval(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	a := f.enrolPasskey(m.user.UserID)
	f.clock.advance(time.Hour)
	id, opts, err := f.passkeys.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	bind, _ := keyproto.SessionBindMessage(opts.Response.Challenge, m.device.WriterID)
	if _, err := f.acct.PasskeyLoginFinish(bgctx, id, a.Assert(t, opts, 2),
		&DeviceBinding{WriterID: m.device.WriterID, Sig: ed25519.Sign(m.device.DWK, bind)}); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	su := m.deviceStepUp(keyproto.ActionPasskeyDelete, m.s, a.CredID)
	if _, err := f.passkeys.DeletePasskey(bgctx, m.info(), a.CredID, su); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	m.changePasswordWithThisDevice()
	f.clock.advance(2 * time.Hour)
	m.deviceFreezeIsDatedNowAndLifts()
}

func TestADeviceFreezeIsDatedToAPasswordChangeAnotherDeviceAskedFor(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	victim := m.device
	f.clock.advance(time.Hour)
	other := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, $5)`, m.user.UserID, other.WriterID, other.DWKPub(), other.DAKPub(), f.clock.now()); err != nil {
		t.Fatal(err)
	}
	in, err := m.loginPassword(m.s, other)
	if err != nil {
		t.Fatal(err)
	}
	m.token, m.device = in.Session.Token, other
	f.clock.advance(time.Hour)
	changed := f.clock.now()
	m.changePasswordWithThisDevice()
	f.clock.advance(2 * time.Hour)
	m.device = victim
	if got := m.deviceFreezeTrigger(); !got.Equal(changed) {
		t.Fatalf("trigger %v, want the password change another device asked for %v", got, changed)
	}
}

func TestADeviceFreezeStaysDatedToAPasswordChangeProvedOnlyByAPasskey(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	a := f.enrolPasskey(m.user.UserID)
	f.clock.advance(time.Hour)
	m.signInAgainOnThisDevice()
	f.clock.advance(time.Hour)
	next := f.stretch(m.addr, "an entirely new password")
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionPasswordChange, sumBytes(next))
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionPasswordChange, ph[:], keyproto.ProofPasskey)
	if err != nil {
		t.Fatal(err)
	}
	changed := f.clock.now()
	if _, err := f.acct.ChangePassword(bgctx, i, next, &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "passkey",
		Assertion: a.AssertChallenge(t, authtest.RPID, b.Challenge[:], 2)}}); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	if got := m.deviceFreezeTrigger(); !got.Equal(changed) {
		t.Fatalf("trigger %v, want the change %v: a passkey does not show this device asked", got, changed)
	}
}
