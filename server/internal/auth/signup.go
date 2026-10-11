package auth

// Signup and account creation (spec 02 §10.7, spec 01 §10.3). Invites are the
// only way in, and both methods start with the same step: signup/begin takes
// the invite, the address and the display name; the address is proven by the
// invite link's key (and the invite's own address) or by a signup code. The
// account is created in one transaction by register/finish (a passkey) or
// password/register (a password), which claim the signup, re-check the invite
// and the address, insert the user under the reserved id, redeem the invite and
// run spec 07's join hook.

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// SignupTTL is how long a signup ceremony (and the plaintext address it holds)
// lives.
const SignupTTL = 30 * time.Minute

// SignupBeginRequest is #43's body, decoded.
type SignupBeginRequest struct {
	InviteCode    string
	Email         string
	DisplayName   string
	InviteLinkKey string // 43 b64url characters from the link's fragment, or ""
}

// SignupBegun is #43's answer. It depends only on the invite and link key the
// caller sent and on the address's syntax and tag, never on whether the
// address has an account.
type SignupBegun struct {
	SignupID    string
	UserID      uuid.UUID
	EmailProven bool
	Salt        []byte // s_srv(email_norm)
	Nonce       []byte // the signup nonce C1-P's AAK signatures use
	ExpiresAt   time.Time
}

// SignupBegin is #43 (after the per-IP limiters, which run in the API).
func (a *Accounts) SignupBegin(ctx context.Context, req SignupBeginRequest) (SignupBegun, error) {
	email, err := normEmail(req.Email)
	if err != nil {
		return SignupBegun{}, err
	}
	name, err := DisplayName(req.DisplayName)
	if err != nil {
		return SignupBegun{}, err
	}
	var linkKey []byte
	if req.InviteLinkKey != "" {
		if len(req.InviteLinkKey) != 43 {
			return SignupBegun{}, fmt.Errorf("%w: invite_link_key is not 43 b64url characters", ErrBadRequest)
		}
		if linkKey, err = base64.RawURLEncoding.DecodeString(req.InviteLinkKey); err != nil || len(linkKey) != 32 {
			return SignupBegun{}, fmt.Errorf("%w: invite_link_key is not 43 b64url characters", ErrBadRequest)
		}
	}
	now := a.now()
	codeHash := InviteCodeHash(req.InviteCode)
	inv, err := redeemableInvite(ctx, a.Pool, codeHash, now)
	if err != nil {
		return SignupBegun{}, err
	}
	tag := a.Keys.EmailTag(email)
	if inv.EmailTag != nil && subtle.ConstantTimeCompare(inv.EmailTag, tag) != 1 {
		// The same bytes as an unknown code: the answer says nothing about
		// whom an invite was for.
		return SignupBegun{}, ErrNotInvited
	}
	proven := linkKey != nil && inv.LinkKeyHash != nil && inv.EmailTag != nil &&
		keyproto.InviteLinkKeyMatches(linkKey, inv.LinkKeyHash)

	id, err := newCeremonyIDN(16)
	if err != nil {
		return SignupBegun{}, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return SignupBegun{}, err
	}
	userID := uuid.New()
	out := SignupBegun{SignupID: id, UserID: userID, EmailProven: proven, Salt: a.Keys.PasswordSalt(email),
		Nonce: nonce, ExpiresAt: now.Add(SignupTTL)}

	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignupBegun{}, fmt.Errorf("auth: signup: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	var code *IssuedCode
	var codeID any
	if !proven {
		var inUse bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE email_norm = $1)`, email).Scan(&inUse); err != nil {
			return SignupBegun{}, fmt.Errorf("auth: signup: %w", err)
		}
		c, err := issueCodeTx(ctx, tx, a.Keys, now, PurposeSignup, email, nil, CeremonySignup, id, !inUse)
		if err != nil {
			return SignupBegun{}, err
		}
		c.Notice = inUse
		code, codeID = &c, c.ID
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name,
		   email_proven, code_id, signup_nonce, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		id, userID, codeHash, email, tag, name, proven, codeID, nonce, now, out.ExpiresAt); err != nil {
		return SignupBegun{}, fmt.Errorf("auth: signup: record: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return SignupBegun{}, fmt.Errorf("auth: signup: commit: %w", err)
	}
	if code != nil {
		a.Mail.SendCodes(*code)
	}
	return out, nil
}

// SignupVerify is #44: the signup code; success sets verified_at. Every
// failure is ErrCodeRejected (or ErrRateLimited from the address's counter).
func (a *Accounts) SignupVerify(ctx context.Context, signupID, code string) error {
	now := a.now()
	var (
		codeID *uuid.UUID
		proven bool
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT code_id, email_proven FROM signup_ceremonies
		  WHERE id = $1 AND expires_at > $2 AND verified_at IS NULL AND claimed_at IS NULL`, signupID, now).
		Scan(&codeID, &proven)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (proven || codeID == nil)) {
		return fmt.Errorf("%w: no verifiable signup", ErrCodeRejected)
	}
	if err != nil {
		return fmt.Errorf("auth: signup verify: %w", err)
	}
	if err := limitCodeVerify(ctx, a.Pool, now, *codeID); err != nil {
		return err
	}
	return a.consumeCode(ctx, codeCheck{CodeID: *codeID, Purpose: PurposeSignup, CeremonyKind: CeremonySignup,
		CeremonyID: signupID, Submitted: code}, func(ctx context.Context, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE signup_ceremonies SET verified_at = $2 WHERE id = $1 AND verified_at IS NULL`, signupID, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrCodeRejected
		}
		return nil
	})
}

// consumeCode verifies a code and runs then in one transaction. A wrong guess
// is committed alone after the rollback.
func (a *Accounts) consumeCode(ctx context.Context, c codeCheck, then func(ctx context.Context, tx pgx.Tx) error) error {
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	fail, err := verifyCodeTx(ctx, tx, a.Keys, now, c)
	if err != nil {
		pgtx.Rollback(ctx, tx)
		if fail != nil {
			if _, ferr := fail.apply(ctx, a.Pool, now); ferr != nil {
				return ferr
			}
		}
		return err
	}
	if err := then(ctx, tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// signupRow is a claimed (or claimable) signup.
type signupRow struct {
	ID          string
	UserID      uuid.UUID
	InviteHash  []byte
	EmailNorm   string
	Tag         []byte
	DisplayName string
	Proven      bool
	VerifiedAt  *time.Time
	Nonce       []byte
}

const signupColumns = `id, user_id, invite_code_hash, email_norm, email_tag, display_name, email_proven, verified_at, signup_nonce`

func scanSignup(row pgx.Row) (signupRow, error) {
	var s signupRow
	err := row.Scan(&s.ID, &s.UserID, &s.InviteHash, &s.EmailNorm, &s.Tag, &s.DisplayName, &s.Proven, &s.VerifiedAt, &s.Nonce)
	return s, err
}

// readySignup reads a signup that is verified or proven, unexpired and
// unclaimed (register/begin's check), or ErrCodeRejected.
func readySignup(ctx context.Context, q querier, signupID string, now time.Time) (signupRow, error) {
	s, err := scanSignup(q.QueryRow(ctx, `SELECT `+signupColumns+` FROM signup_ceremonies
		WHERE id = $1 AND expires_at > $2 AND claimed_at IS NULL AND (email_proven OR verified_at IS NOT NULL)`,
		signupID, now))
	if errors.Is(err, pgx.ErrNoRows) {
		return signupRow{}, fmt.Errorf("%w: the signup is not ready", ErrCodeRejected)
	}
	if err != nil {
		return signupRow{}, fmt.Errorf("auth: read signup: %w", err)
	}
	return s, nil
}

// addressFree refuses an address that already has an account: 409
// email_in_use for a proven signup (only the holder of that invite link can
// learn it), else the uniform code_rejected.
func addressFree(ctx context.Context, q querier, s signupRow) error {
	var inUse bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE email_norm = $1)`, s.EmailNorm).Scan(&inUse); err != nil {
		return fmt.Errorf("auth: signup address: %w", err)
	}
	if !inUse {
		return nil
	}
	if s.Proven {
		return ErrEmailInUse
	}
	return fmt.Errorf("%w: the address is in use", ErrCodeRejected)
}

