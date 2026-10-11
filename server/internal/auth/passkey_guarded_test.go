package auth

// Tests for passkey_guarded.go: adding and removing a passkey need more than a
// session (spec 02 #10, #11, #13, §10.5; spec 01 §10.7, R-01). The reviewer's
// attack is the reason: a stolen session that could enrol its own passkey
// would pass every later passkey step-up with it.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// testBeginAdd and testFinishAdd drive the add ceremony's WebAuthn half
// without the step-up and the DWK signature, for the tests about handles,
// credentials and sessions that predate them. A request cannot reach either:
// the HTTP routes call AddBegin and AddFinish.
func (p *Passkeys) testBeginAdd(t *testing.T, userID uuid.UUID) (string, *protocol.CredentialCreation, error) {
	t.Helper()
	return p.beginAdd(bgctx, p.Pool, userID, authtest.RandBytesTB(t, keyproto.NonceSize))
}

func (p *Passkeys) testFinishAdd(ctx context.Context, ceremonyID string, userID uuid.UUID, response []byte) ([]byte, error) {
	made, c, err := p.verifyAdd(ctx, ceremonyID, userID, response)
	if err != nil {
		return nil, err
	}
	if err := insertCredential(ctx, p.Pool, storedCredential{UserID: userID, UserHandle: c.UserHandle,
		Credential: *made.Credential, AttestationSHA256: made.AttestationSHA256}, p.now().UTC()); err != nil {
		return nil, err
	}
	return made.Credential.ID, nil
}

// deleteCredential is deleteCredentialTx in a transaction of its own. Tests
// only: a request reaches the removal through DeletePasskey, under step-up.
func (p *Passkeys) deleteCredential(ctx context.Context, userID uuid.UUID, credentialID, keepSessionHash []byte) (int64, error) {
	if p == nil || p.Pool == nil {
		return 0, errors.New("auth: Passkeys is not configured")
	}
	// READ COMMITTED pinned rather than inherited, for the reason upsertUser
	// pins it: default_transaction_isolation is settable per database, per role
	// and by a pooler, and the lock-then-count relies on a waiter taking a
	// FRESH snapshot when the lock is released. Under REPEATABLE READ the second
	// transaction would wake up and still see the row the first one deleted,
	// which is precisely the miscount this lock exists to prevent. StepUp.Run
	// pins it the same way (pgtx.BeginReadCommitted).
	tx, err := p.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: begin: %w", err)
	}
	defer func() {
		rbCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(rbCtx)
	}()
	revoked, err := deleteCredentialTx(ctx, tx, userID, credentialID, keepSessionHash, p.now())
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: commit: %w", err)
	}
	return revoked, nil
}
// guarded wires the fixture's step-up into its relying party, as
// api.NewServer does.
func (f *keyFixture) guarded() *keyFixture {
	f.passkeys.StepUp = f.stepUp
	return f
}

// addSig is the device's dwk_sig over PasskeyAddMessage for the credential a
// just created.
func addSig(t *testing.T, d *authtest.Device, nonce []byte, a *authtest.Authenticator, wrap []byte) []byte {
	t.Helper()
	m, err := keyproto.PasskeyAddMessage(nonce, a.LastClientDataJSON, a.LastAttestationObject, wrap)
	if err != nil {
		t.Fatal(err)
	}
	return ed25519.Sign(d.DWK, m)
}

func wellFormedWrap(fill byte) []byte { return append([]byte{1, 2}, bytes.Repeat([]byte{fill}, 125)...) }

// addOver runs #10 and #11 on token's session with the device's DWK, and
// answers the new authenticator and AddFinish's outcome.
func (f *keyFixture) addOver(token string, signer *authtest.Device, wrap bool) (*authtest.Authenticator, []byte, error) {
	f.t.Helper()
	su := f.stepUpPasskey(token, keyproto.ActionPasskeyAdd)
	id, opts, err := f.passkeys.AddBegin(bgctx, f.info(token), su)
	if err != nil {
		return nil, nil, err
	}
	a := authtest.New(f.t)
	resp := a.Create(f.t, opts)
	add := PasskeyAdd{CeremonyID: id, Credential: resp}
	var w []byte
	if wrap {
		w = wellFormedWrap(7)
		add.PRFCredentialID, add.PRFWrap, add.PRFWrapVersion = a.CredID, w, 1
	}
	add.DWKSig = addSig(f.t, signer, su.Nonce, a, w)
	cred, err := f.passkeys.AddFinish(bgctx, f.info(token), add)
	return a, cred, err
}

