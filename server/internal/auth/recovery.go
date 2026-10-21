package auth

// Access recovery: an email code plus the phrase (C4; spec 02 §10.4, spec 01
// §10.9, routes #7, #48, #8). Never email alone: the code proves the mailbox,
// the recovery key (derived from the phrase) signs the new authenticator's
// raw bytes, and one transaction registers it with a new writer and a bound
// session while every other session, every other passkey, the old password
// and every outstanding ceremony of the account are revoked.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// RecoveryTTL is a recovery ceremony's lifetime, from creation and again from
// verification.
const RecoveryTTL = 10 * time.Minute

// recoveriesPerDay is recover-account: successful recoveries per account per
// 24 hours, counted from sessions minted by recovery.
const recoveriesPerDay = 3

// EmailHint is spec 02 §9.9's masked address: the first character of the local
// part, "•••", "@", the first character of the domain, "•••", and the last
// label (m•••@g•••.com).
func EmailHint(addr string) string {
	at := strings.LastIndexByte(addr, '@')
	if at < 1 || at == len(addr)-1 {
		return "•••"
	}
	local, domain := addr[:at], addr[at+1:]
	last := domain[strings.LastIndexByte(domain, '.')+1:]
	return local[:1] + "•••@" + domain[:1] + "•••." + last
}

// RecoverBegun is #7's answer.
type RecoverBegun struct {
	CeremonyID string
	EmailHint  string
}

