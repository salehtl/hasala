package auth

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// ---------------------------------------------------------------------------
// C9: a new iPhone approved by a signed-in one
// ---------------------------------------------------------------------------

func TestC9ResetIsApprovedByASignedInIPhone(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	stale, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	// A second session bound to the approving iPhone's writer: only the
	// session the approval comes from survives (spec 02 §10.9).
	sibling, err := m.loginPassword(m.s, m.device)
	if err != nil {
		t.Fatal(err)
	}
	f.fake.Reset()

	// N: begin and verify with the emailed code.
	id, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	v, err := f.acct.ResetVerify(bgctx, id, f.lastCode(m.addr))
	if err != nil {
		t.Fatal(err)
	}
	if !v.Approvers || len(v.Nonce) != 32 || !sameBytes(v.Salt, f.keys.PasswordSalt(m.addr)) {
		t.Fatalf("%+v", v)
	}
	ekPub, ek, _ := ed25519.GenerateKey(rand.Reader)
	// The request wakes every live writer of the account, so one can approve
	// (spec 02 §12.5).
	if wake, err := f.acct.ResetRequest(bgctx, id, ekPub); err != nil || wake.UserID != m.user.UserID || wake.Except != "" {
		t.Fatalf("reset request: %+v %v", wake, err)
	}
	if _, err := f.acct.ResetRequest(bgctx, id, ekPub); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a second ek_pub: %v", err)
	}
	newS := f.stretch(m.addr, "a brand new password")
	finishSig := func(s []byte) []byte {
		msg, _ := keyproto.ResetFinishMessage(v.Nonce, s)
		return ed25519.Sign(ek, msg)
	}
	if _, err := f.acct.ResetFinish(bgctx, id, newS, finishSig(newS)); !errors.Is(err, ErrNotApproved) {
		t.Fatalf("finish before approval: %v", err)
	}

	// A: the pending list, then the DAK approval.
	pending, err := f.acct.ResetPending(bgctx, m.user.UserID)
	if err != nil || len(pending) != 1 || pending[0].ResetID != id || !sameBytes(pending[0].EKPub, ekPub) {
		t.Fatalf("pending %+v %v", pending, err)
	}
	approve := func(signer *authtest.Device, ek []byte) []byte {
		msg, _ := keyproto.ResetApproveMessage(v.Nonce, m.user.UserID, ek, signer.WriterID)
		return signer.SignDAK(t, msg)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := f.acct.ResetApprove(bgctx, m.info(), id, m.device.WriterID, approve(m.device, other)); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("an approval of another ephemeral key: %v", err)
	}
	if err := f.acct.ResetApprove(bgctx, m.info(), id, m.device.WriterID, approve(authtest.NewDevice(t), ekPub)); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("an approval by another DAK: %v", err)
	}
	if err := f.acct.ResetApprove(bgctx, m.info(), id, m.device.WriterID, approve(m.device, ekPub)); err != nil {
		t.Fatal(err)
	}

	// N: finish.
	if _, err := f.acct.ResetFinish(bgctx, id, newS, finishSig(m.s)); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("ek_sig over another S: %v", err)
	}
	in, err := f.acct.ResetFinish(bgctx, id, newS, finishSig(newS))
	if err != nil {
		t.Fatal(err)
	}
	if in.Wake.UserID != m.user.UserID || in.Wake.Except != "" {
		t.Fatalf("the reset wakes %+v, want every device of the account", in.Wake)
	}
	i, err := f.sessions.Info(bgctx, in.Session.Token)
	if err != nil || i.MintedBy != MintedPasswordReset || i.WriterID != "" {
		t.Fatalf("N's session %+v %v", i, err)
	}
	if _, err := f.sessions.Resolve(bgctx, stale.Session.Token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatal("a session that predates the reset survived it")
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		t.Fatalf("the approving iPhone was signed out: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, sibling.Session.Token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatal("another session of the approving writer survived the reset")
	}
	if _, err := f.acct.ResetFinish(bgctx, id, newS, finishSig(newS)); !errors.Is(err, ErrResetRefused) {
		t.Fatalf("a replayed finish: %v", err)
	}
	if _, err := m.loginPassword(newS, nil); err != nil {
		t.Fatalf("the new password: %v", err)
	}
	for _, k := range []string{"password_reset", "sign_in_new"} {
		if n := f.count(`SELECT count(*) FROM auth_events WHERE kind = $1`, k); n < 1 {
			t.Fatalf("no %s event", k)
		}
	}
}

