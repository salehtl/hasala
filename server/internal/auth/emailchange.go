package auth

// Email change and re-verification (spec 02 §10.12, spec 01 §10.17; routes
// #60–#63). A change needs a step-up plus a code to the new address and either
// a code to the old one or, when the old mailbox is lost, the recovery key's
// signature. A password user's verifier is re-salted for the new address,
// because s_srv is a function of it.

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// EmailChangeTTL is an email-change ceremony's lifetime.
const EmailChangeTTL = 10 * time.Minute

// EmailChangeBegun is #60's answer, identical whether or not the new address
// is in use.
type EmailChangeBegun struct {
	ChangeID uuid.UUID
	Nonce    []byte
}

// EmailChangeBegin is #60.
func (a *Accounts) EmailChangeBegin(ctx context.Context, session SessionInfo, newEmail string, verifierNew []byte, su *StepUpObject) (EmailChangeBegun, error) {
	addr, err := normEmail(newEmail)
	if err != nil {
		return EmailChangeBegun{}, err
	}
	st, err := readAccount(ctx, a.Pool, session.UserID, false)
	if err != nil {
		return EmailChangeBegun{}, err
	}
	if addr == st.EmailNorm {
		return EmailChangeBegun{}, fmt.Errorf("%w: that is the current address", ErrBadRequest)
	}
	if st.hasPassword() != (verifierNew != nil) {
		return EmailChangeBegun{}, fmt.Errorf("%w: verifier_new is required exactly when the account has a password", ErrBadRequest)
	}
	addrHash := sha256.Sum256([]byte(addr))
	second := []byte{}
	if verifierNew != nil {
		if second, err = verifierHash(verifierNew); err != nil {
			return EmailChangeBegun{}, err
		}
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionEmailChange, addrHash[:], second)
	if err != nil {
		return EmailChangeBegun{}, err
	}
	if su == nil {
		return EmailChangeBegun{}, ErrStepUpRequired
	}
	id := uuid.New()
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return EmailChangeBegun{}, err
	}
	var codes []IssuedCode
	g := Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionEmailChange, ParamsHash: ph, StepUp: su}
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		now := a.now()
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		var hash, salt []byte
		if verifierNew != nil {
			if hash, salt, err = newPasswordHash(ctx, a.Keys, a.Gate, verifierNew); err != nil {
				return err
			}
		}
		var inUse bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE email_norm = $1)`, addr).Scan(&inUse); err != nil {
			return err
		}
		old, err := issueCodeTx(ctx, tx, a.Keys, now, PurposeEmailChangeOld, st.EmailNorm, &st.ID, CeremonyEmailChange, id.String(), true)
		if err != nil {
			return err
		}
		old.Name = st.DisplayName
		fresh, err := issueCodeTx(ctx, tx, a.Keys, now, PurposeEmailChangeNew, addr, &st.ID, CeremonyEmailChange, id.String(), !inUse)
		if err != nil {
			return err
		}
		fresh.Notice = inUse
		if inUse {
			fresh.UserID = nil
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO email_change_ceremonies (id, user_id, new_email_norm, new_email_tag, new_in_use, new_password_hash,
			   new_password_salt, change_nonce, code_old_id, code_new_id, created_at, expires_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
			id, st.ID, addr, a.Keys.EmailTag(addr), inUse, hash, salt, nonce, old.ID, fresh.ID, now, now.Add(EmailChangeTTL)); err != nil {
			return fmt.Errorf("auth: email change begin: %w", err)
		}
		codes = []IssuedCode{old, fresh}
		return nil
	})
	if err != nil {
		return EmailChangeBegun{}, err
	}
	a.Mail.SendCodes(codes...)
	return EmailChangeBegun{ChangeID: id, Nonce: nonce}, nil
}

// EmailChangeFinish is #61: the new address's code, and the old address's
// code or the recovery key's signature over EmailChangeMessage. Every
// failure is ErrCodeRejected.
func (a *Accounts) EmailChangeFinish(ctx context.Context, session SessionInfo, changeID uuid.UUID, codeNew string,
	codeOld *string, rkSig []byte) error {
	if (codeOld == nil) == (rkSig == nil) {
		return fmt.Errorf("%w: exactly one of code_old and rk_sig", ErrBadRequest)
	}
	now := a.now()
	var (
		newAddr      string
		inUse        bool
		hash, salt   []byte
		nonce        []byte
		oldID, newID uuid.UUID
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT new_email_norm, new_in_use, new_password_hash, new_password_salt, change_nonce, code_old_id, code_new_id
		   FROM email_change_ceremonies WHERE id = $1 AND user_id = $2 AND consumed_at IS NULL AND expires_at > $3`,
		changeID, session.UserID, now).Scan(&newAddr, &inUse, &hash, &salt, &nonce, &oldID, &newID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && inUse) {
		return fmt.Errorf("%w: no change to finish", ErrCodeRejected)
	}
	if err != nil {
		return err
	}
	if err := limitCodeVerify(ctx, a.Pool, now, newID); err != nil {
		return err
	}
	if codeOld != nil {
		if err := limitCodeVerify(ctx, a.Pool, now, oldID); err != nil {
			return err
		}
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	var failures []*codeFailure
	var refusal error
	fNew, err := verifyCodeTx(ctx, tx, a.Keys, now, codeCheck{CodeID: newID, Purpose: PurposeEmailChangeNew,
		CeremonyKind: CeremonyEmailChange, CeremonyID: changeID.String(), Submitted: codeNew})
	if err != nil {
		refusal = err
		if fNew != nil {
			failures = append(failures, fNew)
		}
	}
	if codeOld != nil {
		fOld, err := verifyCodeTx(ctx, tx, a.Keys, now, codeCheck{CodeID: oldID, Purpose: PurposeEmailChangeOld,
			CeremonyKind: CeremonyEmailChange, CeremonyID: changeID.String(), Submitted: *codeOld})
		if err != nil {
			refusal = err
			if fOld != nil {
				failures = append(failures, fOld)
			}
		}
	} else {
		var rk []byte
		if err := tx.QueryRow(ctx, `SELECT recovery_pubkey FROM account_keys WHERE user_id = $1`, session.UserID).Scan(&rk); err != nil {
			refusal = fmt.Errorf("%w: no recovery key", ErrCodeRejected)
		} else if msg, err := keyproto.EmailChangeMessage(nonce, newAddr); err != nil || !keyproto.VerifyEd25519(rk, msg, rkSig) {
			refusal = fmt.Errorf("%w: rk_sig", ErrCodeRejected)
		}
	}
	if refusal != nil {
		pgtx.Rollback(ctx, tx)
		for _, f := range failures {
			if _, err := f.apply(ctx, a.Pool, now); err != nil {
				return err
			}
		}
		return refusal
	}
	st, err := readAccount(ctx, tx, session.UserID, true)
	if err != nil {
		return err
	}
	if st.frozen() {
		return ErrAccountFrozen
	}
	if _, err := tx.Exec(ctx,
		`UPDATE users SET email_norm = $2, email_verified_at = $3, email_undeliverable_at = NULL,
		        password_hash = coalesce($4, password_hash), password_salt = coalesce($5, password_salt)
		  WHERE id = $1`, st.ID, newAddr, now, hash, salt); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			return fmt.Errorf("%w: the address was taken meanwhile", ErrCodeRejected)
		}
		return err
	}
	if hash != nil {
		if _, err := tx.Exec(ctx, `UPDATE users SET password_version = $2 WHERE id = $1`, st.ID, a.Keys.Current()); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE email_change_ceremonies SET consumed_at = $2 WHERE id = $1`, changeID, now); err != nil {
		return err
	}
	if err := recordEventTx(ctx, tx, a.Mail, st.ID, AuthEvent{Kind: EventEmailChanged}, now); err != nil {
		return err
	}
	if err := a.Mail.enqueueAlertTx(ctx, tx, st.ID, "email_changed_new", newAddr, now); err != nil {
		return err
	}
	if err := a.Mail.enqueueAlertTx(ctx, tx, st.ID, "email_changed_old", st.EmailNorm, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	a.Mail.Kick()
	return nil
}

// EmailVerifyBegin is #62: an email_verify code to the current address,
// bound to the account itself as the ceremony.
func (a *Accounts) EmailVerifyBegin(ctx context.Context, userID uuid.UUID) error {
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	st, err := readAccount(ctx, tx, userID, false)
	if err != nil {
		return err
	}
	c, err := issueCodeTx(ctx, tx, a.Keys, a.now(), PurposeEmailVerify, st.EmailNorm, &st.ID, CeremonyEmailVerify, st.ID.String(), true)
	if err != nil {
		return err
	}
	c.Name = st.DisplayName
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	a.Mail.SendCodes(c)
	return nil
}

// EmailVerifyFinish is #63: the newest unused, unexpired email_verify code of
// the account; success re-verifies the address and clears the bounce and the
// operator's request.
func (a *Accounts) EmailVerifyFinish(ctx context.Context, userID uuid.UUID, code string) error {
	now := a.now()
	var codeID uuid.UUID
	err := a.Pool.QueryRow(ctx,
		`SELECT code_id FROM email_codes
		  WHERE ceremony_kind = 'email_verify' AND ceremony_id = $1 AND purpose = 'email_verify'
		    AND used_at IS NULL AND burned_at IS NULL AND expires_at > $2 AND sent
		  ORDER BY created_at DESC LIMIT 1`, userID.String(), now).Scan(&codeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: no code", ErrCodeRejected)
	}
	if err != nil {
		return err
	}
	if err := limitCodeVerify(ctx, a.Pool, now, codeID); err != nil {
		return err
	}
	return a.consumeCode(ctx, codeCheck{CodeID: codeID, Purpose: PurposeEmailVerify, CeremonyKind: CeremonyEmailVerify,
		CeremonyID: userID.String(), Submitted: code}, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`UPDATE users SET email_verified_at = $2, email_undeliverable_at = NULL, reverify_requested_at = NULL WHERE id = $1`,
			userID, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, userID, AuthEvent{Kind: EventEmailVerified}, now)
	})
}