func TestAddingAPasskeyNeedsTheStepUpAndTheSessionWritersSignature(t *testing.T) {
	f := newKeyFixture(t).guarded()

	a, cred, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatalf("add with step-up and DWK: %v", err)
	}
	if !bytes.Equal(cred, a.CredID) {
		t.Fatal("AddFinish named a different credential")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, f.user, cred); n != 1 {
		t.Fatalf("%d PRF wraps for the new credential, want 1 (stored in the same transaction)", n)
	}
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE user_id = $1 AND action = 'passkey.add' AND used_at IS NOT NULL`, f.user); n != 1 {
		t.Fatalf("%d spent passkey.add nonces, want 1", n)
	}
}

func TestAddBeginWithoutAStepUpIsRefusedAndMintsNoCeremony(t *testing.T) {
	f := newKeyFixture(t).guarded()
	if _, _, err := f.passkeys.AddBegin(bgctx, f.info(f.token), nil); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("add/begin with no step-up: %v, want ErrStepUpRequired", err)
	}
	// A step-up for another action does not open an add ceremony.
	su := f.stepUpPasskey(f.token, keyproto.ActionKeysWrapDelete, f.credID)
	if _, _, err := f.passkeys.AddBegin(bgctx, f.info(f.token), su); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("add/begin with a keys.wrap.delete step-up: %v, want ErrStepUpFailed", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_ceremonies WHERE kind = 'add'`); n != 0 {
		t.Fatalf("%d add ceremonies exist, want 0", n)
	}
}

// TestAStolenSessionCannotEnrolAPasskeyBeforeBootstrap is the review's
// exploit: between register/finish and bootstrap the account has no keys and
// no writer, so a session alone used to be enough to enrol a passkey and then
// prove keys.bootstrap with it. An unbound session cannot begin an add.
func TestAStolenSessionCannotEnrolAPasskeyBeforeBootstrap(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t).guarded()
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd)
	if _, _, err := f.passkeys.AddBegin(bgctx, f.info(f.token), su); !errors.Is(err, ErrWriterUnbound) {
		t.Fatalf("add/begin on an unbound session: %v, want ErrWriterUnbound", err)
	}
	// And the nonce cannot be spent by an unbound add/finish either: there is
	// no ceremony.
	if n := f.count(`SELECT count(*) FROM webauthn_ceremonies WHERE kind = 'add'`); n != 0 {
		t.Fatalf("%d add ceremonies exist, want 0", n)
	}
}

func TestAddFinishRefusesASignatureFromAnyKeyButTheSessionWriters(t *testing.T) {
	f := newKeyFixture(t).guarded()
	stranger := authtest.NewDevice(t)
	_, _, err := f.addOver(f.token, stranger, true)
	if !errors.Is(err, ErrBadSignature) {
		t.Fatalf("add/finish signed by a stranger's DWK: %v, want ErrBadSignature", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, f.user); n != 1 {
		t.Fatalf("%d credentials after a refused add, want 1", n)
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, f.user); n != 1 {
		t.Fatalf("%d wraps after a refused add, want the bootstrap's 1", n)
	}
}

// TestAddFinishRefusesASwappedWrapOrCredential: R-01 and N-11. A terminator
// that substitutes the wrap (or the credential) changes a hash the DWK signed.
func TestAddFinishRefusesASwappedWrapOrCredential(t *testing.T) {
	f := newKeyFixture(t).guarded()
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd)
	id, opts, err := f.passkeys.AddBegin(bgctx, f.info(f.token), su)
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	resp := a.Create(t, opts)
	signed := wellFormedWrap(7)
	add := PasskeyAdd{CeremonyID: id, Credential: resp, PRFCredentialID: a.CredID, PRFWrap: wellFormedWrap(8),
		PRFWrapVersion: 1, DWKSig: addSig(t, f.device, su.Nonce, a, signed)}
	if _, err := f.passkeys.AddFinish(bgctx, f.info(f.token), add); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("add/finish with a swapped wrap: %v, want ErrBadSignature", err)
	}
	// A wrap posted when the signature covered none is the same swap.
	su = f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd)
	id, opts, err = f.passkeys.AddBegin(bgctx, f.info(f.token), su)
	if err != nil {
		t.Fatal(err)
	}
	b := authtest.New(t)
	resp = b.Create(t, opts)
	add = PasskeyAdd{CeremonyID: id, Credential: resp, PRFCredentialID: b.CredID, PRFWrap: signed,
		PRFWrapVersion: 1, DWKSig: addSig(t, f.device, su.Nonce, b, nil)}
	if _, err := f.passkeys.AddFinish(bgctx, f.info(f.token), add); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("add/finish with a wrap the signature did not cover: %v, want ErrBadSignature", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, f.user); n != 1 {
		t.Fatalf("%d credentials, want 1", n)
	}
}

