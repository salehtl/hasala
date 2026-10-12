package auth

// Password reset on a new iPhone, approved by a signed-in iPhone (C9, spec 02
// §10.9, routes #49–#54; spec 01 §10.16). N (the new iPhone) proves the
// address with a password_reset code, posts an ephemeral Ed25519 key, and
// waits; A (an enrolled iPhone with a bound session) approves with its DAK
// over ResetApproveMessage, after the user compares the 80-bit approval code
// derived from that key (the server never computes it). N finishes with the
// ephemeral key's signature over the new S.

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// ResetTTL is a reset ceremony's lifetime, from creation and again from
// verification.
const ResetTTL = 10 * time.Minute

// ResetBegin is #49: one transaction writes the ceremony (with user_id only
// when the account exists, has a password, is active and not frozen) and a
// password_reset code, sent only then. The answer is identical for every
// valid address.
func (a *Accounts) ResetBegin(ctx context.Context, email string) (string, error) {
	addr, err := normEmail(email)
	if err != nil {
		return "", err
	}
	id, err := newCeremonyIDN(32)
	if err != nil {
		return "", err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return "", err
	}
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return "", err
	}
	defer pgtx.Rollback(ctx, tx)
	st, ok, err := accountByEmail(ctx, tx, addr)
	if err != nil {
		return "", err
	}
	eligible := ok && st.hasPassword() && st.active() && !st.frozen()
	var userID *uuid.UUID
	if eligible {
		userID = &st.ID
	}
	code, err := issueCodeTx(ctx, tx, a.Keys, now, PurposePasswordReset, addr, userID, CeremonyPasswordReset, id, eligible)
	if err != nil {
		return "", err
	}
	if eligible {
		code.Name = st.DisplayName
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO password_reset_ceremonies (id, user_id, email_tag, code_id, reset_nonce, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		id, userID, a.Keys.EmailTag(addr), code.ID, nonce, now, now.Add(ResetTTL)); err != nil {
		return "", fmt.Errorf("auth: reset begin: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	a.Mail.SendCodes(code)
	return id, nil
}

// ResetVerified is #50's answer, revealed only to a correct code.
type ResetVerified struct {
	Nonce     []byte
	Salt      []byte
	Approvers bool
}

// ResetVerify is #50: the code; on success verified_at and a fresh 10-minute
// expiry. Every failure is ErrCodeRejected.
func (a *Accounts) ResetVerify(ctx context.Context, resetID, code string) (ResetVerified, error) {
	now := a.now()
	var (
		codeID uuid.UUID
		userID *uuid.UUID
		nonce  []byte
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT code_id, user_id, reset_nonce FROM password_reset_ceremonies
		  WHERE id = $1 AND verified_at IS NULL AND expires_at > $2`, resetID, now).Scan(&codeID, &userID, &nonce)
	if errors.Is(err, pgx.ErrNoRows) {
		return ResetVerified{}, fmt.Errorf("%w: no verifiable reset", ErrCodeRejected)
	}
	if err != nil {
		return ResetVerified{}, err
	}
	if err := limitCodeVerify(ctx, a.Pool, now, codeID); err != nil {
		return ResetVerified{}, err
	}
	var out ResetVerified
	err = a.consumeCode(ctx, codeCheck{CodeID: codeID, Purpose: PurposePasswordReset, CeremonyKind: CeremonyPasswordReset,
		CeremonyID: resetID, Submitted: code}, func(ctx context.Context, tx pgx.Tx) error {
		if userID == nil {
			return fmt.Errorf("%w: no eligible account", ErrCodeRejected) // unreachable: its code was never sent
		}
		if _, err := tx.Exec(ctx, `UPDATE password_reset_ceremonies SET verified_at = $2, expires_at = $3 WHERE id = $1`,
			resetID, now, now.Add(ResetTTL)); err != nil {
			return err
		}
		var email string
		if err := tx.QueryRow(ctx,
			`SELECT u.email_norm, EXISTS (SELECT 1 FROM writers w WHERE w.user_id = u.id AND w.revoked_at IS NULL)
			   FROM users u WHERE u.id = $1`, *userID).Scan(&email, &out.Approvers); err != nil {
			return err
		}
		out.Nonce, out.Salt = nonce, a.Keys.PasswordSalt(email)
		return nil
	})
	return out, err
}

// ResetRequest is #51: the new iPhone's ephemeral key, stored once on a
// verified, unexpired ceremony. Every failure is ErrResetRefused. The answer
// wakes every live writer of the account, so one of them can approve (spec 02
// §12.5).
func (a *Accounts) ResetRequest(ctx context.Context, resetID string, ekPub []byte) (Wake, error) {
	if keyproto.CheckEd25519PublicKey(ekPub) != nil {
		return Wake{}, fmt.Errorf("%w: ek_pub", ErrResetRefused)
	}
	var userID uuid.UUID
	err := a.Pool.QueryRow(ctx,
		`UPDATE password_reset_ceremonies SET ek_pubkey = $2
		  WHERE id = $1 AND verified_at IS NOT NULL AND expires_at > $3 AND ek_pubkey IS NULL AND user_id IS NOT NULL
		 RETURNING user_id`,
		resetID, ekPub, a.now()).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Wake{}, fmt.Errorf("%w: not a waiting ceremony", ErrResetRefused)
	}
	if err != nil {
		return Wake{}, err
	}
	return wakeFor(userID, "", nil), nil
}

// PendingReset is one row of #52.
type PendingReset struct {
	ResetID   string
	Nonce     []byte
	EKPub     []byte
	CreatedAt time.Time
}

// ResetPending is #52: this account's verified, unexpired, unapproved
// ceremonies with an ephemeral key.
func (a *Accounts) ResetPending(ctx context.Context, userID uuid.UUID) ([]PendingReset, error) {
	rows, err := a.Pool.Query(ctx,
		`SELECT id, reset_nonce, ek_pubkey, created_at FROM password_reset_ceremonies
		  WHERE user_id = $1 AND verified_at IS NOT NULL AND expires_at > $2 AND ek_pubkey IS NOT NULL
		    AND approved_at IS NULL ORDER BY created_at`, userID, a.now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PendingReset{}
	for rows.Next() {
		var p PendingReset
		if err := rows.Scan(&p.ResetID, &p.Nonce, &p.EKPub, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ResetApprove is #53: the approving session's bound, live writer signs
// ResetApproveMessage with its DAK. Every failure is ErrResetRefused.
func (a *Accounts) ResetApprove(ctx context.Context, session SessionInfo, resetID, writerID string, sig []byte) error {
	if writerID == "" || writerID != session.WriterID {
		return fmt.Errorf("%w: not the session's writer", ErrResetRefused)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	now := a.now()
	var (
		nonce, ek []byte
		dak       []byte
		live      bool
	)
	err = tx.QueryRow(ctx,
		`SELECT reset_nonce, ek_pubkey FROM password_reset_ceremonies
		  WHERE id = $1 AND user_id = $2 AND verified_at IS NOT NULL AND expires_at > $3 AND ek_pubkey IS NOT NULL
		    AND approved_at IS NULL FOR UPDATE`, resetID, session.UserID, now).Scan(&nonce, &ek)
	if err != nil {
		return fmt.Errorf("%w: no ceremony awaiting approval", ErrResetRefused)
	}
	if err := tx.QueryRow(ctx, `SELECT dak_pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		session.UserID, writerID).Scan(&dak, &live); err != nil || !live {
		return fmt.Errorf("%w: the writer is not live", ErrResetRefused)
	}
	msg, err := keyproto.ResetApproveMessage(nonce, session.UserID, ek, writerID)
	if err != nil || !keyproto.VerifyDAKBytes(dak, msg, sig) {
		return fmt.Errorf("%w: the approval does not verify", ErrResetRefused)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE password_reset_ceremonies SET approved_by_writer = $2, approved_session = $3, approval_sig = $4, approved_at = $5
		  WHERE id = $1`,
		resetID, writerID, session.Hash, sig, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ResetFinish is #54: the ephemeral key's signature over the new S, then one
// transaction: the new verifier, every other session revoked except the
// approver's, N's session minted (password_reset, unbound), the ceremony
// consumed, and password_reset and sign_in_new recorded.
func (a *Accounts) ResetFinish(ctx context.Context, resetID string, verifier, ekSig []byte) (SignedIn, error) {
	if _, err := verifierHash(verifier); err != nil {
		return SignedIn{}, fmt.Errorf("%w: verifier", ErrResetRefused)
	}
	now := a.now()
	var (
		userID     *uuid.UUID
		nonce, ek  []byte
		approver   *string
		approvedAt *time.Time
		consumed   *time.Time
		expires    time.Time
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT user_id, reset_nonce, ek_pubkey, approved_by_writer, approved_at, consumed_at, expires_at
		   FROM password_reset_ceremonies WHERE id = $1`, resetID).
		Scan(&userID, &nonce, &ek, &approver, &approvedAt, &consumed, &expires)
	if err != nil || userID == nil || ek == nil || consumed != nil || !expires.After(now) {
		return SignedIn{}, fmt.Errorf("%w: no ceremony to finish", ErrResetRefused)
	}
	if approvedAt == nil {
		return SignedIn{}, ErrNotApproved
	}
	msg, err := keyproto.ResetFinishMessage(nonce, verifier)
	if err != nil || !keyproto.VerifyEd25519(ek, msg, ekSig) {
		return SignedIn{}, fmt.Errorf("%w: ek_sig", ErrResetRefused)
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return SignedIn{}, err
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	var approvedSession []byte
	err = tx.QueryRow(ctx,
		`UPDATE password_reset_ceremonies SET consumed_at = $2 WHERE id = $1 AND consumed_at IS NULL AND approved_at IS NOT NULL
		 RETURNING approved_session`,
		resetID, now).Scan(&approvedSession)
	if errors.Is(err, pgx.ErrNoRows) {
		return SignedIn{}, fmt.Errorf("%w: already consumed", ErrResetRefused)
	}
	if err != nil {
		return SignedIn{}, err
	}
	st, err := readAccount(ctx, tx, *userID, true)
	if err != nil {
		return SignedIn{}, fmt.Errorf("%w: %v", ErrResetRefused, err)
	}
	if !st.active() || !st.hasPassword() || st.frozen() {
		return SignedIn{}, fmt.Errorf("%w: the account is no longer eligible", ErrResetRefused)
	}
	var live bool
	if err := tx.QueryRow(ctx, `SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		st.ID, *approver).Scan(&live); err != nil || !live {
		return SignedIn{}, fmt.Errorf("%w: the approver is gone", ErrResetRefused)
	}
	if err := setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now); err != nil {
		return SignedIn{}, err
	}
	// Keep the session the approval came from (spec 02 §10.9), and only it.
	keep := [][]byte{approvedSession}
	revoked, err := RevokeOtherSessionsTx(ctx, tx, st.ID, keep, now)
	if err != nil {
		return SignedIn{}, err
	}
	if err := recordEventTx(ctx, tx, a.Mail, st.ID, AuthEvent{Kind: EventPasswordReset}, now); err != nil {
		return SignedIn{}, err
	}
	out, err := a.signInTx(ctx, tx, st, MintedPasswordReset, MethodPassword, nil, "")
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	a.Mail.Kick()
	// The new iPhone has no writer yet: every device of the account hears of
	// the reset, the approver included (spec 02 §12.5).
	out.Wake = wakeFor(st.ID, "", revoked)
	return out, nil
}