// #49 answers the same for every valid address and mails only an eligible
// account.
func TestC9BeginIsUniform(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.fake.Reset()
	a, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		t.Fatal(err)
	}
	stranger := newAddr()
	b, err := f.acct.ResetBegin(bgctx, stranger)
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != len(b) {
		t.Fatal("reset ids differ in shape")
	}
	if len(f.fake.To(stranger)) != 0 || len(f.fake.To(m.addr)) != 1 {
		t.Fatal("a code went to an address with no account, or none to the account")
	}
	if _, err := f.acct.ResetVerify(bgctx, b, "123456"); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a code for an address with no account: %v", err)
	}
}

// ---------------------------------------------------------------------------
// C4: access recovery with an email code and the phrase
// ---------------------------------------------------------------------------

func TestRecoveryWithAPasswordRegistersANewDevice(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	old := m.token
	rk := cryptoref.RK(m.acct.E)
	if _, err := f.acct.RecoverBegin(bgctx, authtest.RandBytesTB(t, 32)); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("an unknown recovery key: %v", err)
	}
	f.fake.Reset()
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	if b.EmailHint != m.addr[:1]+"•••@e•••.com" {
		t.Fatalf("hint %q", b.EmailHint)
	}
	v, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password")
	if err != nil {
		t.Fatal(err)
	}
	if v.UserID != m.user.UserID || !sameBytes(v.Salt, f.keys.PasswordSalt(m.addr)) || len(v.RecoveryWrap) != 127 {
		t.Fatalf("%+v", v)
	}
	d := authtest.NewDevice(t)
	newS := f.stretch(m.addr, "recovered password here")
	msg, _ := keyproto.RecoverySigninPassword(v.Nonce, newS)
	req := RecoverFinishRequest{CeremonyID: b.CeremonyID, Kind: "password", Verifier: newS, RKSig: ed25519.Sign(rk, msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(t, d, v.Nonce)}}
	bad := req
	bad.RKSig = append([]byte(nil), req.RKSig...)
	bad.RKSig[0] ^= 1
	if _, err := f.acct.RecoverFinish(bgctx, bad); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a bad rk_sig: %v", err)
	}
	// The failed attempt spent the ceremony.
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a claimed ceremony: %v", err)
	}
	// Again, properly.
	f.clock.advance(time.Minute)
	b, err = f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	v, err = f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password")
	if err != nil {
		t.Fatal(err)
	}
	msg, _ = keyproto.RecoverySigninPassword(v.Nonce, newS)
	req.CeremonyID, req.RKSig, req.Writer.Sig = b.CeremonyID, ed25519.Sign(rk, msg), m.acct.Registration(t, d, v.Nonce)
	f.fake.Reset()
	out, err := f.acct.RecoverFinish(bgctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if out.WriterID != d.WriterID {
		t.Fatal("the recover session is not bound to the new writer")
	}
	if _, err := f.sessions.Resolve(bgctx, old); !errors.Is(err, ErrSessionRevoked) {
		t.Fatal("recovery left the old session alive")
	}
	if _, err := m.loginPassword(newS, d); err != nil {
		t.Fatalf("the recovered password: %v", err)
	}
	f.sendQueued()
	if !strings.Contains(mailTexts(f.fake.To(m.addr)), "Your recovery phrase was used") {
		t.Fatal("no recovery-used alert")
	}
	if f.count(`SELECT count(*) FROM freeze_tokens WHERE trigger_kind = 'recovery_used'`) != 1 {
		t.Fatal("the recovery alert carries no freeze link")
	}
}

