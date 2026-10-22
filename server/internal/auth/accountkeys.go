package auth

// The account's key material (spec 01 §4–§5, §10.3, §10.7; spec 02 §10.1,
// §10.5): the atomic bootstrap, GET /keys and the PRF wraps.
//
// The server stores opaque bytes. It checks lengths and header bytes, rebuilds
// the canonical BootstrapPayload v1 from the request's fields and verifies the
// AAK's signatures over it; it never opens a wrap or the phrase box, and holds
// no key that could (spec 02 §4.4 fence 3).
//
// # Who may bootstrap
//
//   - The key bound into the account-creating passkey ceremony: when the posted
//     authority_pubkey is users.authority_pubkey_pending (set by register/finish
//     from C_reg's key), no step-up is needed, but auth_kind must be 0x01 with
//     auth_hash = the creating credential's attestation_sha256 (R-01), so a TLS
//     terminator that swapped the credential fails here, visibly.
//   - Any other key needs step-up keys.bootstrap with T = (authority_pubkey),
//     and auth_kind 0x00 with auth_hash = 0^32 (the interrupted-onboarding
//     path, spec 01 §10.3).
//   - auth_kind 0x02 exists only inside the password signup, which this route
//     refuses.
//
// The bootstrap also registers the first writer under the same nonce, with an
// AAK RegistrationMessage stored in key_history (never the bootstrap
// signature, which no device could verify as a registration).

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// Account-key errors, mapped by the HTTP layer.
var (
	ErrKeysExist     = errors.New("auth: the account already has keys")       // 409 keys_exist
	ErrKeysMalformed = errors.New("auth: key material is malformed")          // 400 bad_request
	ErrNotYours      = errors.New("auth: no such credential on this account") // 404 not_found
	ErrNoKeys        = errors.New("auth: the account has no keys")            // 404 no_keys
)

// AccountKeys owns account_keys and account_key_wraps.
type AccountKeys struct {
	Pool   *pgxpool.Pool
	StepUp *StepUp
	Now    func() time.Time
}

func (k *AccountKeys) now() time.Time {
	if k.Now != nil {
		return k.Now()
	}
	return time.Now()
}

// Bootstrap is POST /api/v1/account/bootstrap's request (spec 02 §10.1),
// decoded from b64.
type Bootstrap struct {
	FormatVersion   int
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
	RecoveryWrap    []byte
	PhraseBox       []byte
	EmailHash       []byte
	AuthKind        int
	AuthHash        []byte
	PRFCredentialID []byte // nil: no PRF wrap
	PRFWrap         []byte
	PRFWrapVersion  int
	Writer          Registration // Nonce and Sig: the writer nonce and registration_sig
	AuthoritySig    []byte
	StepUp          *StepUpObject
	PhraseUnseen    bool
}

// Bootstrapped is the 201 answer.
type Bootstrapped struct {
	WriterID     string
	CurrentEpoch int
}

