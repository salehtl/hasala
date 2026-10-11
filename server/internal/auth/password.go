package auth

// Password sign-in, signup, set, change, remove and C8 (spec 02 §10.7.3,
// §10.8, §10.10; spec 01 §10.15, §10.16). S is access only: #47 is the only
// route that accepts S as the whole proof, and what it grants is a session.

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// PasswordLoginTTL is a password-login ceremony's lifetime.
const PasswordLoginTTL = 5 * time.Minute

// dummyBindKey is the fixed key an unknown writer's SessionBind signature is
// checked against, so the answer and its cost depend only on the proof sent.
var dummyBindKey = ed25519.NewKeyFromSeed(make([]byte, 32)).Public().(ed25519.PublicKey)

// DeviceBinding is a sign-in's {writer_id, sig}: the DWK over
// SessionBindMessage(login challenge, writer_id).
type DeviceBinding struct {
	WriterID string
	Sig      []byte
}

// SignedIn is what a sign-in answers.
type SignedIn struct {
	Session    Minted
	UserID     uuid.UUID
	WriterID   string // "" when unbound
	HasKeys    bool
	Restricted bool
}

// PasswordLoginBegun is #46's answer, identical in shape for every valid
// address.
type PasswordLoginBegun struct {
	CeremonyID string
	Salt       []byte
	Nonce      []byte
}

// PasswordLoginBegin is #46: the public salt for any address, and a ceremony
// whose nonce a bound sign-in signs.
func (a *Accounts) PasswordLoginBegin(ctx context.Context, email string) (PasswordLoginBegun, error) {
	addr, err := normEmail(email)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	id, err := newCeremonyIDN(32)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	now := a.now()
	if _, err := a.Pool.Exec(ctx,
		`INSERT INTO password_login_ceremonies (id, user_id, email_tag, nonce, created_at, expires_at)
		 VALUES ($1, (SELECT id FROM users WHERE email_norm = $2), $3, $4, $5, $6)`,
		id, addr, a.Keys.EmailTag(addr), nonce, now, now.Add(PasswordLoginTTL)); err != nil {
		return PasswordLoginBegun{}, fmt.Errorf("auth: password login begin: %w", err)
	}
	return PasswordLoginBegun{CeremonyID: id, Salt: a.Keys.PasswordSalt(addr), Nonce: nonce}, nil
}

// checkBinding verifies a sign-in's SessionBind signature under the DWK of
// (userID, writer), or a fixed dummy key when there is no such writer. It
// answers ErrBadSignature, ErrWriterRevoked, or nil for a live writer.
func checkBinding(ctx context.Context, q querier, userID *uuid.UUID, challenge []byte, d *DeviceBinding) error {
	key := []byte(dummyBindKey)
	live, known := false, false
	if userID != nil && keyproto.ValidWriterID(d.WriterID) {
		var pub []byte
		err := q.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			*userID, d.WriterID).Scan(&pub, &live)
		if err == nil {
			key, known = pub, true
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("auth: read the binding writer: %w", err)
		}
	}
	msg, err := keyproto.SessionBindMessage(challenge, d.WriterID)
	if err != nil {
		msg = make([]byte, keyproto.SessionBindSize) // still one verification; it fails
	}
	ok := keyproto.VerifyEd25519(key, msg, d.Sig)
	switch {
	case !ok || !known || err != nil:
		return fmt.Errorf("%w: the session binding does not verify", ErrBadSignature)
	case !live:
		return ErrWriterRevoked
	}
	return nil
}

// signInTx mints a sign-in's session in tx: restricted while the account is
// frozen, bound when the sign-in was, and an unbound sign-in into an unfrozen
// account records sign_in_new (whose alert carries a freeze link).
func (a *Accounts) signInTx(ctx context.Context, tx pgx.Tx, st accountState, mintedBy, method string, cred []byte, writer string) (SignedIn, error) {
	now := a.now()
	restricted := st.frozen()
	m, err := a.Sessions.IssueTx(ctx, tx, Mint{UserID: st.ID, MintedBy: mintedBy, CredentialID: cred,
		WriterID: writer, Restricted: restricted})
	if err != nil {
		return SignedIn{}, err
	}
	if writer == "" && !restricted {
		if err := recordEventTx(ctx, tx, a.Mail, st.ID, AuthEvent{Kind: EventSignInNew, Method: method, CredentialID: cred}, now); err != nil {
			return SignedIn{}, err
		}
	}
	return SignedIn{Session: m, UserID: st.ID, WriterID: writer, HasKeys: st.HasKeys, Restricted: restricted}, nil
}