func TestRecoveryWithAPasskeyRegistersTheCredentialAndItsWrap(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	v, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "passkey")
	if err != nil {
		t.Fatal(err)
	}
	if v.Options == nil || v.Options.Response.AuthenticatorSelection.UserVerification != protocol.VerificationRequired {
		t.Fatal("passkey recovery needs UV registration options")
	}
	a := authtest.New(t)
	cred := a.Create(t, v.Options)
	var parsed struct {
		Response struct {
			ClientDataJSON    string `json:"clientDataJSON"`
			AttestationObject string `json:"attestationObject"`
		} `json:"response"`
	}
	if err := json.Unmarshal(cred, &parsed); err != nil {
		t.Fatal(err)
	}
	rawCDJ := mustB64URL(t, parsed.Response.ClientDataJSON)
	rawAtt := mustB64URL(t, parsed.Response.AttestationObject)
	body := cryptoref.Body(m.acct.AMK, m.acct.AAKSeed)
	wrap := cryptoref.SealPRFWrap(authtest.RandBytesTB(t, 32), authtest.RandBytesTB(t, 32), authtest.RandBytesTB(t, 12), body, m.user.UserID, a.CredID)
	msg, _ := keyproto.RecoverySigninPasskey(v.Nonce, rawCDJ, rawAtt, wrap)
	d := authtest.NewDevice(t)
	out, err := f.acct.RecoverFinish(bgctx, RecoverFinishRequest{CeremonyID: b.CeremonyID, Kind: "passkey", Credential: cred,
		PRFCredentialID: a.CredID, PRFWrap: wrap, PRFWrapVersion: 1, RKSig: ed25519.Sign(cryptoref.RK(m.acct.E), msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(t, d, v.Nonce)}})
	if err != nil {
		t.Fatal(err)
	}
	if f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, out.UserID, a.CredID) != 1 ||
		f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, a.CredID) != 1 {
		t.Fatal("the credential or its wrap is missing")
	}
}

func mustB64URL(t *testing.T, s string) []byte {
	t.Helper()
	var b protocol.URLEncodedBase64
	if err := b.UnmarshalJSON([]byte(`"` + s + `"`)); err != nil {
		t.Fatal(err)
	}
	return b
}

// ---------------------------------------------------------------------------
// Email change and re-verification
// ---------------------------------------------------------------------------

func TestEmailChangeNeedsAStepUpAndCodesToBothAddresses(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	next := newAddr()
	sNew := f.stretch(next, m.pw) // the same password, re-salted for the new address
	addrHash := sha([]byte(next))
	if _, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, nil, nil); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("a password account without verifier_new: %v", err)
	}
	f.fake.Reset()
	su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, addrHash, sumBytes(sNew))
	begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
	if err != nil {
		t.Fatal(err)
	}
	oldCode, newCode := f.lastCode(m.addr), f.lastCode(next)
	if !strings.HasPrefix(f.fake.To(m.addr)[0].Text, "Hi Maya,") || !strings.HasPrefix(f.fake.To(next)[0].Text, "Hi,") {
		t.Fatal("the old address's code greets the holder; the new one's greets nobody")
	}
	wrong := "000000"
	if newCode == wrong {
		wrong = "111111"
	}
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, wrong, &oldCode, nil); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a wrong new code: %v", err)
	}
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, newCode, &oldCode, []byte("x")); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("both code_old and rk_sig: %v", err)
	}
	f.fake.Reset()
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, newCode, &oldCode, nil); err != nil {
		t.Fatal(err)
	}
	var email string
	if err := f.pool.QueryRow(bgctx, `SELECT email_norm FROM users WHERE id = $1`, m.user.UserID).Scan(&email); err != nil || email != next {
		t.Fatalf("address %q", email)
	}
	// The password was re-salted: S for the new address signs in.
	m.addr = next
	if _, err := m.loginPassword(sNew, nil); err != nil {
		t.Fatalf("the re-salted password: %v", err)
	}
	f.sendQueued()
	old := mailTexts(f.fake.Sent())
	if !strings.Contains(old, "This is now your Hasala email address") || !strings.Contains(old, "stopped using this email address") {
		t.Fatal("the two email-changed alerts are missing")
	}
}