// Bootstrap runs spec 01 §10.3.2's checks in spec 02 §10.1's order and then
// one transaction (§10.3.3).
func (k *AccountKeys) Bootstrap(ctx context.Context, session SessionInfo, b Bootstrap) (Bootstrapped, error) {
	if k.Pool == nil {
		return Bootstrapped{}, errors.New("auth: AccountKeys.Pool is nil")
	}
	userID := session.UserID
	// 2. No keys yet.
	var exists bool
	if err := k.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM account_keys WHERE user_id = $1)`, userID).Scan(&exists); err != nil {
		return Bootstrapped{}, fmt.Errorf("auth: bootstrap: %w", err)
	}
	if exists {
		return Bootstrapped{}, ErrKeysExist
	}
	// 3. Decode and rebuild the canonical payload.
	if b.FormatVersion != keyproto.BootstrapPayloadVersion {
		return Bootstrapped{}, fmt.Errorf("%w: format_version %d", ErrKeysMalformed, b.FormatVersion)
	}
	if !keyproto.ValidWriterID(b.Writer.WriterID) {
		return Bootstrapped{}, ErrBadWriterID
	}
	if b.Writer.Alg != AlgEd25519 {
		return Bootstrapped{}, fmt.Errorf("%w: writer.alg is not Ed25519", ErrKeysMalformed)
	}
	if b.AuthKind < 0 || b.AuthKind > int(keyproto.AuthKindPassword) {
		return Bootstrapped{}, fmt.Errorf("%w: auth_kind %d", ErrKeysMalformed, b.AuthKind)
	}
	if b.PRFCredentialID != nil && b.PRFWrapVersion != 1 {
		return Bootstrapped{}, fmt.Errorf("%w: prf_wrap.wrap_version %d", ErrKeysMalformed, b.PRFWrapVersion)
	}
	pl := keyproto.BootstrapPayload{
		UserID: userID, AMKCommitment: b.AMKCommitment, AuthorityPubkey: b.AuthorityPubkey,
		RecoveryPubkey: b.RecoveryPubkey, RecoveryWrap: b.RecoveryWrap, PhraseBox: b.PhraseBox,
		EmailHash: b.EmailHash, AuthKind: byte(b.AuthKind), AuthHash: b.AuthHash,
		WriterPubkey: b.Writer.PubKey, WriterDAK: b.Writer.DAKPubkey, WriterID: b.Writer.WriterID,
		CredentialID: b.PRFCredentialID, PRFWrap: b.PRFWrap,
	}
	payload, err := pl.Bytes()
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := pl.CheckKeys(); err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if len(b.AuthoritySig) != keyproto.Ed25519SigSize || len(b.Writer.Sig) != keyproto.Ed25519SigSize {
		return Bootstrapped{}, fmt.Errorf("%w: a signature is not 64 bytes", ErrBadSignature)
	}
	var (
		emailNorm *string
		pending   []byte
		frozen    bool
	)
	if err := k.Pool.QueryRow(ctx, `SELECT email_norm, authority_pubkey_pending, frozen_at IS NOT NULL FROM users WHERE id = $1`, userID).
		Scan(&emailNorm, &pending, &frozen); err != nil {
		return Bootstrapped{}, fmt.Errorf("auth: bootstrap: read account: %w", err)
	}
	if frozen {
		return Bootstrapped{}, ErrAccountFrozen
	}
	if b.PRFCredentialID != nil {
		var mine bool
		if err := k.Pool.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2)`,
			userID, b.PRFCredentialID).Scan(&mine); err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: %w", err)
		}
		if !mine {
			return Bootstrapped{}, ErrNotYours
		}
	}
	// The address binding: a terminator that swapped the address at signup is
	// caught here. An account with no address cannot bootstrap.
	if emailNorm == nil {
		return Bootstrapped{}, fmt.Errorf("%w: the account has no address to bind", ErrKeysMalformed)
	}
	if want := keyproto.EmailHash(*emailNorm); !bytes.Equal(want[:], b.EmailHash) {
		return Bootstrapped{}, fmt.Errorf("%w: email_hash is not the account's address", ErrKeysMalformed)
	}
	// 4. Authorization.
	pendingPath := pending != nil && bytes.Equal(pending, b.AuthorityPubkey)
	switch {
	case byte(b.AuthKind) == keyproto.AuthKindPassword:
		return Bootstrapped{}, fmt.Errorf("%w: auth_kind 2 exists only inside the password signup", ErrKeysMalformed)
	case pendingPath:
		if byte(b.AuthKind) != keyproto.AuthKindPasskey {
			return Bootstrapped{}, fmt.Errorf("%w: the pending authority key bootstraps with auth_kind 1", ErrKeysMalformed)
		}
		var att []byte
		if err := k.Pool.QueryRow(ctx,
			`SELECT attestation_sha256 FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id LIMIT 1`,
			userID).Scan(&att); err != nil || !bytes.Equal(att, b.AuthHash) {
			return Bootstrapped{}, fmt.Errorf("%w: auth_hash is not the creating credential's attestation", ErrKeysMalformed)
		}
	default:
		if byte(b.AuthKind) != keyproto.AuthKindNone || !bytes.Equal(b.AuthHash, make([]byte, 32)) {
			return Bootstrapped{}, fmt.Errorf("%w: a stepped-up bootstrap carries auth_kind 0 and a zero auth_hash", ErrKeysMalformed)
		}
		if b.StepUp == nil {
			return Bootstrapped{}, ErrStepUpRequired
		}
	}
	if b.PhraseUnseen {
		if !pendingPath || b.PRFCredentialID == nil {
			return Bootstrapped{}, fmt.Errorf("%w: phrase_unseen needs the creating passkey and its PRF wrap", ErrKeysMalformed)
		}
		var synced bool
		if err := k.Pool.QueryRow(ctx,
			`SELECT backup_eligible AND backup_state FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`,
			userID, b.PRFCredentialID).Scan(&synced); err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: %w", err)
		}
		if !synced {
			return Bootstrapped{}, fmt.Errorf("%w: phrase_unseen needs a synced passkey", ErrKeysMalformed)
		}
	}
	// 5. The writer nonce, spent by the attempt.
	if err := consumeChallenge(ctx, k.Pool, k.now(), userID, b.Writer.Nonce); err != nil {
		return Bootstrapped{}, err
	}
	// 6. The AAK's two signatures over the same nonce.
	bm, err := keyproto.BootstrapMessage(b.Writer.Nonce, payload)
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	rm, err := keyproto.RegistrationMessage(b.Writer.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if !keyproto.VerifyEd25519(b.AuthorityPubkey, bm, b.AuthoritySig) ||
		!keyproto.VerifyEd25519(b.AuthorityPubkey, rm, b.Writer.Sig) {
		return Bootstrapped{}, fmt.Errorf("%w: authority_sig or registration_sig", ErrBadSignature)
	}

	var viaPending []byte // the pending key this bootstrap was authorized by
	if pendingPath {
		viaPending = pending
	}
	write := func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		return k.bootstrapTx(ctx, tx, session, b, viaPending)
	}
	if pendingPath {
		tx, err := pgtx.BeginReadCommitted(ctx, k.Pool)
		if err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: begin: %w", err)
		}
		defer pgtx.Rollback(ctx, tx)
		if err := write(ctx, tx, Proven{}); err != nil {
			return Bootstrapped{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: commit: %w", err)
		}
	} else {
		if k.StepUp == nil {
			return Bootstrapped{}, errors.New("auth: AccountKeys.StepUp is nil")
		}
		ph, err := keyproto.ParamsHash(keyproto.ActionKeysBootstrap, b.AuthorityPubkey)
		if err != nil {
			return Bootstrapped{}, err
		}
		g := Guarded{UserID: userID, SessionHash: session.Hash, BoundWriter: session.WriterID,
			Action: keyproto.ActionKeysBootstrap, ParamsHash: ph, StepUp: b.StepUp}
		if err := k.StepUp.Run(ctx, g, write); err != nil {
			return Bootstrapped{}, err
		}
	}
	return Bootstrapped{WriterID: b.Writer.WriterID, CurrentEpoch: 1}, nil
}

