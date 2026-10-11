package auth

// Freeze and unfreeze (spec 02 §9.8, §10.13; spec 01 §10.18). A freeze only
// removes access: every session is revoked, and sign-ins mint restricted
// sessions until a full sign-in proves a factor older than the event that
// triggered the freeze. Four ways in:
//   - the freeze link (#64) from a new-sign-in or recovery-used alert, dated
//     to that event;
//   - the in-app lockdown (#65), step-up account.freeze, dated now;
//   - the device freeze (#77, #78, D42): an enrolled iPhone with no session
//     signs DeviceFreezeMessage with its DAK, dated back to when something
//     else signed it out;
//   - the operator (OperatorFreeze), which outranks a holder's freeze.
// Only the operator lifts an operator freeze (review 2 F-03).

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// DeviceFreezeTTL is a device-freeze nonce's lifetime.
const DeviceFreezeTTL = 5 * time.Minute

// deviceFreezeBackdate bounds how far a device freeze is dated back.
const deviceFreezeBackdate = 7 * 24 * time.Hour

// Who froze an account.
const (
	FrozenByHolder   = "holder"
	FrozenByOperator = "operator"
)

// freezeTx freezes the account with trigger time t: frozen_at is the first
// freeze's time, freeze_trigger_at the earliest trigger; a holder's freeze on
// an operator-frozen account is remembered in holder_also_froze and changes
// nothing else about who may lift it. Every session except keep is revoked
// and account_frozen recorded (with its alert).
func freezeTx(ctx context.Context, tx pgx.Tx, m *Mailer, userID uuid.UUID, by string, trigger, now time.Time, keep [][]byte, writer string) error {
	var q string
	if by == FrozenByOperator {
		q = `UPDATE users SET frozen_at = coalesce(frozen_at, $2),
		        freeze_trigger_at = least(coalesce(freeze_trigger_at, $3), $3),
		        holder_also_froze = holder_also_froze OR coalesce(frozen_by = 'holder', false),
		        frozen_by = 'operator'
		      WHERE id = $1`
	} else {
		q = `UPDATE users SET frozen_at = coalesce(frozen_at, $2),
		        freeze_trigger_at = least(coalesce(freeze_trigger_at, $3), $3),
		        holder_also_froze = holder_also_froze OR coalesce(frozen_by = 'operator', false),
		        frozen_by = CASE WHEN frozen_by = 'operator' THEN 'operator' ELSE 'holder' END
		      WHERE id = $1`
	}
	if trigger.After(now) {
		trigger = now
	}
	tag, err := tx.Exec(ctx, q, userID, now, trigger)
	if err != nil {
		return fmt.Errorf("auth: freeze: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return ErrNoSuchAccount
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, userID, keep, now); err != nil {
		return err
	}
	return recordEventTx(ctx, tx, m, userID, AuthEvent{Kind: EventAccountFrozen, WriterID: writer}, now)
}

// FreezeByLink is #64. It answers nothing: the route always answers 204, and
// an invalid, used or expired token changes nothing.
func (a *Accounts) FreezeByLink(ctx context.Context, token string) error {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 32 || len(token) != 43 {
		return nil
	}
	h := sha256.Sum256(raw)
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	var (
		userID  uuid.UUID
		trigger time.Time
	)
	err = tx.QueryRow(ctx,
		`UPDATE freeze_tokens SET used_at = $2 WHERE token_hash = $1 AND used_at IS NULL AND expires_at > $2
		 RETURNING user_id, trigger_at`, h[:], now).Scan(&userID, &trigger)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := freezeTx(ctx, tx, a.Mail, userID, FrozenByHolder, trigger, now, nil, ""); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	a.Mail.Kick()
	return nil
}

// FreezeNow is #65: step-up account.freeze, dated now, revoking every session
// including this one.
func (a *Accounts) FreezeNow(ctx context.Context, session SessionInfo, su *StepUpObject) error {
	ph, err := keyproto.ParamsHash(keyproto.ActionAccountFreeze)
	if err != nil {
		return err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionAccountFreeze, ParamsHash: ph, StepUp: su}
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if st.frozen() {
			return ErrAccountFrozen
		}
		now := a.now()
		return freezeTx(ctx, tx, a.Mail, session.UserID, FrozenByHolder, now, now, nil, p.WriterID)
	})
	if err == nil {
		a.Mail.Kick()
	}
	return err
}