func TestEmailChangeWithThePhraseInsteadOfTheOldMailbox(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	next := newAddr()
	sNew := f.stretch(next, m.pw)
	su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(next)), sumBytes(sNew))
	begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.EmailChangeMessage(begun.Nonce, next)
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, f.lastCode(next), nil,
		ed25519.Sign(cryptoref.RK(m.acct.E), msg)); err != nil {
		t.Fatal(err)
	}
}

func TestEmailChangeFinishDoesNotUndoANewerPasswordState(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(f *acctFixture, m *member)
	}{
		{"removed", func(f *acctFixture, m *member) {
			if _, err := f.pool.Exec(bgctx,
				`UPDATE users SET password_hash = NULL, password_salt = NULL, password_version = NULL, password_set_at = NULL
				  WHERE id = $1`, m.user.UserID); err != nil {
				t.Fatal(err)
			}
		}},
		{"changed", func(f *acctFixture, m *member) {
			hash, salt, err := newPasswordHash(bgctx, f.keys, f.acct.Gate, f.stretch(m.addr, "a newer password"))
			if err != nil {
				t.Fatal(err)
			}
			if err := setPasswordTx(bgctx, f.pool, m.user.UserID, hash, salt, f.keys.Current(), f.clock.now()); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			next := newAddr()
			sNew := f.stretch(next, m.pw)
			su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(next)), sumBytes(sNew))
			begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), next, sNew, su)
			if err != nil {
				t.Fatal(err)
			}
			oldCode, newCode := f.lastCode(m.addr), f.lastCode(next)
			var before []byte
			f.clock.advance(time.Second)
			tc.change(f, m)
			if err := f.pool.QueryRow(bgctx, `SELECT password_hash FROM users WHERE id = $1`, m.user.UserID).Scan(&before); err != nil {
				t.Fatal(err)
			}
			if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, newCode, &oldCode, nil); !errors.Is(err, ErrCodeRejected) {
				t.Fatalf("finish after the password was %s: %v, want ErrCodeRejected", tc.name, err)
			}
			var after []byte
			if err := f.pool.QueryRow(bgctx, `SELECT password_hash FROM users WHERE id = $1`, m.user.UserID).Scan(&after); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(before, after) {
				t.Fatalf("the password state was rewritten by an older email change")
			}
		})
	}
}

// A new address that already has an account gets a notice, the answer is
// the same, and the change can never finish.
func TestEmailChangeToAnAddressInUseNeverFinishes(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	taken := f.passwordMember("Pat")
	sNew := f.stretch(taken.addr, m.pw)
	f.fake.Reset()
	su := m.deviceStepUp(keyproto.ActionEmailChange, m.s, sha([]byte(taken.addr)), sumBytes(sNew))
	begun, err := f.acct.EmailChangeBegin(bgctx, m.info(), taken.addr, sNew, su)
	if err != nil {
		t.Fatal(err)
	}
	if msgs := f.fake.To(taken.addr); len(msgs) != 1 || codeRe.MatchString(msgs[0].Text) {
		t.Fatal("the address in use got a code, or no notice")
	}
	old := f.lastCode(m.addr)
	if err := f.acct.EmailChangeFinish(bgctx, m.info(), begun.ChangeID, "123456", &old, nil); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a change to an address in use: %v", err)
	}
}

