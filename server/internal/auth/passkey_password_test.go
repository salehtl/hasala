package auth

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestAPasswordAccountAddsAPasskeyWithItsPasswordAndApprovalKey(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")

	su := m.deviceStepUp(keyproto.ActionPasskeyAdd, m.s)
	id, opts, err := f.passkeys.AddBegin(bgctx, m.info(), su)
	if err != nil {
		t.Fatalf("add/begin with a device proof: %v", err)
	}
	a := authtest.New(t)
	resp := a.Create(t, opts)
	wrap := wellFormedWrap(3)
	add := PasskeyAdd{CeremonyID: id, Credential: resp, PRFCredentialID: a.CredID, PRFWrap: wrap, PRFWrapVersion: 1,
		DWKSig: addSig(t, m.device, su.Nonce, a, wrap)}
	cred, err := f.passkeys.AddFinish(bgctx, m.info(), add)
	if err != nil {
		t.Fatalf("add/finish: %v", err)
	}
	if !bytes.Equal(cred, a.CredID) {
		t.Fatal("AddFinish named a different credential")
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID); n != 1 {
		t.Fatalf("%d credentials, want 1", n)
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, m.user.UserID, cred); n != 1 {
		t.Fatalf("%d PRF wraps for the new credential, want 1", n)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NOT NULL`, m.user.UserID); n != 1 {
		t.Fatal("adding a passkey removed the password")
	}

	i := m.info()
	ph, _ := keyproto.ParamsHash(keyproto.ActionSessionLogoutAll)
	b, err := f.stepUp.Begin(bgctx, i.UserID, i.Hash, i.WriterID, keyproto.ActionSessionLogoutAll, ph[:], keyproto.ProofPasskey)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.AllowCredentials) != 1 || !bytes.Equal(b.AllowCredentials[0], cred) {
		t.Fatal("a passkey step-up does not offer the new credential")
	}
	passkeyProof := &StepUpObject{Nonce: b.Nonce, Proof: StepUpProof{Kind: "passkey",
		Assertion: a.AssertChallenge(t, authtest.RPID, b.Challenge[:], 2)}}
	g := Guarded{UserID: i.UserID, SessionHash: i.Hash, BoundWriter: i.WriterID, Action: keyproto.ActionSessionLogoutAll,
		ParamsHash: ph, StepUp: passkeyProof}
	if err := f.stepUp.Run(bgctx, g, func(context.Context, pgx.Tx, Proven) error { return nil }); err != nil {
		t.Fatalf("a passkey step-up with the new credential: %v", err)
	}
}

func TestAPasswordAccountsWrongPasswordAddsNoPasskey(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")

	su := m.deviceStepUp(keyproto.ActionPasskeyAdd, f.stretch(m.addr, "not the password"))
	if _, _, err := f.passkeys.AddBegin(bgctx, m.info(), su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("add/begin with a wrong password: %v, want ErrStepUpFailed", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_ceremonies WHERE kind = 'add'`); n != 0 {
		t.Fatalf("%d add ceremonies exist, want 0", n)
	}
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NOT NULL`, su.Nonce); n != 1 {
		t.Fatal("the failed proof's nonce is not burned")
	}
	if _, _, err := f.passkeys.AddBegin(bgctx, m.info(), su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("the burned nonce again: %v, want ErrStepUpFailed", err)
	}
}
