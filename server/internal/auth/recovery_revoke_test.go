package auth

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func (f *acctFixture) enrolPasskey(userID uuid.UUID) *authtest.Authenticator {
	f.t.Helper()
	creds, handle, err := f.passkeys.credentialsForUser(bgctx, f.pool, userID)
	if err != nil {
		f.t.Fatal(err)
	}
	opts, sd, err := f.passkeys.WA.BeginRegistration(passkeyUser{handle: handle, credentials: creds, rpName: passkeyUserName})
	if err != nil {
		f.t.Fatal(err)
	}
	a := authtest.New(f.t)
	made, err := f.passkeys.createCredential(passkeyUser{handle: handle, rpName: passkeyUserName}, ceremony{Session: *sd}, a.Create(f.t, opts))
	if err != nil {
		f.t.Fatal(err)
	}
	if err := insertCredential(bgctx, f.pool, storedCredential{UserID: userID, UserHandle: handle, Credential: *made.Credential,
		AttestationSHA256: made.AttestationSHA256}, f.clock.now()); err != nil {
		f.t.Fatal(err)
	}
	return a
}

func (f *acctFixture) passkeyLogin(a *authtest.Authenticator, counter uint32) (SignedIn, error) {
	f.t.Helper()
	id, opts, err := f.passkeys.BeginLogin(bgctx)
	if err != nil {
		f.t.Fatal(err)
	}
	return f.acct.PasskeyLoginFinish(bgctx, id, a.Assert(f.t, opts, counter), nil)
}

func (f *acctFixture) verifiedRecovery(m *member, kind string) (string, RecoverVerified) {
	f.t.Helper()
	b, err := f.acct.RecoverBegin(bgctx, cryptoref.RKPub(m.acct.E))
	if err != nil {
		f.t.Fatal(err)
	}
	v, err := f.acct.RecoverVerify(bgctx, b.CeremonyID, f.lastCode(m.addr), kind)
	if err != nil {
		f.t.Fatal(err)
	}
	return b.CeremonyID, v
}

func (f *acctFixture) passkeyRecoveryRequest(m *member, ceremonyID string, v RecoverVerified) (RecoverFinishRequest, *authtest.Authenticator) {
	f.t.Helper()
	a := authtest.New(f.t)
	cred := a.Create(f.t, v.Options)
	var parsed struct {
		Response struct {
			ClientDataJSON    string `json:"clientDataJSON"`
			AttestationObject string `json:"attestationObject"`
		} `json:"response"`
	}
	if err := json.Unmarshal(cred, &parsed); err != nil {
		f.t.Fatal(err)
	}
	msg, _ := keyproto.RecoverySigninPasskey(v.Nonce, mustB64URL(f.t, parsed.Response.ClientDataJSON),
		mustB64URL(f.t, parsed.Response.AttestationObject), nil)
	d := authtest.NewDevice(f.t)
	return RecoverFinishRequest{CeremonyID: ceremonyID, Kind: "passkey", Credential: cred,
		RKSig: ed25519.Sign(cryptoref.RK(m.acct.E), msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(f.t, d, v.Nonce)}}, a
}

func (f *acctFixture) passwordRecoveryRequest(m *member, ceremonyID string, v RecoverVerified, newS []byte) RecoverFinishRequest {
	f.t.Helper()
	msg, _ := keyproto.RecoverySigninPassword(v.Nonce, newS)
	d := authtest.NewDevice(f.t)
	return RecoverFinishRequest{CeremonyID: ceremonyID, Kind: "password", Verifier: newS,
		RKSig: ed25519.Sign(cryptoref.RK(m.acct.E), msg),
		Writer: Registration{WriterID: d.WriterID, Alg: AlgEd25519, PubKey: d.DWKPub(), DAKPubkey: d.DAKPub(),
			Sig: m.acct.Registration(f.t, d, v.Nonce)}}
}

type outstanding struct {
	other     SignedIn
	login     PasswordLoginBegun
	stepUps   int
	resetID   string
	passkeyID int
}