func TestReverificationClearsTheBounceAndTheOperatorsRequest(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET email_undeliverable_at = now(), reverify_requested_at = now() WHERE id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if err := f.acct.EmailVerifyBegin(bgctx, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if err := f.acct.EmailVerifyFinish(bgctx, m.user.UserID, f.lastCode(m.addr)); err != nil {
		t.Fatal(err)
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND email_undeliverable_at IS NULL AND reverify_requested_at IS NULL`, m.user.UserID) != 1 {
		t.Fatal("re-verification did not clear the flags")
	}
}

// ---------------------------------------------------------------------------
// Freeze
// ---------------------------------------------------------------------------

func TestTheFreezeLinkFreezesAndOnlyAnOlderFactorUnfreezes(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	// An intruder signs in with the password from a new iPhone; the alert
	// carries the freeze link.
	f.fake.Reset()
	intruder, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	tok := f.freezeToken(m.addr)
	f.clock.advance(time.Minute)
	if _, err := f.acct.FreezeByLink(bgctx, tok); err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{m.token, intruder.Session.Token} {
		if _, err := f.sessions.Resolve(bgctx, s); !errors.Is(err, ErrSessionRevoked) {
			t.Fatal("a session survived the freeze")
		}
	}
	if _, err := f.acct.FreezeByLink(bgctx, tok); err != nil {
		t.Fatal("a used token is still a silent success")
	}
	// Sign-ins are restricted now.
	in, err := m.loginPassword(m.s, m.device)
	if err != nil || !in.Restricted {
		t.Fatalf("a sign-in into a frozen account: %+v %v", in, err)
	}
	m.token = in.Session.Token
	// The device (registered before the trigger) and the password (set before
	// it) are older than the event: the unfreeze works.
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	if m.info().Restricted {
		t.Fatal("the unfreezing session is still restricted")
	}
	if f.count(`SELECT count(*) FROM users WHERE frozen_at IS NULL AND id = $1`, m.user.UserID) != 1 {
		t.Fatal("still frozen")
	}
}

func TestANewPasswordCannotUnfreeze(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatal("the in-app freeze kept its own session")
	}
	f.clock.advance(time.Minute)
	// A password set after the freeze (say, by the operator's tools) is not
	// older than the trigger.
	in, _ := m.loginPassword(m.s, m.device)
	m.token = in.Session.Token
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET password_set_at = $2 WHERE id = $1`, m.user.UserID, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a factor newer than the freeze: %v", err)
	}
}

// Only the operator lifts an operator freeze; a holder's freeze on it is
// remembered and handed back by the console's unfreeze (review 2 F-03).
func TestOperatorFreezeOutranksTheHolder(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	tx, _ := f.pool.Begin(bgctx)
	if err := OperatorFreeze(bgctx, tx, m.user.UserID, f.clock.now(), f.mailer); err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit(bgctx)
	in, _ := m.loginPassword(m.s, m.device)
	m.token = in.Session.Token
	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionAccountUnfreeze)
	if _, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionAccountUnfreeze, ph[:], keyproto.ProofDevice); !errors.Is(err, ErrAccountFrozen) {
		t.Fatalf("an unfreeze step-up on an operator freeze: %v", err)
	}
	if _, err := f.acct.Unfreeze(bgctx, i, &StepUpObject{Nonce: make([]byte, 32)}); !errors.Is(err, ErrAccountFrozen) {
		t.Fatalf("the holder's unfreeze of an operator freeze: %v", err)
	}
	// A holder freeze laid on it (the device freeze) keeps the operator's.
	nonce, _, err := f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
	if err != nil {
		t.Fatal(err)
	}
	msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
	if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), nil); err != nil {
		t.Fatal(err)
	}
	var (
		by        string
		holderToo bool
	)
	_ = f.pool.QueryRow(bgctx, `SELECT frozen_by, holder_also_froze FROM users WHERE id = $1`, m.user.UserID).Scan(&by, &holderToo)
	if by != "operator" || !holderToo {
		t.Fatalf("frozen_by %s, holder_also_froze %v", by, holderToo)
	}
	// The console's unfreeze hands it back to the holder.
	tx, _ = f.pool.Begin(bgctx)
	unfrozen, err := OperatorUnfreeze(bgctx, tx, m.user.UserID, ScopeOperatorOnly, f.clock.now(), f.mailer)
	if err != nil || unfrozen {
		t.Fatalf("C37 on an operator+holder freeze: %v %v", unfrozen, err)
	}
	_ = tx.Commit(bgctx)
	_ = f.pool.QueryRow(bgctx, `SELECT frozen_by, holder_also_froze FROM users WHERE id = $1`, m.user.UserID).Scan(&by, &holderToo)
	if by != "holder" || holderToo {
		t.Fatalf("after C37: frozen_by %s, holder_also_froze %v", by, holderToo)
	}
	tx, _ = f.pool.Begin(bgctx)
	if _, err := OperatorUnfreeze(bgctx, tx, m.user.UserID, ScopeOperatorOnly, f.clock.now(), f.mailer); !errors.Is(err, ErrHolderFreeze) {
		t.Fatalf("C37 on a holder's freeze: %v", err)
	}
	_ = tx.Rollback(bgctx)
	tx, _ = f.pool.Begin(bgctx)
	if unfrozen, err := OperatorUnfreeze(bgctx, tx, m.user.UserID, ScopeAny, f.clock.now(), f.mailer); err != nil || !unfrozen {
		t.Fatalf("the CLI's unfreeze: %v %v", unfrozen, err)
	}
	_ = tx.Commit(bgctx)
}

