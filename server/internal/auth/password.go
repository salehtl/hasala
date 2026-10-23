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
	"github.com/salehtl/hasala/server/internal/pushv2"
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
	// Wake is set by C9 finish (#54), which signs other sessions out; a
	// sign-in wakes nobody.
	Wake Wake
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
	// The same one lookup whether or not the address has an account (spec 02
	// §9.4: the cost depends only on the proof); the nil id matches no row.
	owner := uuid.Nil
	if userID != nil {
		owner = *userID
	}
	var pub []byte
	err := q.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		owner, d.WriterID).Scan(&pub, &live)
	switch {
	case err == nil && userID != nil && keyproto.ValidWriterID(d.WriterID):
		key, known = pub, true
	case err != nil && !errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("auth: read the binding writer: %w", err)
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
// (checked under the account the credential resolved to; a writer of another
// account is ErrDeviceOtherAccount), then one
// transaction that mints the session and records an unbound sign-in.
func (a *Accounts) PasskeyLoginFinish(ctx context.Context, ceremonyID string, response []byte, device *DeviceBinding) (SignedIn, error) {
	r, err := a.Passkeys.FinishLoginResult(ctx, ceremonyID, response)
	if err != nil {
		return SignedIn{}, err
	}
	writer := ""
	if device != nil {
		var mine bool
		if err := a.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM writers WHERE user_id = $1 AND writer_id = $2)`,
			r.UserID, device.WriterID).Scan(&mine); err != nil {
			return SignedIn{}, fmt.Errorf("auth: read the binding writer: %w", err)
		}
		if !mine {
			return SignedIn{}, ErrDeviceOtherAccount
		}
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
	} else if err := writerPasswordAttempt(ctx, a.Pool, *userID, boundWriter, now); err != nil {
		return SignedIn{}, err
	}
	// 4. The gate, before the ceremony is spent: a busy server (503) spends
	// nothing, and the retry can use the same ceremony.
	release, err := a.Gate.Acquire(ctx)
	if err != nil {
		if boundWriter != "" {
			if rerr := refundWriterPasswordAttempt(ctx, a.Pool, *userID, boundWriter, now); rerr != nil {
				return SignedIn{}, rerr
			}
		}
		return SignedIn{}, gateErr(err)
	}
	defer release()
	// 5. Spend the ceremony, then the one PBKDF2 in the slot already held.
	tag2, err := a.Pool.Exec(ctx,
		`UPDATE password_login_ceremonies SET used_at = $2 WHERE id = $1 AND used_at IS NULL AND expires_at > $2`, ceremonyID, now)
	if err != nil {
		return SignedIn{}, err
	}
	// The account is read on every path, an unknown address's as the nil id
	// (no row), so the answer's cost does not depend on whether the address
	// has an account (spec 02 §10.8).
	var st accountState
	exists := false
	target := uuid.Nil
	if userID != nil && tag2.RowsAffected() == 1 {
		target = *userID
	}
	if st, err = readAccount(ctx, a.Pool, target, false); err == nil {
		exists = true
	} else if !errors.Is(err, ErrNoSuchAccount) {
		return SignedIn{}, err
	}
	paused := exists && st.PausedUntil != nil && st.PausedUntil.After(now) && boundWriter == ""
	compare := exists && st.hasPassword() && !paused
	ok, err := passwordMatches(ctx, a.Keys, nil, st, verifier, compare)
	release()
	if err != nil {
		return SignedIn{}, err
	}
	if !ok {
		if compare {
			if err := recordPasswordFailure(ctx, a.Pool, st.ID, now); err != nil {
				return SignedIn{}, err
			}
		} else if _, err := a.Pool.Exec(ctx,
			`UPDATE users SET password_failures = password_failures + 1 WHERE id = $1`, uuid.Nil); err != nil {
			// The same statement against no row: an absent or paused account's
			// failure costs what a counted one does.
			return SignedIn{}, err
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
	if boundWriter != "" {
		if err := refundWriterPasswordAttempt(ctx, tx, st.ID, boundWriter, now); err != nil {
			return SignedIn{}, err
		}
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
	// 1. The signup must be claimable. The claim itself is the account
	// transaction's first statement (AT-AUTH-2: a busy gate or a fault in that
	// transaction leaves the signup unclaimed); a request the checks below
	// refuse spends it, since its nonce is consumed by the attempt.
	s, err := readySignup(ctx, a.Pool, signupID, now)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	spend := func(err error) (PasswordSignedUp, error) {
		if _, xerr := a.Pool.Exec(ctx, `UPDATE signup_ceremonies SET claimed_at = $2 WHERE id = $1 AND claimed_at IS NULL`,
			signupID, now); xerr != nil {
			return PasswordSignedUp{}, errors.Join(err, fmt.Errorf("auth: password signup: spend: %w", xerr))
		}
		return PasswordSignedUp{}, err
	}
	if err := addressFree(ctx, a.Pool, s); err != nil {
		if errors.Is(err, ErrEmailInUse) || errors.Is(err, ErrCodeRejected) {
			return spend(err)
		}
		return PasswordSignedUp{}, err
	}
	// The invite must still be unspent (spec 02 §10.7.3 step 1: anything
	// else is code_rejected), checked before the PBKDF2 it would waste. The
	// redemption in the account transaction stays the gate against a race.
	var unspent bool
	if err := a.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM invite_codes WHERE code_hash = $1 AND state = 'active' AND expires_at > $2)`,
		s.InviteHash, now).Scan(&unspent); err != nil {
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: invite: %w", err)
	}
	if !unspent {
		return spend(fmt.Errorf("%w: the invite is spent", ErrCodeRejected))
	}
	// 2. Bootstrap checks 3, 5, 6 against the signup.
	if err := checkPasswordBootstrap(s, verifier, b); err != nil {
		return spend(err)
	}
	// 3. The verifier, through the gate.
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	// 4. One transaction, which claims the signup first.
	handle, err := randBytes(userHandleBytes)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	claimed, err := claimSignupTx(ctx, tx, signupID, now)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	if claimed.UserID != s.UserID || claimed.EmailNorm != s.EmailNorm || !sameBytes(claimed.Nonce, s.Nonce) {
		// The bootstrap was checked against the row as read; a signup row
		// never changes these, but the claim must be of that row.
		return PasswordSignedUp{}, fmt.Errorf("%w: the signup changed", ErrCodeRejected)
	}
	s = claimed
	if err := createAccountTx(ctx, tx, s, handle, now); err != nil {
		if errors.Is(err, ErrNotInvited) {
			// The invite was redeemed since the check above: #45 answers every
			// unusable signup alike (§10.7.3 step 1).
			return PasswordSignedUp{}, fmt.Errorf("%w: the invite is spent", ErrCodeRejected)
		}
		return PasswordSignedUp{}, err
	}
	if err := setPasswordTx(ctx, tx, s.UserID, hash, salt, a.Keys.Current(), now); err != nil {
		return PasswordSignedUp{}, err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at, phrase_seen_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, $7, $7, $7)`,
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

// checkPasswordBootstrap is #45's step 2: spec 02 §10.1 checks 3, 5 and 6
// against the signup (its reserved id, its address, SHA256(S), its nonce).
func checkPasswordBootstrap(s signupRow, verifier []byte, b Bootstrap) error {
	sh := sha256.Sum256(verifier)
	switch {
	case b.FormatVersion != keyproto.BootstrapPayloadVersion:
		return fmt.Errorf("%w: format_version %d", ErrKeysMalformed, b.FormatVersion)
	case byte(b.AuthKind) != keyproto.AuthKindPassword || !sameBytes(b.AuthHash, sh[:]):
		return fmt.Errorf("%w: auth_kind 2 with auth_hash = SHA256(S)", ErrKeysMalformed)
	case !sameBytes(b.EmailHash, signupEmailHash(s)):
		return fmt.Errorf("%w: email_hash is not the signup's address", ErrKeysMalformed)
	case b.PRFCredentialID != nil:
		return fmt.Errorf("%w: a password signup carries no PRF wrap", ErrKeysMalformed)
	case !sameBytes(b.Writer.Nonce, s.Nonce):
		return fmt.Errorf("%w: the nonce is not the signup's", ErrBadSignature)
	case b.Writer.Alg != AlgEd25519:
		return fmt.Errorf("%w: writer.alg is not Ed25519", ErrKeysMalformed)
	case !keyproto.ValidWriterID(b.Writer.WriterID):
		return ErrBadWriterID
	}
	pl := keyproto.BootstrapPayload{
		UserID: s.UserID, AMKCommitment: b.AMKCommitment, AuthorityPubkey: b.AuthorityPubkey,
		RecoveryPubkey: b.RecoveryPubkey, RecoveryWrap: b.RecoveryWrap, PhraseBox: b.PhraseBox,
		EmailHash: b.EmailHash, AuthKind: keyproto.AuthKindPassword, AuthHash: b.AuthHash,
		WriterPubkey: b.Writer.PubKey, WriterDAK: b.Writer.DAKPubkey, WriterID: b.Writer.WriterID,
	}
	payload, err := pl.Bytes()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := pl.CheckKeys(); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	bm, err := keyproto.BootstrapMessage(s.Nonce, payload)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	rm, err := keyproto.RegistrationMessage(s.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if !keyproto.VerifyEd25519(b.AuthorityPubkey, bm, b.AuthoritySig) || !keyproto.VerifyEd25519(b.AuthorityPubkey, rm, b.Writer.Sig) {
		return fmt.Errorf("%w: authority_sig or registration_sig", ErrBadSignature)
	}
	return nil
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

// passwordAction runs one of #55–#58 under its step-up. Every other session
// is signed out, and the answer is who to wake once it has committed: the
// account's other devices and the signed-out sessions' tokens (spec 02 §12.5).
func (a *Accounts) passwordAction(ctx context.Context, session SessionInfo, action keyproto.Action, fields [][]byte,
	su *StepUpObject, do func(ctx context.Context, tx pgx.Tx, st accountState, p Proven, now time.Time) (string, error)) (Wake, error) {
	ph, err := keyproto.ParamsHash(action, fields...)
	if err != nil {
		return Wake{}, err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: action, ParamsHash: ph, StepUp: su}
	var (
		revoked []pushv2.Target
		changed string
		at      time.Time
	)
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
		changed, at = event, now
		if revoked, err = RevokeOtherSessionsTx(ctx, tx, session.UserID, [][]byte{session.Hash}, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: event, WriterID: p.WriterID, CredentialID: p.CredentialID}, now)
	})
	if err != nil {
		return Wake{}, err
	}
	if changed != EventPasswordSet {
		a.recordPassword(session.UserID, at)
	}
	a.Mail.Kick()
	return wakeFor(session.UserID, session.WriterID, revoked), nil
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
func (a *Accounts) SetPassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
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
func (a *Accounts) ChangePassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
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
func (a *Accounts) RemovePassword(ctx context.Context, session SessionInfo, su *StepUpObject) (Wake, error) {
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
func (a *Accounts) ResetPasswordWithCode(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordReset, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			return EventPasswordReset, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}