func (f *acctFixture) openEverything(m *member) outstanding {
	f.t.Helper()
	other, err := m.loginPassword(m.s, nil)
	if err != nil {
		f.t.Fatal(err)
	}
	m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(f.stretch(m.addr, "never used")))
	resetID, err := f.acct.ResetBegin(bgctx, m.addr)
	if err != nil {
		f.t.Fatal(err)
	}
	login, err := f.acct.PasswordLoginBegin(bgctx, m.addr)
	if err != nil {
		f.t.Fatal(err)
	}
	return outstanding{other: other, login: login, resetID: resetID,
		stepUps:   f.count(`SELECT count(*) FROM step_up_challenges WHERE user_id = $1 AND used_at IS NULL`, m.user.UserID),
		passkeyID: f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID)}
}

func (f *acctFixture) assertNothingRevoked(m *member, old *authtest.Authenticator, o outstanding, counter uint32) {
	f.t.Helper()
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		f.t.Fatalf("the old session: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, o.other.Session.Token); err != nil {
		f.t.Fatalf("the other session: %v", err)
	}
	if f.count(`SELECT count(*) FROM step_up_challenges WHERE user_id = $1 AND used_at IS NULL`, m.user.UserID) != o.stepUps {
		f.t.Fatal("a pending step-up was ended")
	}
	if f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE id = $1`, o.resetID) != 1 {
		f.t.Fatal("the pending password reset was ended")
	}
	if f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID) != o.passkeyID {
		f.t.Fatal("a passkey was removed")
	}
	if _, err := f.passkeyLogin(old, counter); err != nil {
		f.t.Fatalf("the old passkey: %v", err)
	}
	if _, err := m.loginPassword(m.s, nil); err != nil {
		f.t.Fatalf("the old password: %v", err)
	}
}

func (f *acctFixture) assertOldAccessEnded(m *member, o outstanding) {
	f.t.Helper()
	if _, err := f.sessions.Resolve(bgctx, m.token); !errors.Is(err, ErrSessionRevoked) {
		f.t.Fatalf("the old session: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, o.other.Session.Token); !errors.Is(err, ErrSessionRevoked) {
		f.t.Fatalf("the other session: %v", err)
	}
	if _, err := m.loginPassword(m.s, nil); !errors.Is(err, ErrPasswordRejected) {
		f.t.Fatalf("the old password: %v", err)
	}
	if f.count(`SELECT count(*) FROM step_up_challenges WHERE user_id = $1 AND used_at IS NULL`, m.user.UserID) != 0 {
		f.t.Fatal("a pending step-up survived")
	}
	if f.count(`SELECT count(*) FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, m.user.UserID) != 0 {
		f.t.Fatal("a pending password reset survived")
	}
	if f.count(`SELECT count(*) FROM email_codes WHERE user_id = $1 AND used_at IS NULL AND burned_at IS NULL`, m.user.UserID) != 0 {
		f.t.Fatal("an emailed code survived")
	}
	if f.count(`SELECT count(*) FROM password_login_ceremonies WHERE id = $1 AND used_at IS NULL`, o.login.CeremonyID) != 0 {
		f.t.Fatal("a begun password sign-in survived")
	}
}