func TestAddFinishRefusesAWrapForAnotherCredential(t *testing.T) {
	f := newKeyFixture(t).guarded()
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd)
	id, opts, err := f.passkeys.AddBegin(bgctx, f.info(f.token), su)
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	resp := a.Create(t, opts)
	w := wellFormedWrap(7)
	add := PasskeyAdd{CeremonyID: id, Credential: resp, PRFCredentialID: f.credID, PRFWrap: w,
		PRFWrapVersion: 1, DWKSig: addSig(t, f.device, su.Nonce, a, w)}
	if _, err := f.passkeys.AddFinish(bgctx, f.info(f.token), add); !errors.Is(err, ErrKeysMalformed) {
		t.Fatalf("add/finish whose prf_wrap names the old credential: %v, want ErrKeysMalformed", err)
	}
}

func TestAddFinishOnARevokedWriterIsRefused(t *testing.T) {
	f := newKeyFixture(t).guarded()
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyAdd)
	id, opts, err := f.passkeys.AddBegin(bgctx, f.info(f.token), su)
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	resp := a.Create(t, opts)
	if _, err := f.owner.Exec(bgctx, `UPDATE writers SET revoked_at = now() WHERE user_id = $1`, f.user); err != nil {
		t.Fatal(err)
	}
	add := PasskeyAdd{CeremonyID: id, Credential: resp, DWKSig: addSig(t, f.device, su.Nonce, a, nil)}
	if _, err := f.passkeys.AddFinish(bgctx, f.info(f.token), add); !errors.Is(err, ErrWriterUnbound) {
		t.Fatalf("add/finish after the session's writer was revoked: %v, want ErrWriterUnbound", err)
	}
}

func TestDeletingAPasskeyNeedsAStepUpForThatCredential(t *testing.T) {
	f := newKeyFixture(t).guarded()
	second, _, err := f.addOver(f.token, f.device, false)
	if err != nil {
		t.Fatal(err)
	}
	info := f.info(f.token)
	if _, err := f.passkeys.DeletePasskey(bgctx, info, second.CredID, nil); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("delete with no step-up: %v, want ErrStepUpRequired", err)
	}
	// A step-up for the OTHER credential does not remove this one.
	wrong := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, f.credID)
	if _, err := f.passkeys.DeletePasskey(bgctx, info, second.CredID, wrong); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("delete with another credential's step-up: %v, want ErrStepUpFailed", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, f.user); n != 2 {
		t.Fatalf("%d credentials, want 2", n)
	}
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, second.CredID)
	if _, err := f.passkeys.DeletePasskey(bgctx, info, second.CredID, su); err != nil {
		t.Fatalf("delete with its step-up: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, f.user); n != 1 {
		t.Fatalf("%d credentials, want 1", n)
	}
}

// TestRefusingTheLastPasskeyLeavesTheNonceUsable is spec 02 §8.1 5.5 (AT-SU-8):
// an action refused after a good proof does not burn the step-up.
func TestRefusingTheLastPasskeyLeavesTheNonceUsable(t *testing.T) {
	f := newKeyFixture(t).guarded()
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, f.credID)
	if _, err := f.passkeys.DeletePasskey(bgctx, f.info(f.token), f.credID, su); !errors.Is(err, ErrLastPasskey) {
		t.Fatalf("delete of the last passkey: %v, want ErrLastPasskey", err)
	}
	if n := f.count(`SELECT count(*) FROM step_up_challenges WHERE nonce = $1 AND used_at IS NULL`, su.Nonce); n != 1 {
		t.Fatal("the passkey.delete nonce was spent by a refused action")
	}
}