// Unfreeze is #66: refused while frozen_by = 'operator' (nothing consumed),
// then step-up account.unfreeze whose factor predates freeze_trigger_at: the
// asserting passkey's created_at, or (device) the writer's registered_at and
// the password's password_set_at. The session stops being restricted and every
// other session is revoked.
func (a *Accounts) Unfreeze(ctx context.Context, session SessionInfo, su *StepUpObject) error {
	st, err := readAccount(ctx, a.Pool, session.UserID, false)
	if err != nil {
		return err
	}
	if !st.frozen() {
		return fmt.Errorf("%w: the account is not frozen", ErrBadRequest)
	}
	if st.FrozenBy != nil && *st.FrozenBy == FrozenByOperator {
		return fmt.Errorf("%w: only the operator lifts an operator freeze", ErrAccountFrozen)
	}
	if su == nil {
		return ErrStepUpRequired
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionAccountUnfreeze)
	if err != nil {
		return err
	}
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionAccountUnfreeze, ParamsHash: ph, StepUp: su}
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if !st.frozen() {
			return fmt.Errorf("%w: the account is not frozen", ErrBadRequest)
		}
		if st.FrozenBy != nil && *st.FrozenBy == FrozenByOperator {
			return fmt.Errorf("%w: only the operator lifts an operator freeze", ErrAccountFrozen)
		}
		trigger := *st.FreezeTriggerAt
		switch p.Kind {
		case keyproto.ProofPasskey:
			var created time.Time
			if err := tx.QueryRow(ctx, `SELECT created_at FROM webauthn_credentials WHERE credential_id = $1`,
				p.CredentialID).Scan(&created); err != nil || !created.Before(trigger) {
				return fmt.Errorf("%w: the passkey is not older than the freeze", ErrStepUpFailed)
			}
		case keyproto.ProofDevice:
			var registered time.Time
			if err := tx.QueryRow(ctx, `SELECT registered_at FROM writers WHERE user_id = $1 AND writer_id = $2`,
				session.UserID, p.WriterID).Scan(&registered); err != nil || !registered.Before(trigger) ||
				st.PasswordSetAt == nil || !st.PasswordSetAt.Before(trigger) {
				return fmt.Errorf("%w: the device or the password is not older than the freeze", ErrStepUpFailed)
			}
		default:
			return fmt.Errorf("%w: proof kind %s", ErrStepUpFailed, p.Kind)
		}
		now := a.now()
		if _, err := tx.Exec(ctx,
			`UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL, holder_also_froze = false
			  WHERE id = $1`, session.UserID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET restricted = false WHERE token_hash = $1`, session.Hash); err != nil {
			return err
		}
		if _, err := RevokeOtherSessionsTx(ctx, tx, session.UserID, [][]byte{session.Hash}, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: EventAccountUnfrozen,
			WriterID: p.WriterID, CredentialID: p.CredentialID}, now)
	})
	if err == nil {
		a.Mail.Kick()
	}
	return err
}

// DeviceFreezeChallenge is #77: a nonce for any well-formed writer id, with no
// account lookup, so the answer says nothing about writers.
func (a *Accounts) DeviceFreezeChallenge(ctx context.Context, writerID string) ([]byte, time.Time, error) {
	if !keyproto.ValidWriterID(writerID) {
		return nil, time.Time{}, ErrBadWriterID
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return nil, time.Time{}, err
	}
	now := a.now()
	exp := now.Add(DeviceFreezeTTL)
	if _, err := a.Pool.Exec(ctx,
		`INSERT INTO device_freeze_challenges (nonce, writer_id, issued_at, expires_at) VALUES ($1, $2, $3, $4)`,
		nonce, writerID, now, exp); err != nil {
		return nil, time.Time{}, fmt.Errorf("auth: device freeze challenge: %w", err)
	}
	return nonce, exp, nil
}

// DeviceFreeze is #78: the nonce is spent by the attempt in its own statement;
// exactly one live writer with that id must have signed DeviceFreezeMessage
// with its DAK. The freeze is dated back to the writer's latest session
// revocation caused by something else, when that is within seven days. Every
// failure is ErrFreezeRefused.
func (a *Accounts) DeviceFreeze(ctx context.Context, writerID string, nonce, sig []byte) error {
	if !keyproto.ValidWriterID(writerID) || len(nonce) != keyproto.NonceSize {
		return fmt.Errorf("%w: malformed", ErrFreezeRefused)
	}
	now := a.now()
	tag, err := a.Pool.Exec(ctx,
		`UPDATE device_freeze_challenges SET used_at = $3
		  WHERE nonce = $1 AND writer_id = $2 AND used_at IS NULL AND expires_at > $3`, nonce, writerID, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return fmt.Errorf("%w: unknown, used, expired or another writer's nonce", ErrFreezeRefused)
	}
	rows, err := a.Pool.Query(ctx, `SELECT user_id, dak_pubkey FROM writers WHERE writer_id = $1 AND revoked_at IS NULL`, writerID)
	if err != nil {
		return err
	}
	type cand struct {
		user uuid.UUID
		dak  []byte
	}
	var cands []cand
	for rows.Next() {
		var c cand
		if err := rows.Scan(&c.user, &c.dak); err != nil {
			rows.Close()
			return err
		}
		cands = append(cands, c)
	}
	rows.Close()
	if len(cands) != 1 {
		return fmt.Errorf("%w: no single live writer", ErrFreezeRefused)
	}
	c := cands[0]
	msg, err := keyproto.DeviceFreezeMessage(nonce, c.user, writerID)
	if err != nil || !keyproto.VerifyDAKBytes(c.dak, msg, sig) {
		return fmt.Errorf("%w: the DAK signature", ErrFreezeRefused)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	if err := lockUser(ctx, tx, c.user); err != nil {
		return fmt.Errorf("%w: %v", ErrFreezeRefused, err)
	}
	trigger := now
	var signedOut *time.Time
	if err := tx.QueryRow(ctx,
		`SELECT max(revoked_at) FROM sessions WHERE user_id = $1 AND writer_id = $2 AND revoked_reason = 'others'`,
		c.user, writerID).Scan(&signedOut); err != nil {
		return err
	}
	if signedOut != nil && signedOut.After(now.Add(-deviceFreezeBackdate)) {
		trigger = *signedOut
	}
	if err := freezeTx(ctx, tx, a.Mail, c.user, FrozenByHolder, trigger, now, nil, writerID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	a.Mail.Kick()
	return nil
}

// OperatorFreeze is the console's freeze (C36, O-18): spec 01 §10.18's freeze
// with trigger now and frozen_by 'operator' (a holder's freeze in place is
// kept in holder_also_froze), every session revoked, account_frozen recorded
// and its alert queued. It needs no key, no mail token and no network.
func OperatorFreeze(ctx context.Context, tx pgx.Tx, userID uuid.UUID, now time.Time, m *Mailer) error {
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	return freezeTx(ctx, tx, m, userID, FrozenByOperator, now, now, nil, "")
}

// UnfreezeScope is who an operator unfreeze may lift.
type UnfreezeScope int

// Scopes.
const (
	// ScopeOperatorOnly is the console's C37: it lifts only an operator
	// freeze, and hands one that also carries a holder's freeze back to the
	// holder instead of lifting it.
	ScopeOperatorOnly UnfreezeScope = iota
	// ScopeAny is the CLI's `account unfreeze`, after the out-of-band check:
	// it lifts any freeze.
	ScopeAny
)

// ErrHolderFreeze is C37 meeting a holder's freeze, which it never lifts.
var ErrHolderFreeze = errors.New("auth: the holder froze this account; the console does not lift it")

// OperatorUnfreeze is the operator's unfreeze. It answers whether the account
// is unfrozen afterwards (false when C37 handed it back to the holder).
func OperatorUnfreeze(ctx context.Context, tx pgx.Tx, userID uuid.UUID, scope UnfreezeScope, now time.Time, m *Mailer) (bool, error) {
	st, err := readAccount(ctx, tx, userID, true)
	if err != nil {
		return false, err
	}
	if !st.frozen() {
		return true, nil
	}
	var holderToo bool
	if err := tx.QueryRow(ctx, `SELECT holder_also_froze FROM users WHERE id = $1`, userID).Scan(&holderToo); err != nil {
		return false, err
	}
	if scope == ScopeOperatorOnly {
		if *st.FrozenBy != FrozenByOperator {
			return false, ErrHolderFreeze
		}
		if holderToo {
			_, err := tx.Exec(ctx, `UPDATE users SET frozen_by = 'holder', holder_also_froze = false WHERE id = $1`, userID)
			return false, err
		}
	}
	if _, err := tx.Exec(ctx,
		`UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL, holder_also_froze = false WHERE id = $1`,
		userID); err != nil {
		return false, err
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, userID, nil, now); err != nil {
		return false, err
	}
	return true, recordEventTx(ctx, tx, m, userID, AuthEvent{Kind: EventAccountUnfrozen}, now)
}