// D42: an enrolled iPhone whose session something else revoked freezes the
// account with its DAK, dated back to that sign-out, so the factors created
// by the event cannot unfreeze.
func TestADeviceFreezeIsDatedBackToTheSignOut(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	// A thief recovers the account (new password, new writer): the owner's
	// iPhone is signed out.
	signedOut := f.clock.now()
	if _, err := f.pool.Exec(bgctx, `UPDATE sessions SET revoked_at = $2, revoked_reason = 'others' WHERE token_hash = $1`,
		SessionHash(m.token), signedOut); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(2 * time.Hour)
	// Uniform answers: any well-formed writer id gets a nonce.
	if _, _, err := f.acct.DeviceFreezeChallenge(bgctx, "ios-"+strings.Repeat("0", 8)+"-0000-4000-8000-000000000000"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.acct.DeviceFreezeChallenge(bgctx, "not-a-writer"); !errors.Is(err, ErrBadWriterID) {
		t.Fatal(err)
	}
	nonce, _, _ := f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
	msg, _ := keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
	bad := m.device.SignDAK(t, msg)
	bad[40] ^= 1
	if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, bad, nil); !errors.Is(err, ErrFreezeRefused) {
		t.Fatal(err)
	}
	if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), nil); !errors.Is(err, ErrFreezeRefused) {
		t.Fatal("a nonce served twice")
	}
	nonce, _, _ = f.acct.DeviceFreezeChallenge(bgctx, m.device.WriterID)
	msg, _ = keyproto.DeviceFreezeMessage(nonce, m.user.UserID, m.device.WriterID)
	if _, err := f.acct.DeviceFreeze(bgctx, m.device.WriterID, nonce, m.device.SignDAK(t, msg), nil); err != nil {
		t.Fatal(err)
	}
	var trigger time.Time
	if err := f.pool.QueryRow(bgctx, `SELECT freeze_trigger_at FROM users WHERE id = $1`, m.user.UserID).Scan(&trigger); err != nil {
		t.Fatal(err)
	}
	if !trigger.Equal(signedOut) {
		t.Fatalf("trigger %v, want the sign-out %v", trigger, signedOut)
	}
	if f.count(`SELECT count(*) FROM auth_events WHERE kind = 'account_frozen' AND writer_id = $1`, m.device.WriterID) != 1 {
		t.Fatal("account_frozen does not name the writer")
	}
}