// bootstrapTx is spec 01 §10.3.3: account_keys, the PRF wrap, the writer and
// its key_history row, the pending key cleared, account_usage, the binding.
// viaPending is the pending authority key that authorized a step-up-free
// bootstrap (nil for a stepped-up one): the pending key and the attestation
// were read outside this transaction, so the clear re-checks that very key
// and requires one row.
func (k *AccountKeys) bootstrapTx(ctx context.Context, tx pgx.Tx, session SessionInfo, b Bootstrap, viaPending []byte) error {
	userID := session.UserID
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	now := k.now()
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at, phrase_seen_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, $7, $7, CASE WHEN $8::boolean THEN NULL ELSE $7::timestamptz END)`,
		userID, b.AMKCommitment, b.AuthorityPubkey, b.RecoveryPubkey, b.RecoveryWrap, b.PhraseBox, now, b.PhraseUnseen); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			if pg.ConstraintName == "account_keys_pkey" {
				return ErrKeysExist
			}
			return fmt.Errorf("%w: the authority or recovery key is already in use", ErrKeysMalformed)
		}
		return fmt.Errorf("auth: bootstrap: insert account_keys: %w", err)
	}
	if b.PRFCredentialID != nil {
		if _, err := tx.Exec(ctx,
			`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at) VALUES ($1,$2,$3,1,$4)`,
			userID, b.PRFCredentialID, b.PRFWrap, now); err != nil {
			return fmt.Errorf("auth: bootstrap: insert the PRF wrap: %w", err)
		}
	}
	if err := insertWriterTx(ctx, tx, userID, b.Writer, now); err != nil {
		return err
	}
	if err := recordEventTx(ctx, tx, nil, userID, AuthEvent{Kind: EventDeviceAdded, WriterID: b.Writer.WriterID}, now); err != nil {
		return err
	}
	if viaPending != nil {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET authority_pubkey_pending = NULL WHERE id = $1 AND authority_pubkey_pending = $2`, userID, viaPending)
		if err != nil {
			return fmt.Errorf("auth: bootstrap: clear the pending authority key: %w", err)
		}
		if tag.RowsAffected() != 1 {
			return fmt.Errorf("%w: the pending authority key changed during the bootstrap", ErrKeysMalformed)
		}
	} else if _, err := tx.Exec(ctx,
		`UPDATE users SET authority_pubkey_pending = NULL WHERE id = $1 AND authority_pubkey_pending IS NOT NULL`, userID); err != nil {
		return fmt.Errorf("auth: bootstrap: clear the pending authority key: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_usage (user_id, resource, amount) VALUES ($1, 'oplog_hot_bytes', 0) ON CONFLICT DO NOTHING`, userID); err != nil {
		return fmt.Errorf("auth: bootstrap: account_usage: %w", err)
	}
	return bindSessionTx(ctx, tx, session.Hash, userID, b.Writer.WriterID)
}