// RecoverBegin is #7: the account by its recovery key (unknown, suspended or
// frozen: ErrNoSuchAccount, 404), a ceremony, and a recovery code to the
// account's address.
func (a *Accounts) RecoverBegin(ctx context.Context, recoveryPub []byte) (RecoverBegun, error) {
	if len(recoveryPub) != keyproto.Ed25519KeySize {
		return RecoverBegun{}, fmt.Errorf("%w: recovery_pubkey is not 32 bytes", ErrBadRequest)
	}
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return RecoverBegun{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	st, err := scanAccount(tx.QueryRow(ctx, `SELECT `+accountColumns+` FROM users u
		JOIN account_keys ak ON ak.user_id = u.id WHERE ak.recovery_pubkey = $1`, recoveryPub))
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (!st.active() || st.frozen())) {
		return RecoverBegun{}, ErrNoSuchAccount
	}
	if err != nil {
		return RecoverBegun{}, err
	}
	id, err := newCeremonyIDN(32)
	if err != nil {
		return RecoverBegun{}, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return RecoverBegun{}, err
	}
	code, err := issueCodeTx(ctx, tx, a.Keys, now, PurposeRecovery, st.EmailNorm, &st.ID, CeremonyRecovery, id, true)
	if err != nil {
		return RecoverBegun{}, err
	}
	code.Name = st.DisplayName
	if _, err := tx.Exec(ctx,
		`INSERT INTO recovery_ceremonies (id, user_id, recover_nonce, code_id, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`, id, st.ID, nonce, code.ID, now, now.Add(RecoveryTTL)); err != nil {
		return RecoverBegun{}, fmt.Errorf("auth: recover begin: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return RecoverBegun{}, err
	}
	a.Mail.SendCodes(code)
	return RecoverBegun{CeremonyID: id, EmailHint: EmailHint(st.EmailNorm)}, nil
}

// RecoverVerified is #48's answer: what the device needs to unwrap and check
// the commitments before any prompt.
type RecoverVerified struct {
	Nonce           []byte
	UserID          uuid.UUID
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryWrap    []byte
	CurrentEpoch    int
	Options         *protocol.CredentialCreation // passkey
	Salt            []byte                       // password
}

// RecoverVerify is #48: the code; then the kind is fixed, the expiry restarts,
// and a passkey recovery gets its registration options (the account's handle,
// existing credentials excluded, UV required).
func (a *Accounts) RecoverVerify(ctx context.Context, ceremonyID, code, kind string) (RecoverVerified, error) {
	if kind != MethodPasskey && kind != MethodPassword {
		return RecoverVerified{}, fmt.Errorf("%w: kind", ErrBadRequest)
	}
	if kind == MethodPasskey && (a.Passkeys == nil || a.Passkeys.WA == nil) {
		return RecoverVerified{}, fmt.Errorf("%w: passkeys are not configured", ErrBadRequest)
	}
	now := a.now()
	var (
		codeID uuid.UUID
		userID uuid.UUID
		nonce  []byte
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT code_id, user_id, recover_nonce FROM recovery_ceremonies
		  WHERE id = $1 AND verified_at IS NULL AND expires_at > $2`, ceremonyID, now).Scan(&codeID, &userID, &nonce)
	if errors.Is(err, pgx.ErrNoRows) {
		return RecoverVerified{}, fmt.Errorf("%w: no verifiable recovery", ErrCodeRejected)
	}
	if err != nil {
		return RecoverVerified{}, err
	}
	if err := limitCodeVerify(ctx, a.Pool, now, codeID); err != nil {
		return RecoverVerified{}, err
	}
	out := RecoverVerified{Nonce: nonce, UserID: userID}
	err = a.consumeCode(ctx, codeCheck{CodeID: codeID, Purpose: PurposeRecovery, CeremonyKind: CeremonyRecovery,
		CeremonyID: ceremonyID, Submitted: code}, func(ctx context.Context, tx pgx.Tx) error {
		var email string
		if err := tx.QueryRow(ctx,
			`SELECT u.email_norm, k.amk_commitment, k.authority_pubkey, k.recovery_wrap, k.current_epoch
			   FROM users u JOIN account_keys k ON k.user_id = u.id WHERE u.id = $1`, userID).
			Scan(&email, &out.AMKCommitment, &out.AuthorityPubkey, &out.RecoveryWrap, &out.CurrentEpoch); err != nil {
			return fmt.Errorf("%w: the account has no keys", ErrCodeRejected)
		}
		var session any
		if kind == MethodPasskey {
			creds, handle, err := a.Passkeys.credentialsForUser(ctx, tx, userID)
			if err != nil {
				return err
			}
			user := passkeyUser{handle: handle, credentials: creds, rpName: passkeyUserName}
			opts, sd, err := a.Passkeys.WA.BeginRegistration(user,
				webauthn.WithExclusions(webauthn.Credentials(creds).CredentialDescriptors()))
			if err != nil {
				return fmt.Errorf("auth: recover verify: options: %w", err)
			}
			raw, err := json.Marshal(sd)
			if err != nil {
				return err
			}
			out.Options, session = opts, raw
		} else {
			out.Salt = a.Keys.PasswordSalt(email)
		}
		_, err := tx.Exec(ctx,
			`UPDATE recovery_ceremonies SET verified_at = $2, kind = $3, session_data = $4, expires_at = $5 WHERE id = $1`,
			ceremonyID, now, kind, session, now.Add(RecoveryTTL))
		return err
	})
	return out, err
}

// RecoverFinishRequest is #8's body, decoded.
type RecoverFinishRequest struct {
	CeremonyID      string
	Kind            string
	Credential      []byte // passkey: the PublicKeyCredential JSON
	PRFCredentialID []byte // passkey: nil, or the new credential's id
	PRFWrap         []byte
	PRFWrapVersion  int
	Verifier        []byte // password: S_new
	RKSig           []byte
	Writer          Registration // Nonce is ignored: the recover nonce signs
}

// RecoverFinished is #8's answer.
type RecoverFinished struct {
	Session  Minted
	UserID   uuid.UUID
	WriterID string
	// Wake is every other device and every signed-out session (spec 02
	// §12.5), sent once the recovery has committed.
	Wake Wake
}

// RecoverFinish is #8. Every failure is ErrRecoveryRefused, except the
// recover-account limit (ErrRateLimited) and the gate (ErrUnavailable).
func (a *Accounts) RecoverFinish(ctx context.Context, r RecoverFinishRequest) (RecoverFinished, error) {
	refuse := func(why string, args ...any) error {
		return fmt.Errorf("%w: "+why, append([]any{ErrRecoveryRefused}, args...)...)
	}
	now := a.now()
	var userID uuid.UUID
	if err := a.Pool.QueryRow(ctx, `SELECT user_id FROM recovery_ceremonies WHERE id = $1`, r.CeremonyID).Scan(&userID); err != nil {
		return RecoverFinished{}, refuse("no such ceremony")
	}
	var recent int
	if err := a.Pool.QueryRow(ctx,
		`SELECT count(*) FROM sessions WHERE user_id = $1 AND minted_by = 'recover' AND created_at > $2`,
		userID, now.Add(-24*time.Hour)).Scan(&recent); err != nil {
		return RecoverFinished{}, err
	}
	if recent >= recoveriesPerDay {
		return RecoverFinished{}, fmt.Errorf("%w: recoveries for this account", ErrRateLimited)
	}
	// Claim once: spent by the attempt.
	var (
		nonce   []byte
		kind    string
		session []byte
	)
	err := a.Pool.QueryRow(ctx,
		`UPDATE recovery_ceremonies SET claimed_at = $2
		  WHERE id = $1 AND verified_at IS NOT NULL AND expires_at > $2 AND claimed_at IS NULL
		 RETURNING recover_nonce, kind, session_data`, r.CeremonyID, now).Scan(&nonce, &kind, &session)
	if err != nil {
		return RecoverFinished{}, refuse("not claimable")
	}
	if kind != r.Kind {
		return RecoverFinished{}, refuse("the kind is not the one verified (%s)", kind)
	}
	st, err := readAccount(ctx, a.Pool, userID, false)
	if err != nil || !st.active() || !st.HasKeys || st.frozen() {
		return RecoverFinished{}, refuse("the account is not active, keyed and unfrozen")
	}
	var recoveryPub, authorityPub []byte
	if err := a.Pool.QueryRow(ctx, `SELECT recovery_pubkey, authority_pubkey FROM account_keys WHERE user_id = $1`, userID).
		Scan(&recoveryPub, &authorityPub); err != nil {
		return RecoverFinished{}, refuse("keys")
	}
	// The new authenticator, its RK signature, and (passkey) its attestation.
	var (
		made    created
		handle  []byte
		hash    []byte
		salt    []byte
		rkMsg   []byte
		hasWrap = r.PRFWrap != nil || r.PRFCredentialID != nil
	)
	switch kind {
	case MethodPasskey:
		if a.Passkeys == nil || a.Passkeys.WA == nil {
			return RecoverFinished{}, refuse("passkeys are not configured")
		}
		parsed, err := protocol.ParseCredentialCreationResponseBytes(r.Credential)
		if err != nil {
			return RecoverFinished{}, refuse("credential: %v", err)
		}
		var wrap []byte
		if hasWrap {
			if keyproto.CheckPRFWrap(r.PRFWrap) != nil || keyproto.CheckCredentialID(r.PRFCredentialID) != nil || r.PRFWrapVersion != 1 {
				return RecoverFinished{}, refuse("prf_wrap shape")
			}
			wrap = r.PRFWrap
		}
		if rkMsg, err = keyproto.RecoverySigninPasskey(nonce, []byte(parsed.Raw.AttestationResponse.ClientDataJSON),
			[]byte(parsed.Raw.AttestationResponse.AttestationObject), wrap); err != nil {
			return RecoverFinished{}, refuse("%v", err)
		}
		if !keyproto.VerifyEd25519(recoveryPub, rkMsg, r.RKSig) {
			return RecoverFinished{}, refuse("rk_sig")
		}
		var sd webauthn.SessionData
		if err := json.Unmarshal(session, &sd); err != nil {
			return RecoverFinished{}, refuse("session data")
		}
		_, handle, err = a.Passkeys.credentialsForUser(ctx, a.Pool, userID)
		if err != nil || handle == nil {
			return RecoverFinished{}, refuse("handle")
		}
		made, err = a.Passkeys.createCredential(passkeyUser{handle: handle, rpName: passkeyUserName},
			ceremony{Session: sd}, r.Credential)
		if err != nil {
			return RecoverFinished{}, refuse("%v", err)
		}
		if hasWrap && !sameBytes(r.PRFCredentialID, made.Credential.ID) {
			return RecoverFinished{}, refuse("prf_wrap.credential_id is not the new credential")
		}
	case MethodPassword:
		if rkMsg, err = keyproto.RecoverySigninPassword(nonce, r.Verifier); err != nil || len(r.Verifier) != 32 {
			return RecoverFinished{}, refuse("verifier")
		}
		if !keyproto.VerifyEd25519(recoveryPub, rkMsg, r.RKSig) {
			return RecoverFinished{}, refuse("rk_sig")
		}
	default:
		return RecoverFinished{}, refuse("kind")
	}
	w := r.Writer
	w.Nonce = nonce
	if err := w.checkShape(); err != nil {
		return RecoverFinished{}, refuse("writer: %v", err)
	}
	rm, err := keyproto.RegistrationMessage(nonce, w.WriterID, w.PubKey, w.DAKPubkey)
	if err != nil || !keyproto.VerifyEd25519(authorityPub, rm, w.Sig) {
		return RecoverFinished{}, refuse("registration_sig")
	}
	// A busy gate or a server fault before the commit is not the attempt's
	// failure: the verified ceremony goes back unclaimed, so the retry (under
	// recover-ip's 3 an hour) is not refused for the server's sake.
	release := func(err error) (RecoverFinished, error) {
		if _, xerr := a.Pool.Exec(ctx, `UPDATE recovery_ceremonies SET claimed_at = NULL WHERE id = $1 AND claimed_at = $2`,
			r.CeremonyID, now); xerr != nil {
			return RecoverFinished{}, errors.Join(err, fmt.Errorf("auth: recovery: release the ceremony: %w", xerr))
		}
		return RecoverFinished{}, err
	}
	if kind == MethodPassword {
		if hash, salt, err = newPasswordHash(ctx, a.Keys, a.Gate, r.Verifier); err != nil {
			return release(err)
		}
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return release(err)
	}
	defer pgtx.Rollback(ctx, tx)
	// The account's state again, under the lock: a freeze or a suspension
	// that landed since the check above refuses.
	if st, err = readAccount(ctx, tx, userID, true); err != nil || !st.active() || !st.HasKeys || st.frozen() {
		return RecoverFinished{}, refuse("the account is not active, keyed and unfrozen")
	}
	var live int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM writers WHERE user_id = $1 AND revoked_at IS NULL`, userID).Scan(&live); err != nil {
		return release(err)
	}
	if live >= MaxLiveWriters {
		return RecoverFinished{}, refuse("too many devices")
	}
	method := kind
	var cred []byte
	if kind == MethodPasskey {
		cred = made.Credential.ID
		if err := insertCredential(ctx, tx, storedCredential{UserID: userID, UserHandle: handle, Credential: *made.Credential,
			AttestationSHA256: made.AttestationSHA256}, now); err != nil {
			return RecoverFinished{}, refuse("%v", err)
		}
		if hasWrap {
			if _, err := tx.Exec(ctx,
				`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at) VALUES ($1, $2, $3, 1, $4)`,
				userID, cred, r.PRFWrap, now); err != nil {
				return RecoverFinished{}, refuse("%v", err)
			}
		}
	} else if err := setPasswordTx(ctx, tx, userID, hash, salt, a.Keys.Current(), now); err != nil {
		return release(err)
	}
	if err := insertWriterTx(ctx, tx, userID, w, now); err != nil {
		return RecoverFinished{}, refuse("%v", err)
	}
	revoked, err := RevokeOtherSessionsTx(ctx, tx, userID, nil, now)
	if err != nil {
		return release(err)
	}
	if err := revokeOldCredentialsTx(ctx, tx, userID, cred, kind == MethodPassword, now); err != nil {
		return release(err)
	}
	m, err := a.Sessions.IssueTx(ctx, tx, Mint{UserID: userID, MintedBy: MintedRecover, CredentialID: cred, WriterID: w.WriterID})
	if err != nil {
		return release(err)
	}
	if err := recordEventTx(ctx, tx, a.Mail, userID, AuthEvent{Kind: EventRecoveryUsed, Method: method,
		WriterID: w.WriterID, CredentialID: cred}, now); err != nil {
		return release(err)
	}
	if err := recordEventTx(ctx, tx, a.Mail, userID, AuthEvent{Kind: EventDeviceAdded, WriterID: w.WriterID}, now); err != nil {
		return release(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return RecoverFinished{}, err
	}
	if kind == MethodPassword || st.hasPassword() {
		a.recordPassword(userID, now)
	}
	a.Mail.Kick()
	return RecoverFinished{Session: m, UserID: userID, WriterID: w.WriterID,
		Wake: wakeFor(userID, w.WriterID, revoked)}, nil
}

func revokeOldCredentialsTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, keepCredential []byte, keepPassword bool, now time.Time) error {
	rows, err := tx.Query(ctx,
		`DELETE FROM webauthn_credentials WHERE user_id = $1 AND ($2::bytea IS NULL OR credential_id <> $2)
		 RETURNING credential_id`, userID, keepCredential)
	if err != nil {
		return fmt.Errorf("auth: recovery: remove old passkeys: %w", err)
	}
	removed, err := pgx.CollectRows(rows, pgx.RowTo[[]byte])
	if err != nil {
		return fmt.Errorf("auth: recovery: remove old passkeys: %w", err)
	}
	for _, id := range removed {
		if err := recordEventTx(ctx, tx, nil, userID, AuthEvent{Kind: EventPasskeyRemoved, CredentialID: id}, now); err != nil {
			return err
		}
	}
	if !keepPassword {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET password_hash = NULL, password_salt = NULL, password_version = NULL, password_set_at = NULL,
			        password_failures = 0, password_paused_until = NULL
			  WHERE id = $1 AND password_hash IS NOT NULL`, userID)
		if err != nil {
			return fmt.Errorf("auth: recovery: remove the old password: %w", err)
		}
		if tag.RowsAffected() == 1 {
			if err := recordEventTx(ctx, tx, nil, userID, AuthEvent{Kind: EventPasswordRemoved}, now); err != nil {
				return err
			}
		}
	}
	for _, q := range []string{
		`DELETE FROM step_up_challenges WHERE user_id = $1 AND used_at IS NULL`,
		`DELETE FROM webauthn_ceremonies WHERE user_id = $1`,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`,
		`DELETE FROM email_change_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return fmt.Errorf("auth: recovery: end outstanding ceremonies: %w", err)
		}
	}
	for _, q := range []string{
		`UPDATE password_login_ceremonies SET used_at = $2 WHERE user_id = $1 AND used_at IS NULL`,
		`UPDATE email_codes SET burned_at = $2 WHERE user_id = $1 AND used_at IS NULL AND burned_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, q, userID, now); err != nil {
			return fmt.Errorf("auth: recovery: end outstanding ceremonies: %w", err)
		}
	}
	return nil
}