// PasskeyLoginFinish is #6: the assertion, then the optional device binding
// (checked under the account the credential resolved to), then one
// transaction that mints the session and records an unbound sign-in.
func (a *Accounts) PasskeyLoginFinish(ctx context.Context, ceremonyID string, response []byte, device *DeviceBinding) (SignedIn, error) {
	r, err := a.Passkeys.FinishLoginResult(ctx, ceremonyID, response)
	if err != nil {
		return SignedIn{}, err
	}
	writer := ""
	if device != nil {
		if err := checkBinding(ctx, a.Pool, &r.UserID, r.Challenge, device); err != nil {
			return SignedIn{}, err
		}
		writer = device.WriterID
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	st, err := readAccount(ctx, tx, r.UserID, true)
	if err != nil {
		return SignedIn{}, err
	}
	out, err := a.signInTx(ctx, tx, st, MintedLogin, MethodPasskey, r.CredentialID, writer)
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	a.Mail.Kick()
	return out, nil
}

// PasswordLoginFinish is #47 (spec 02 §10.8), after signin-ip. Every failure
// except an invalid binding (400 bad_signature), a revoked writer (403
// writer_revoked), a limiter (429) or the gate (503) is ErrPasswordRejected,
// after the same one PBKDF2.
func (a *Accounts) PasswordLoginFinish(ctx context.Context, ceremonyID string, verifier []byte, device *DeviceBinding) (SignedIn, error) {
	now := a.now()
	var (
		userID       *uuid.UUID
		tag, nonce   []byte
		expires      time.Time
		used         *time.Time
		cerOK        = true
		boundWriter  string
		passwordStep = func(st accountState, compare bool) (bool, error) {
			return passwordMatches(ctx, a.Keys, a.Gate, st, verifier, compare)
		}
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT user_id, email_tag, nonce, expires_at, used_at FROM password_login_ceremonies WHERE id = $1`, ceremonyID).
		Scan(&userID, &tag, &nonce, &expires, &used)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (used != nil || !expires.After(now))) {
		cerOK = false
	} else if err != nil {
		return SignedIn{}, fmt.Errorf("auth: password login: %w", err)
	}
	if !cerOK {
		if _, err := passwordStep(accountState{}, false); err != nil {
			return SignedIn{}, err
		}
		return SignedIn{}, fmt.Errorf("%w: no usable ceremony", ErrPasswordRejected)
	}
	// 2. The binding, before S: it reveals nothing about the password.
	if device != nil {
		if err := checkBinding(ctx, a.Pool, userID, nonce, device); err != nil {
			if errors.Is(err, ErrBadSignature) {
				_, _ = a.Pool.Exec(ctx, `UPDATE password_login_ceremonies SET used_at = $2 WHERE id = $1 AND used_at IS NULL`, ceremonyID, now)
			}
			return SignedIn{}, err
		}
		boundWriter = device.WriterID
	}
	// 3. The counters, before any PBKDF2.
	if boundWriter == "" {
		n, err := bumpCounter(ctx, a.Pool, "password-email", tag, passwordEmailWindow, now)
		if err != nil {
			return SignedIn{}, err
		}
		if n > passwordEmailLimit {
			return SignedIn{}, fmt.Errorf("%w: password attempts for this address", ErrRateLimited)
		}
	} else if err := writerPasswordBudget(ctx, a.Pool, *userID, boundWriter, now); err != nil {
		return SignedIn{}, err
	}
	// 5. Spend the ceremony, then the one PBKDF2.
	tag2, err := a.Pool.Exec(ctx,
		`UPDATE password_login_ceremonies SET used_at = $2 WHERE id = $1 AND used_at IS NULL AND expires_at > $2`, ceremonyID, now)
	if err != nil {
		return SignedIn{}, err
	}
	var st accountState
	exists := false
	if userID != nil && tag2.RowsAffected() == 1 {
		if st, err = readAccount(ctx, a.Pool, *userID, false); err == nil {
			exists = true
		} else if !errors.Is(err, ErrNoSuchAccount) {
			return SignedIn{}, err
		}
	}
	paused := exists && st.PausedUntil != nil && st.PausedUntil.After(now) && boundWriter == ""
	compare := exists && st.hasPassword() && !paused
	ok, err := passwordStep(st, compare)
	if err != nil {
		return SignedIn{}, err
	}
	if !ok {
		if compare {
			if err := recordPasswordFailure(ctx, a.Pool, st.ID, boundWriter, now); err != nil {
				return SignedIn{}, err
			}
		}
		return SignedIn{}, fmt.Errorf("%w: wrong, absent or paused", ErrPasswordRejected)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	if st, err = readAccount(ctx, tx, st.ID, true); err != nil {
		return SignedIn{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET password_failures = 0, password_paused_until = NULL WHERE id = $1`, st.ID); err != nil {
		return SignedIn{}, err
	}
	out, err := a.signInTx(ctx, tx, st, MintedPasswordLogin, MethodPassword, nil, boundWriter)
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	a.Mail.Kick()
	return out, nil
}

// PasswordSignedUp is #45's answer.
type PasswordSignedUp struct {
	Session  Minted
	UserID   uuid.UUID
	WriterID string
}

// PasswordSignup is #45, C1-P (spec 02 §10.7.3): one request claims the
// signup, checks the bootstrap (bound to the signup's reserved id, its address
// and SHA256(S), over the signup nonce), hashes S, and creates the account
// with its keys, first writer, password and bound session in one transaction.
// Bootstrap.Writer.Nonce must be the signup nonce; no PRF wrap is possible.
func (a *Accounts) PasswordSignup(ctx context.Context, signupID string, verifier []byte, b Bootstrap) (PasswordSignedUp, error) {
	now := a.now()
	if len(verifier) != authkeys.VerifierSize {
		return PasswordSignedUp{}, fmt.Errorf("%w: verifier is not 32 bytes", ErrBadRequest)
	}
	// 1. Claim once: spent by the attempt.
	s, err := scanSignup(a.Pool.QueryRow(ctx, `UPDATE signup_ceremonies SET claimed_at = $2
		WHERE id = $1 AND expires_at > $2 AND claimed_at IS NULL AND (email_proven OR verified_at IS NOT NULL)
		RETURNING `+signupColumns, signupID, now))
	if errors.Is(err, pgx.ErrNoRows) {
		return PasswordSignedUp{}, fmt.Errorf("%w: the signup is not claimable", ErrCodeRejected)
	}
	if err != nil {
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: claim: %w", err)
	}
	if err := addressFree(ctx, a.Pool, s); err != nil {
		return PasswordSignedUp{}, err
	}
	// 2. Bootstrap checks 3, 5, 6 against the signup.
	sh := sha256.Sum256(verifier)
	switch {
	case b.FormatVersion != keyproto.BootstrapPayloadVersion:
		return PasswordSignedUp{}, fmt.Errorf("%w: format_version %d", ErrKeysMalformed, b.FormatVersion)
	case byte(b.AuthKind) != keyproto.AuthKindPassword || !sameBytes(b.AuthHash, sh[:]):
		return PasswordSignedUp{}, fmt.Errorf("%w: auth_kind 2 with auth_hash = SHA256(S)", ErrKeysMalformed)
	case !sameBytes(b.EmailHash, signupEmailHash(s)):
		return PasswordSignedUp{}, fmt.Errorf("%w: email_hash is not the signup's address", ErrKeysMalformed)
	case b.PRFCredentialID != nil:
		return PasswordSignedUp{}, fmt.Errorf("%w: a password signup carries no PRF wrap", ErrKeysMalformed)
	case !sameBytes(b.Writer.Nonce, s.Nonce):
		return PasswordSignedUp{}, fmt.Errorf("%w: the nonce is not the signup's", ErrBadSignature)
	case b.Writer.Alg != AlgEd25519:
		return PasswordSignedUp{}, fmt.Errorf("%w: writer.alg %q", ErrKeysMalformed, b.Writer.Alg)
	case !keyproto.ValidWriterID(b.Writer.WriterID):
		return PasswordSignedUp{}, ErrBadWriterID
	}
	pl := keyproto.BootstrapPayload{
		UserID: s.UserID, AMKCommitment: b.AMKCommitment, AuthorityPubkey: b.AuthorityPubkey,
		RecoveryPubkey: b.RecoveryPubkey, RecoveryWrap: b.RecoveryWrap, PhraseBox: b.PhraseBox,
		EmailHash: b.EmailHash, AuthKind: keyproto.AuthKindPassword, AuthHash: b.AuthHash,
		WriterPubkey: b.Writer.PubKey, WriterDAK: b.Writer.DAKPubkey, WriterID: b.Writer.WriterID,
	}
	payload, err := pl.Bytes()
	if err != nil {
		return PasswordSignedUp{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := pl.CheckKeys(); err != nil {
		return PasswordSignedUp{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	bm, err := keyproto.BootstrapMessage(s.Nonce, payload)
	if err != nil {
		return PasswordSignedUp{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	rm, err := keyproto.RegistrationMessage(s.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
	if err != nil {
		return PasswordSignedUp{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if !keyproto.VerifyEd25519(b.AuthorityPubkey, bm, b.AuthoritySig) || !keyproto.VerifyEd25519(b.AuthorityPubkey, rm, b.Writer.Sig) {
		return PasswordSignedUp{}, fmt.Errorf("%w: authority_sig or registration_sig", ErrBadSignature)
	}
	// 3. The verifier, through the gate.
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	// 4. One transaction.
	handle, err := randBytes(userHandleBytes)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	if err := createAccountTx(ctx, tx, s, handle, now); err != nil {
		return PasswordSignedUp{}, err
	}
	if err := setPasswordTx(ctx, tx, s.UserID, hash, salt, a.Keys.Current(), now); err != nil {
		return PasswordSignedUp{}, err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, $7, $7)`,
		s.UserID, b.AMKCommitment, b.AuthorityPubkey, b.RecoveryPubkey, b.RecoveryWrap, b.PhraseBox, now); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			return PasswordSignedUp{}, fmt.Errorf("%w: the authority or recovery key is already in use", ErrKeysMalformed)
		}
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: keys: %w", err)
	}
	if err := insertWriterTx(ctx, tx, s.UserID, b.Writer, now); err != nil {
		return PasswordSignedUp{}, err
	}
	if err := recordEventTx(ctx, tx, a.Mail, s.UserID, AuthEvent{Kind: EventDeviceAdded, WriterID: b.Writer.WriterID}, now); err != nil {
		return PasswordSignedUp{}, err
	}
	m, err := a.Sessions.IssueTx(ctx, tx, Mint{UserID: s.UserID, MintedBy: MintedPasswordSignup, WriterID: b.Writer.WriterID})
	if err != nil {
		return PasswordSignedUp{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: commit: %w", err)
	}
	return PasswordSignedUp{Session: m, UserID: s.UserID, WriterID: b.Writer.WriterID}, nil
}

// PasswordSalt is #59: s_srv for any address (enumeration-free by
// construction: it is a function of the address alone).
func (a *Accounts) PasswordSalt(email string) ([]byte, error) {
	addr, err := normEmail(email)
	if err != nil {
		return nil, err
	}
	return a.Keys.PasswordSalt(addr), nil
}

// passwordAction runs one of #55–#58 under its step-up.
func (a *Accounts) passwordAction(ctx context.Context, session SessionInfo, action keyproto.Action, fields [][]byte,
	su *StepUpObject, do func(ctx context.Context, tx pgx.Tx, st accountState, p Proven, now time.Time) (string, error)) error {
	ph, err := keyproto.ParamsHash(action, fields...)
	if err != nil {
		return err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: action, ParamsHash: ph, StepUp: su}
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		now := a.now()
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if st.frozen() {
			return ErrAccountFrozen
		}
		event, err := do(ctx, tx, st, p, now)
		if err != nil {
			return err
		}
		if _, err := RevokeOtherSessionsTx(ctx, tx, session.UserID, [][]byte{session.Hash}, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: event, WriterID: p.WriterID, CredentialID: p.CredentialID}, now)
	})
	if err == nil {
		a.Mail.Kick()
	}
	return err
}

func verifierHash(v []byte) ([]byte, error) {
	if len(v) != authkeys.VerifierSize {
		return nil, fmt.Errorf("%w: verifier is not 32 bytes", ErrBadRequest)
	}
	h := sha256.Sum256(v)
	return h[:], nil
}

// SetPassword is #56: step-up password.set (passkey), P = (SHA256(S_new)); the
// account has no password yet (ErrConflict).
func (a *Accounts) SetPassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) error {
	vh, err := verifierHash(verifier)
	if err != nil {
		return err
	}
	if su == nil {
		return ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordSet, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if st.hasPassword() {
				return "", ErrConflict
			}
			return EventPasswordSet, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}

// ChangePassword is #57: step-up password.change (passkey, or device with the
// current S), P = (SHA256(S_new)); the account has a password.
func (a *Accounts) ChangePassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) error {
	vh, err := verifierHash(verifier)
	if err != nil {
		return err
	}
	if su == nil {
		return ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordChange, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			return EventPasswordChanged, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}

// RemovePassword is #58: step-up password.remove (passkey), P = (); the
// account keeps at least one passkey (ErrLastAuthenticator).
func (a *Accounts) RemovePassword(ctx context.Context, session SessionInfo, su *StepUpObject) error {
	return a.passwordAction(ctx, session, keyproto.ActionPasswordRemove, nil, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			var passkeys int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, st.ID).Scan(&passkeys); err != nil {
				return "", err
			}
			if passkeys == 0 {
				return "", ErrLastAuthenticator
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET password_hash = NULL, password_salt = NULL, password_version = NULL, password_set_at = NULL,
				        password_failures = 0, password_paused_until = NULL WHERE id = $1`, st.ID); err != nil {
				return "", err
			}
			return EventPasswordRemoved, nil
		})
}

// ResetPasswordWithCode is #55, C8 on a signed-in iPhone: step-up
// password.reset (device_code: the DAK plus the emailed code), P =
// (SHA256(S_new)); the account has a password.
func (a *Accounts) ResetPasswordWithCode(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) error {
	vh, err := verifierHash(verifier)
	if err != nil {
		return err
	}
	if su == nil {
		return ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordReset, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			return EventPasswordReset, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}