func TestPasskeyRecoveryRemovesTheOldPasskeysAndPassword(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	old := f.enrolPasskey(m.user.UserID)
	f.enrolPasskey(m.user.UserID)
	o := f.openEverything(m)
	id, v := f.verifiedRecovery(m, "passkey")
	req, fresh := f.passkeyRecoveryRequest(m, id, v)
	f.fake.Reset()
	out, err := f.acct.RecoverFinish(bgctx, req)
	if err != nil {
		t.Fatal(err)
	}
	f.assertOldAccessEnded(m, o)
	if _, err := f.passkeyLogin(old, 10); !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("the old passkey: %v", err)
	}
	if f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID) != 1 ||
		f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, m.user.UserID, fresh.CredID) != 1 {
		t.Fatal("recovery did not leave exactly the new passkey")
	}
	if f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NULL AND password_set_at IS NULL`, m.user.UserID) != 1 {
		t.Fatal("the old password survived")
	}
	if _, err := f.sessions.Resolve(bgctx, out.Session.Token); err != nil {
		t.Fatalf("the recovery session: %v", err)
	}
	in, err := f.passkeyLogin(fresh, 10)
	if err != nil || in.UserID != m.user.UserID {
		t.Fatalf("the new passkey: %+v %v", in, err)
	}
	if f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'passkey_removed'`, m.user.UserID) != 2 ||
		f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'password_removed'`, m.user.UserID) != 1 {
		t.Fatal("the removals were not recorded")
	}
	f.sendQueued()
	texts := mailTexts(f.fake.To(m.addr))
	if !strings.Contains(texts, "Your old passkeys and your old password were removed") {
		t.Fatal("the recovery alert does not say the old credentials were removed")
	}
	if strings.Contains(texts, "Your Hasala password changed") {
		t.Fatal("recovery sent a separate password alert")
	}
}

func TestPasswordRecoveryRemovesEveryPasskeyAndTheOldPassword(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	old := f.enrolPasskey(m.user.UserID)
	o := f.openEverything(m)
	id, v := f.verifiedRecovery(m, "password")
	newS := f.stretch(m.addr, "a recovered password")
	out, err := f.acct.RecoverFinish(bgctx, f.passwordRecoveryRequest(m, id, v, newS))
	if err != nil {
		t.Fatal(err)
	}
	f.assertOldAccessEnded(m, o)
	if _, err := f.passkeyLogin(old, 10); !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("the old passkey: %v", err)
	}
	if f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID) != 0 {
		t.Fatal("a passkey survived a password recovery")
	}
	if _, err := f.acct.PasswordLoginFinish(bgctx, o.login.CeremonyID, newS, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("a password sign-in begun before the recovery: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, out.Session.Token); err != nil {
		t.Fatalf("the recovery session: %v", err)
	}
	if _, err := m.loginPassword(newS, nil); err != nil {
		t.Fatalf("the new password: %v", err)
	}
	if f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'passkey_removed'`, m.user.UserID) != 1 ||
		f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'password_removed'`, m.user.UserID) != 0 {
		t.Fatal("the removals were not recorded as they happened")
	}
}

func TestARefusedOrAbortedRecoveryRevokesNothing(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	old := f.enrolPasskey(m.user.UserID)
	o := f.openEverything(m)

	id, v := f.verifiedRecovery(m, "passkey")
	req, _ := f.passkeyRecoveryRequest(m, id, v)
	req.RKSig[0] ^= 1
	if _, err := f.acct.RecoverFinish(bgctx, req); !errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a bad rk_sig: %v", err)
	}
	f.assertNothingRevoked(m, old, o, 10)

	f.verifiedRecovery(m, "password")
	f.assertNothingRevoked(m, old, o, 11)

	id, v = f.verifiedRecovery(m, "password")
	if _, err := f.owner.Exec(bgctx, `
		CREATE FUNCTION fail_device_added() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN RAISE EXCEPTION 'injected'; END $$;
		CREATE TRIGGER fail_device_added BEFORE INSERT ON auth_events
		  FOR EACH ROW WHEN (NEW.kind = 'device_added') EXECUTE FUNCTION fail_device_added();`); err != nil {
		t.Fatal(err)
	}
	newS := f.stretch(m.addr, "a recovered password")
	failing := f.passwordRecoveryRequest(m, id, v, newS)
	if _, err := f.acct.RecoverFinish(bgctx, failing); err == nil || errors.Is(err, ErrRecoveryRefused) {
		t.Fatalf("a fault inside the transaction: %v", err)
	}
	if _, err := f.owner.Exec(bgctx, `DROP TRIGGER fail_device_added ON auth_events; DROP FUNCTION fail_device_added();`); err != nil {
		t.Fatal(err)
	}
	f.assertNothingRevoked(m, old, o, 12)
	if f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind IN ('passkey_removed','password_removed','recovery_used')`, m.user.UserID) != 0 {
		t.Fatal("a rolled-back recovery left events")
	}
	if _, err := f.acct.RecoverFinish(bgctx, failing); err != nil {
		t.Fatalf("the released ceremony, again: %v", err)
	}
	if _, err := f.passkeyLogin(old, 13); !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("the old passkey after the retry: %v", err)
	}
}
