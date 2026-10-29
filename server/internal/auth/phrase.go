package auth

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// ViewPhrase is #67 (spec 02 §10.14, spec 01 §10.19): step-up phrase.view with
// a passkey whose credential has a PRF wrap (a password-only account cannot
// open the box), and the box returned in the transaction that records
// phrase_viewed and enqueues its alert. GET /keys never returns it.
func (a *Accounts) ViewPhrase(ctx context.Context, session SessionInfo, su *StepUpObject) ([]byte, error) {
	g, err := guardFor(session, keyproto.ActionPhraseView, su)
	if err != nil {
		return nil, err
	}
	var (
		box       []byte
		firstSeen time.Time
	)
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		var wrapped bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2)`,
			session.UserID, p.CredentialID).Scan(&wrapped); err != nil {
			return err
		}
		if !wrapped {
			return fmt.Errorf("%w: the asserting passkey has no PRF wrap", ErrStepUpFailed)
		}
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if !st.active() {
			return ErrAccountSuspended
		}
		if st.frozen() {
			return ErrAccountFrozen
		}
		if err := tx.QueryRow(ctx, `SELECT phrase_box FROM account_keys WHERE user_id = $1`, session.UserID).Scan(&box); err != nil {
			return ErrNoKeys
		}
		now := a.now()
		tag, err := tx.Exec(ctx,
			`UPDATE account_keys SET phrase_seen_at = greatest(created_at, $2) WHERE user_id = $1 AND phrase_seen_at IS NULL`,
			session.UserID, now)
		if err != nil {
			return fmt.Errorf("auth: phrase view: mark seen: %w", err)
		}
		if tag.RowsAffected() == 1 {
			firstSeen = now
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: EventPhraseViewed, CredentialID: p.CredentialID}, now)
	})
	if err != nil {
		return nil, err
	}
	if !firstSeen.IsZero() {
		a.recordPhraseSeen(session.UserID, firstSeen)
	}
	a.Mail.Kick()
	return box, nil
}

// SetDisplayName is #76: DisplayName, then the column. No step-up, no event,
// no alert: a name is not an authenticator, a key or a mailbox.
func (a *Accounts) SetDisplayName(ctx context.Context, userID uuid.UUID, name string) error {
	n, err := DisplayName(name)
	if err != nil {
		return err
	}
	_, err = a.Pool.Exec(ctx, `UPDATE users SET display_name = $2 WHERE id = $1`, userID, n)
	return err
}

// LogoutAll is #16: step-up session.logout_all, then every session of the
// account (this one included) revoked and every APNs token deleted, with
// sessions_revoked recorded. Writers are not revoked.
func (a *Accounts) LogoutAll(ctx context.Context, session SessionInfo, su *StepUpObject) error {
	g, err := guardFor(session, keyproto.ActionSessionLogoutAll, su)
	if err != nil {
		return err
	}
	var at time.Time
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		now := a.now()
		if _, err := RevokeOtherSessionsTx(ctx, tx, session.UserID, nil, now); err != nil {
			return err
		}
		if err := forgetPushTokens(ctx, tx, `user_id = $1`, session.UserID); err != nil {
			return err
		}
		at = now
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: EventSessionsRevoked, WriterID: p.WriterID,
			CredentialID: p.CredentialID}, now)
	})
	if err != nil {
		return err
	}
	a.recordSessions(session.UserID, at)
	return nil
}