// Keys is GET /api/v1/keys (#17): never the phrase box.
type Keys struct {
	FormatVersion   int
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
	RecoveryWrap    []byte
	CurrentEpoch    int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// Read returns the account's keys or ErrNoKeys.
func (k *AccountKeys) Read(ctx context.Context, userID uuid.UUID) (Keys, error) {
	var out Keys
	err := k.Pool.QueryRow(ctx,
		`SELECT format_version, amk_commitment, authority_pubkey, recovery_pubkey, recovery_wrap, current_epoch, created_at, updated_at
		   FROM account_keys WHERE user_id = $1`, userID).
		Scan(&out.FormatVersion, &out.AMKCommitment, &out.AuthorityPubkey, &out.RecoveryPubkey, &out.RecoveryWrap,
			&out.CurrentEpoch, &out.CreatedAt, &out.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Keys{}, ErrNoKeys
	}
	if err != nil {
		return Keys{}, fmt.Errorf("auth: read keys: %w", err)
	}
	return out, nil
}

// Wrap is one PRF wrap (#19).
type Wrap struct {
	CredentialID []byte
	Wrap         []byte
	WrapVersion  int
	CreatedAt    time.Time
}

// Wraps lists the account's PRF wraps.
func (k *AccountKeys) Wraps(ctx context.Context, userID uuid.UUID) ([]Wrap, error) {
	rows, err := k.Pool.Query(ctx,
		`SELECT credential_id, wrap, wrap_version, created_at FROM account_key_wraps WHERE user_id = $1 ORDER BY created_at, credential_id`,
		userID)
	if err != nil {
		return nil, fmt.Errorf("auth: read wraps: %w", err)
	}
	defer rows.Close()
	out := []Wrap{}
	for rows.Next() {
		var w Wrap
		if err := rows.Scan(&w.CredentialID, &w.Wrap, &w.WrapVersion, &w.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// WrapPut is POST /api/v1/keys/wraps (#20), decoded.
type WrapPut struct {
	CredentialID []byte
	Wrap         []byte
	WrapVersion  int
	DWKSig       []byte
	StepUp       *StepUpObject
}

// PutWrap stores one credential's PRF wrap under step-up keys.wrap.put: a
// passkey proof whose asserting credential is the wrap's own, and the session
// writer's DWK over WrapPutMessage(step_up.nonce, SHA256(credential_id),
// SHA256(wrap)) (spec 01 §10.7, N-11). The session must be bound to a live
// writer (the caller checks WB).
func (k *AccountKeys) PutWrap(ctx context.Context, session SessionInfo, p WrapPut) error {
	if err := keyproto.CheckCredentialID(p.CredentialID); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := keyproto.CheckPRFWrap(p.Wrap); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if p.WrapVersion != 1 {
		return fmt.Errorf("%w: wrap_version %d", ErrKeysMalformed, p.WrapVersion)
	}
	if len(p.DWKSig) != keyproto.Ed25519SigSize {
		return fmt.Errorf("%w: dwk_sig is %d bytes", ErrBadSignature, len(p.DWKSig))
	}
	if p.StepUp == nil {
		return ErrStepUpRequired
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionKeysWrapPut, p.CredentialID)
	if err != nil {
		return err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionKeysWrapPut, ParamsHash: ph, StepUp: p.StepUp}
	return k.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, proven Proven) error {
		if !bytes.Equal(proven.CredentialID, p.CredentialID) {
			return fmt.Errorf("%w: the asserting credential is not the wrap's", ErrStepUpFailed)
		}
		var mine bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2)`,
			session.UserID, p.CredentialID).Scan(&mine); err != nil {
			return err
		}
		if !mine {
			return ErrNotYours
		}
		var (
			dwk  []byte
			live bool
		)
		if err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			session.UserID, session.WriterID).Scan(&dwk, &live); err != nil || !live {
			return ErrWriterUnbound
		}
		msg, err := keyproto.WrapPutMessage(proven.Nonce, p.CredentialID, p.Wrap)
		if err != nil || !keyproto.VerifyEd25519(dwk, msg, p.DWKSig) {
			return fmt.Errorf("%w: dwk_sig over WrapPutMessage", ErrBadSignature)
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at)
			 VALUES ($1, $2, $3, 1, $4)
			 ON CONFLICT (user_id, credential_id)
			 DO UPDATE SET wrap = EXCLUDED.wrap, wrap_version = EXCLUDED.wrap_version, created_at = EXCLUDED.created_at`,
			session.UserID, p.CredentialID, p.Wrap, k.now())
		if err != nil {
			return fmt.Errorf("auth: store wrap: %w", err)
		}
		return nil
	})
}

// DeleteWrap removes one credential's wrap under step-up keys.wrap.delete
// (#21). Deleting a wrap that is not there succeeds.
func (k *AccountKeys) DeleteWrap(ctx context.Context, session SessionInfo, credentialID []byte, su *StepUpObject) error {
	if err := keyproto.CheckCredentialID(credentialID); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if su == nil {
		return ErrStepUpRequired
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionKeysWrapDelete, credentialID)
	if err != nil {
		return err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionKeysWrapDelete, ParamsHash: ph, StepUp: su}
	return k.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		_, err := tx.Exec(ctx, `DELETE FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, session.UserID, credentialID)
		return err
	})
}

// AttestationHash is SHA-256 of a raw attestationObject, as stored in
// webauthn_credentials.attestation_sha256.
func AttestationHash(attestationObject []byte) []byte {
	h := sha256.Sum256(attestationObject)
	return h[:]
}
