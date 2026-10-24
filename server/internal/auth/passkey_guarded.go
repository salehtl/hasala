package auth

// Adding and removing a passkey on a signed-in account (spec 02 #10, #11, #13
// and §10.5; spec 01 §10.7, R-01, D33).
//
// A session alone authorizes neither. With only a session, a thief could
// enrol a passkey of their own and then pass every later passkey step-up with
// it (keys.bootstrap on an account without keys, writer.revoke,
// keys.wrap.delete), or strip the owner's passkeys. So:
//
//   - add/begin (WB) consumes step-up passkey.add, T = (), and stores its
//     nonce as the ceremony's add_nonce, in the step-up's own transaction;
//   - add/finish (WB) verifies the attestation, then dwk_sig under the session
//     writer's DWK over PasskeyAddMessage(add_nonce, SHA256(clientDataJSON),
//     SHA256(attestationObject), SHA256(prf_wrap) or 0^32), rebuilt from the
//     raw posted bytes, and stores the credential and its optional PRF wrap in
//     one transaction. A TLS terminator that swaps in its own credential, or
//     a garbage wrap, has no DWK to sign it with (R-01, N-11);
//   - DELETE consumes step-up passkey.delete, T = (credential_id), and removes
//     the credential inside that step-up's transaction.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// AddBegin is #10: step-up passkey.add, then a registration ceremony whose
// add_nonce is that step-up's nonce. The caller has checked WB; this checks
// it again inside the step-up (a device proof needs the bound writer).
func (p *Passkeys) AddBegin(ctx context.Context, session SessionInfo, su *StepUpObject) (string, *protocol.CredentialCreation, error) {
	if p == nil || p.StepUp == nil {
		return "", nil, errors.New("auth: Passkeys.StepUp is not configured")
	}
	if session.WriterID == "" {
		return "", nil, ErrWriterUnbound
	}
	if su == nil {
		return "", nil, ErrStepUpRequired
	}
	g, err := guardFor(session, keyproto.ActionPasskeyAdd, su)
	if err != nil {
		return "", nil, err
	}
	var (
		id   string
		opts *protocol.CredentialCreation
	)
	err = p.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, proven Proven) error {
		live, err := liveWriterWithDAK(ctx, tx, session.UserID, session.WriterID)
		if err != nil {
			return err
		}
		if !live {
			return ErrWriterUnbound
		}
		id, opts, err = p.beginAdd(ctx, tx, session.UserID, proven.Nonce)
		return err
	})
	if err != nil {
		return "", nil, err
	}
	return id, opts, nil
}

// PasskeyAdd is #11's request, decoded.
type PasskeyAdd struct {
	CeremonyID string
	Credential []byte // the raw PublicKeyCredential JSON
	// PRFCredentialID and PRFWrap are prf_wrap; both nil when it was null.
	PRFCredentialID []byte
	PRFWrap         []byte
	PRFWrapVersion  int
	DWKSig          []byte
}