func sha(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

// ---------------------------------------------------------------------------
// Passkey sign-in binding, phrase view, sweeps
// ---------------------------------------------------------------------------

func TestPasskeySignInBindsADeviceAndRecordsOnlyUnboundSignIns(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	r, a, err := f.registerPasskey(f.provenSignup(addr, "Pat").SignupID)
	if err != nil {
		t.Fatal(err)
	}
	// Enrol a writer directly (the AAK path is writer_test.go's subject).
	d := authtest.NewDevice(t)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1, $2, 'ed25519', $3, $4, now())`,
		r.UserID, d.WriterID, d.DWKPub(), d.DAKPub()); err != nil {
		t.Fatal(err)
	}
	counter := uint32(2)
	login := func(device *authtest.Device, tamper bool) (SignedIn, error) {
		id, opts, err := f.passkeys.BeginLogin(bgctx)
		if err != nil {
			t.Fatal(err)
		}
		counter++
		resp := a.Assert(t, opts, counter)
		var dev *DeviceBinding
		if device != nil {
			msg, _ := keyproto.SessionBindMessage(opts.Response.Challenge, device.WriterID)
			sig := ed25519.Sign(device.DWK, msg)
			if tamper {
				sig[0] ^= 1
			}
			dev = &DeviceBinding{WriterID: device.WriterID, Sig: sig}
		}
		return f.acct.PasskeyLoginFinish(bgctx, id, resp, dev)
	}
	in, err := login(d, false)
	if err != nil || in.WriterID != d.WriterID || in.HasKeys {
		t.Fatalf("a bound sign-in: %+v %v", in, err)
	}
	if f.count(`SELECT count(*) FROM auth_events WHERE kind = 'sign_in_new'`) != 0 {
		t.Fatal("a bound sign-in recorded sign_in_new")
	}
	if _, err := login(d, true); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a tampered binding: %v", err)
	}
	if _, err := login(authtest.NewDevice(t), false); !errors.Is(err, ErrDeviceOtherAccount) {
		t.Fatalf("another account's or no writer: %v", err)
	}
	if in, err = login(nil, false); err != nil || in.WriterID != "" {
		t.Fatal(err)
	}
	if f.count(`SELECT count(*) FROM auth_events WHERE kind = 'sign_in_new' AND method = 'passkey'`) != 1 {
		t.Fatal("an unbound sign-in recorded no sign_in_new")
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE writers SET revoked_at = now() WHERE writer_id = $1`, d.WriterID); err != nil {
		t.Fatal(err)
	}
	if _, err := login(d, false); !errors.Is(err, ErrWriterRevoked) {
		t.Fatalf("a revoked writer: %v", err)
	}
}

func TestThePhraseBoxIsReleasedOnlyToAPasskeyWithAWrap(t *testing.T) {
	k := newKeyFixture(t)
	m := &Mailer{}
	acct := &Accounts{Pool: k.pool, Sessions: k.sessions, Passkeys: k.passkeys, StepUp: k.stepUp, Mail: m, Now: k.clock.now}
	box, err := acct.ViewPhrase(bgctx, k.info(k.token), k.stepUpPasskey(k.token, keyproto.ActionPhraseView))
	if err != nil {
		t.Fatal(err)
	}
	var stored []byte
	if err := k.pool.QueryRow(bgctx, `SELECT phrase_box FROM account_keys WHERE user_id = $1`, k.user).Scan(&stored); err != nil || !sameBytes(box, stored) {
		t.Fatal("the box is not the stored one")
	}
	if k.count(`SELECT count(*) FROM auth_events WHERE kind = 'phrase_viewed'`) != 1 {
		t.Fatal("no phrase_viewed event")
	}
	// A credential with no PRF wrap cannot open it.
	if _, err := k.pool.Exec(bgctx, `DELETE FROM account_key_wraps`); err != nil {
		t.Fatal(err)
	}
	if _, err := acct.ViewPhrase(bgctx, k.info(k.token), k.stepUpPasskey(k.token, keyproto.ActionPhraseView)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a passkey without a wrap: %v", err)
	}
}