// claimSignupTx claims a ready signup once, inside the account transaction.
func claimSignupTx(ctx context.Context, tx pgx.Tx, signupID string, now time.Time) (signupRow, error) {
	s, err := scanSignup(tx.QueryRow(ctx, `UPDATE signup_ceremonies SET claimed_at = $2
		WHERE id = $1 AND expires_at > $2 AND claimed_at IS NULL AND (email_proven OR verified_at IS NOT NULL)
		RETURNING `+signupColumns, signupID, now))
	if errors.Is(err, pgx.ErrNoRows) {
		return signupRow{}, fmt.Errorf("%w: the signup is not claimable", ErrCodeRejected)
	}
	if err != nil {
		return signupRow{}, fmt.Errorf("auth: claim signup: %w", err)
	}
	return s, nil
}

// createAccountTx inserts the account a claimed signup describes, with the
// given user handle, and redeems its invite and runs the join hook, all in
// tx (spec 02 §10.7.2, §10.7.3). The address is re-checked here: a race with
// another signup is ErrEmailInUse or ErrCodeRejected.
func createAccountTx(ctx context.Context, tx pgx.Tx, s signupRow, handle []byte, now time.Time) error {
	if err := addressFree(ctx, tx, s); err != nil {
		return err
	}
	verified := now
	if s.VerifiedAt != nil {
		verified = *s.VerifiedAt
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO users (id, user_handle, created_at, email_norm, email_verified_at, display_name)
		 VALUES ($1, $2, $3, $4, $5, $6)`, s.UserID, handle, now, s.EmailNorm, verified, s.DisplayName); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" && pg.ConstraintName == "users_email_uniq" {
			if s.Proven {
				return ErrEmailInUse
			}
			return fmt.Errorf("%w: the address is in use", ErrCodeRejected)
		}
		return fmt.Errorf("auth: create account: %w", err)
	}
	inv, err := redeemInviteTx(ctx, tx, s.InviteHash, s.Tag, s.UserID, now)
	if err != nil {
		return err
	}
	if inv.Review {
		if _, err := tx.Exec(ctx, `UPDATE users SET review_account = true WHERE id = $1`, s.UserID); err != nil {
			return fmt.Errorf("auth: create account: review flag: %w", err)
		}
	}
	if err := oplog.EnsureSeqRow(ctx, tx, s.UserID); err != nil {
		return fmt.Errorf("auth: create account: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_usage (user_id, resource, amount) VALUES ($1, 'oplog_hot_bytes', 0) ON CONFLICT DO NOTHING`,
		s.UserID); err != nil {
		return fmt.Errorf("auth: create account: account_usage: %w", err)
	}
	return onInviteRedeemedTx(ctx, tx, inv.ID, s.Tag, now)
}

// signupEmailHash is the email_hash a C1-P bootstrap must carry.
func signupEmailHash(s signupRow) []byte {
	h := keyproto.EmailHash(s.EmailNorm)
	return h[:]
}

// sameBytes is a constant-time equality for secrets and hashes.
func sameBytes(a, b []byte) bool { return len(a) == len(b) && subtle.ConstantTimeCompare(a, b) == 1 }