// AddFinish is #11. It answers the new credential's id.
func (p *Passkeys) AddFinish(ctx context.Context, session SessionInfo, a PasskeyAdd) ([]byte, error) {
	if p == nil || p.Pool == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	if session.WriterID == "" {
		return nil, ErrWriterUnbound
	}
	hasWrap := a.PRFWrap != nil || a.PRFCredentialID != nil
	if hasWrap {
		if err := keyproto.CheckCredentialID(a.PRFCredentialID); err != nil {
			return nil, fmt.Errorf("%w: prf_wrap.credential_id: %v", ErrKeysMalformed, err)
		}
		if err := keyproto.CheckPRFWrap(a.PRFWrap); err != nil {
			return nil, fmt.Errorf("%w: prf_wrap.wrap: %v", ErrKeysMalformed, err)
		}
		if a.PRFWrapVersion != 1 {
			return nil, fmt.Errorf("%w: prf_wrap.wrap_version %d", ErrKeysMalformed, a.PRFWrapVersion)
		}
	}
	if len(a.DWKSig) != keyproto.Ed25519SigSize {
		return nil, fmt.Errorf("%w: dwk_sig is %d bytes", ErrBadSignature, len(a.DWKSig))
	}

	made, c, err := p.verifyAdd(ctx, a.CeremonyID, session.UserID, a.Credential)
	if err != nil {
		return nil, err
	}
	if len(c.AddNonce) != keyproto.NonceSize {
		// The CHECK makes this unreachable; an add ceremony without its step-up
		// nonce authorizes nothing.
		return nil, fmt.Errorf("%w: the add ceremony carries no step-up nonce", ErrPasskeyRejected)
	}
	credID := made.Credential.ID
	if hasWrap && !bytes.Equal(a.PRFCredentialID, credID) {
		return nil, fmt.Errorf("%w: prf_wrap.credential_id is not the new credential", ErrKeysMalformed)
	}

	tx, err := pgtx.BeginReadCommitted(ctx, p.Pool)
	if err != nil {
		return nil, fmt.Errorf("auth: passkey add: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	// The session writer, live, under a share lock: a revoke that commits
	// first makes this fail, one that comes second waits for the credential.
	var (
		dwk  []byte
		live bool
	)
	err = tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2 FOR SHARE`,
		session.UserID, session.WriterID).Scan(&dwk, &live)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !live) {
		return nil, ErrWriterUnbound
	}
	if err != nil {
		return nil, fmt.Errorf("auth: passkey add: read writer: %w", err)
	}
	msg, err := keyproto.PasskeyAddMessage(c.AddNonce, made.ClientDataJSON, made.AttestationObject, a.PRFWrap)
	if err != nil || !keyproto.VerifyEd25519(dwk, msg, a.DWKSig) {
		return nil, fmt.Errorf("%w: dwk_sig over PasskeyAddMessage", ErrBadSignature)
	}
	if err := insertCredential(ctx, tx, storedCredential{
		UserID:            session.UserID,
		UserHandle:        c.UserHandle,
		Credential:        *made.Credential,
		AttestationSHA256: made.AttestationSHA256,
	}, p.now().UTC()); err != nil {
		return nil, err
	}
	if hasWrap {
		if _, err := tx.Exec(ctx,
			`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at)
			 VALUES ($1, $2, $3, 1, $4)`,
			session.UserID, credID, a.PRFWrap, p.now()); err != nil {
			return nil, fmt.Errorf("auth: passkey add: store wrap: %w", err)
		}
	}
	if err := recordEventTx(ctx, tx, p.Mail, session.UserID, AuthEvent{Kind: EventPasskeyAdded, CredentialID: credID,
		WriterID: session.WriterID}, p.now()); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("auth: passkey add: commit: %w", err)
	}
	p.Mail.Kick()
	return credID, nil
}

// DeletePasskey is #13: step-up passkey.delete, T = (credential_id), then the
// removal in that step-up's transaction. A refusal after a good proof
// (ErrLastPasskey, ErrCredentialUnknown) leaves the nonce usable (spec 02
// §8.1, AT-SU-8). It reports how many sessions it revoked.
func (p *Passkeys) DeletePasskey(ctx context.Context, session SessionInfo, credentialID []byte, su *StepUpObject) (int64, error) {
	if p == nil || p.StepUp == nil {
		return 0, errors.New("auth: Passkeys.StepUp is not configured")
	}
	if len(credentialID) == 0 {
		return 0, ErrCredentialUnknown
	}
	if su == nil {
		return 0, ErrStepUpRequired
	}
	g, err := guardFor(session, keyproto.ActionPasskeyDelete, su, credentialID)
	if err != nil {
		return 0, err
	}
	var (
		revoked   int64
		removedAt time.Time
	)
	err = p.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		var err error
		removedAt = p.now()
		if err := refuseIfLastUnseenWrapTx(ctx, tx, session.UserID, credentialID); err != nil {
			return err
		}
		revoked, err = deleteCredentialTx(ctx, tx, session.UserID, credentialID, session.Hash, removedAt)
		if err != nil {
			return err
		}
		return recordEventTx(ctx, tx, p.Mail, session.UserID, AuthEvent{Kind: EventPasskeyRemoved, CredentialID: credentialID}, p.now())
	})
	if err != nil {
		return revoked, err
	}
	recordPasskeyRemovals(p.Record, session.UserID, [][]byte{credentialID}, removedAt)
	return revoked, nil
}