func TestSweepsForgetExpiredCeremoniesAndCodes(t *testing.T) {
	f := newAcctFixture(t)
	addr := newAddr()
	if _, err := f.acct.SignupBegin(bgctx, SignupBeginRequest{InviteCode: f.printedInvite(false), Email: addr, DisplayName: "Maya"}); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(SignupTTL + 2*time.Hour)
	if _, err := f.acct.SweepCeremonies(bgctx); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.SweepHourly(bgctx); err != nil {
		t.Fatal(err)
	}
	if f.count(`SELECT count(*) FROM signup_ceremonies`) != 0 || f.count(`SELECT count(*) FROM email_codes`) != 0 {
		t.Fatal("an expired signup or code survived the sweep")
	}
}

func TestSweepsDeleteOldAdminAuditAndRefusals(t *testing.T) {
	f := newAcctFixture(t)
	f.clock.advance(time.Since(f.clock.now()))
	if _, err := f.pool.Exec(bgctx, `INSERT INTO admin_audit (at, actor, action, result) VALUES (now() - interval '401 days', 'system:sweep', 'invite.mint', 'ok'), (now() - interval '399 days', 'system:sweep', 'invite.mint', 'ok')`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.SweepHourly(bgctx); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM admin_audit`); n != 1 {
		t.Fatalf("admin_audit rows = %d, want 1", n)
	}
}

func TestSweepsDeleteOldAnonymousBankCounts(t *testing.T) {
	f := newAcctFixture(t)
	f.clock.advance(time.Since(f.clock.now()))
	if _, err := f.pool.Exec(bgctx, `INSERT INTO bank_requests (other_key, other_text, source, created_at) VALUES ('old', 'Old Bank', 'web', now() - interval '366 days'), ('new', 'New Bank', 'web', now() - interval '364 days')`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.SweepHourly(bgctx); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM bank_requests WHERE source = 'web'`); n != 1 {
		t.Fatalf("anonymous bank_requests = %d, want 1", n)
	}
}

func markAddressInDoubt(t *testing.T, f *acctFixture, m *member) {
	t.Helper()
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET reverify_requested_at = now() WHERE id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
}

func TestARecoveryInProgressStopsWhenTheAddressIsInDoubt(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		t.Fatal(err)
	}
	markAddressInDoubt(t, f, m)
	if _, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), "password"); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("a verification on an address in doubt: %v", err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET reverify_requested_at = NULL WHERE id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}

	f.clock.advance(time.Minute)
	id, v := f.verifiedRecovery(m, "password")
	markAddressInDoubt(t, f, m)
	newS := f.stretch(m.addr, "a recovered password")
	d := authtest.NewDevice(t)
	msg, _ := keyproto.RecoverySigninPassword(v.Nonce, newS)
	req := RecoverFinishRequest{CeremonyID: id, Kind: "password", Verifier: newS,
		RKSig: ed25519.Sign(cryptoref.RK(m.acct.E), msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(t, d, v.Nonce)}}
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a recovery finished on an address in doubt: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM writers WHERE user_id = $1 AND writer_id = $2`, m.user.UserID, d.WriterID); n != 0 {
		t.Fatal("the refused recovery added a device")
	}
}

func TestAPasswordResetSendsNoCodeToAnAddressInDoubt(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	markAddressInDoubt(t, f, m)
	f.fake.Reset()
	if _, err := f.acct.ResetBegin(bgctx, m.addr); err != nil {
		t.Fatalf("a reset of an address in doubt must answer as any other: %v", err)
	}
	if n := len(f.fake.To(m.addr)); n != 0 {
		t.Fatalf("%d emails went to the address in doubt", n)
	}
	if n := f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE user_id = $1`, m.user.UserID); n != 0 {
		t.Fatalf("%d reset ceremonies are bound to the account", n)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET reverify_requested_at = NULL WHERE id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.acct.ResetBegin(bgctx, m.addr); err != nil {
		t.Fatal(err)
	}
	if n := len(f.fake.To(m.addr)); n != 1 {
		t.Fatalf("%d emails after the address was cleared, want the code", n)
	}
}
