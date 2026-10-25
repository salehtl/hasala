package auth

// How this package's emails reach mailq (spec 02 §14.4, D-12):
//   - codes and the "already has an account" notice: minted in the request's
//     transaction, handed to SendCodes after commit, and sent by
//     mailq.SendNow off the request path, so the answer's timing never
//     depends on whether an email goes out;
//   - alerts: enqueued with mailq.EnqueueTx in the event's own transaction;
//     the alert renderer mints the freeze token at send time;
//   - a queued code row (the operator's re-verification, C38): the code
//     renderer issues the code inside the render transaction.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
)

// FreezeTokenTTL is how long a freeze link works.
const FreezeTokenTTL = 7 * 24 * time.Hour

// Mailer is this package's side of the outbox.
type Mailer struct {
	Queue     *mailq.Queue
	Keys      *authkeys.Keys
	FreezeURL string // default mail.DefaultFreezeURL
	Now       func() time.Time
	// Async runs post-commit sends; nil starts a goroutine. Tests run them
	// inline so they can read the code from the fake sender.
	Async func(func())
	Logf  func(format string, args ...any)
}

func (m *Mailer) now() time.Time {
	if m != nil && m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Mailer) logf(format string, args ...any) {
	if m != nil && m.Logf != nil {
		m.Logf(format, args...)
	}
}

// SendCodes sends each issued code (or its notice) after the request's
// transaction committed. Codes written with Send = false and no notice send
// nothing. A nil Mailer sends nothing.
func (m *Mailer) SendCodes(codes ...IssuedCode) {
	if m == nil || m.Queue == nil {
		return
	}
	for _, c := range codes {
		if !c.Send && !c.Notice {
			continue
		}
		run := func() {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			e := mailq.Enqueue{Kind: mail.CodeKind(c.Purpose), Lane: mailq.LaneTransactional, To: c.To, Tag: c.Tag,
				UserID: c.UserID, Params: map[string]any{"purpose": c.Purpose}}
			render := func() (mail.Message, error) { return mail.Code(c.To, c.Purpose, c.Code, c.Name) }
			if c.Notice {
				e.Kind, e.Subkind, e.UserID = "code", "address_in_use", nil
				render = func() (mail.Message, error) { return mail.AddressInUse(c.To), nil }
			}
			if err := m.Queue.SendNow(ctx, e, render); err != nil {
				m.logf("auth: code email (%s): %v", c.Purpose, err)
			}
		}
		if m.Async != nil {
			m.Async(run)
		} else {
			go run()
		}
	}
}

// Kick wakes the worker after an alert's transaction committed.
func (m *Mailer) Kick() {
	if m != nil && m.Queue != nil {
		m.Queue.Kick()
	}
}

// enqueueAlertTx writes an alert row in the event's transaction (spec 02
// §10.16). The address is the account's at this moment unless to is set.
func (m *Mailer) enqueueAlertTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, subkind, to string, at time.Time) error {
	if m == nil || m.Queue == nil {
		return nil
	}
	if to == "" {
		if err := tx.QueryRow(ctx, `SELECT email_norm FROM users WHERE id = $1`, userID).Scan(&to); err != nil {
			return fmt.Errorf("auth: alert address: %w", err)
		}
	}
	var tag []byte
	if m.Keys != nil {
		tag = m.Keys.EmailTag(to)
	}
	_, err := m.Queue.EnqueueTx(ctx, tx, mailq.Enqueue{Kind: "alert", Subkind: subkind, Lane: mailq.LaneTransactional,
		To: to, Tag: tag, UserID: &userID, Params: map[string]any{"event_at": at.UTC().Format(time.RFC3339Nano)}})
	return err
}

// Renderers are this package's renderers for queued rows: alerts and codes.
func (m *Mailer) Renderers() map[string]mailq.Renderer {
	return map[string]mailq.Renderer{
		"alert": mailq.RenderFunc(m.renderAlert),
		"code":  mailq.RenderFunc(m.renderQueuedCode),
	}
}

// Register installs this package's renderers and the bounce hook (spec 02
// §14.7) on q, the server's one outbox.
func (m *Mailer) Register(q *mailq.Queue) {
	for kind, r := range m.Renderers() {
		q.Register(kind, r)
	}
	q.Bounced = BounceHook
}

// renderAlert builds an alert at send time, greeting by name, and mints the
// freeze token for the two subkinds that carry one (spec 02 §10.13).
func (m *Mailer) renderAlert(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
	if row.UserID == nil {
		return mail.Message{}, errors.New("auth: an alert row has no account")
	}
	var name string
	if err := tx.QueryRow(ctx, `SELECT display_name FROM users WHERE id = $1`, *row.UserID).Scan(&name); err != nil {
		return mail.Message{}, fmt.Errorf("auth: alert greeting: %w", err)
	}
	at := row.CreatedAt
	if s, ok := row.Params["event_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			at = t
		}
	}
	link := ""
	if mail.AlertCarriesFreezeLink(row.Subkind) {
		trigger := "new_sign_in"
		if row.Subkind == "recovery_used_passkey" || row.Subkind == "recovery_used_password" {
			trigger = "recovery_used"
		}
		if row.Subkind == "phrase_viewed" {
			trigger = "phrase_viewed"
		}
		raw, err := randBytes(32)
		if err != nil {
			return mail.Message{}, err
		}
		h := sha256.Sum256(raw)
		now := m.now()
		if _, err := tx.Exec(ctx,
			`INSERT INTO freeze_tokens (token_hash, user_id, trigger_kind, trigger_at, created_at, expires_at)
			 VALUES ($1, $2, $3, $4, $5, $6)`, h[:], *row.UserID, trigger, at, now, now.Add(FreezeTokenTTL)); err != nil {
			return mail.Message{}, fmt.Errorf("auth: mint freeze token: %w", err)
		}
		base := m.FreezeURL
		if base == "" {
			base = mail.DefaultFreezeURL
		}
		link = base + "#" + base64.RawURLEncoding.EncodeToString(raw)
	}
	return mail.Alert(row.Recipient, row.Subkind, at, name, link)
}

// renderQueuedCode issues the code of a queued code row (the operator's
// re-verification request) inside the render transaction.
func (m *Mailer) renderQueuedCode(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
	purpose, _ := row.Params["purpose"].(string)
	if purpose != PurposeEmailVerify || row.UserID == nil || m.Keys == nil {
		return mail.Message{}, fmt.Errorf("auth: no queued code renderer for purpose %q", purpose)
	}
	var name, addr string
	if err := tx.QueryRow(ctx, `SELECT display_name, email_norm FROM users WHERE id = $1`, *row.UserID).Scan(&name, &addr); err != nil {
		return mail.Message{}, err
	}
	if addr != row.Recipient {
		return mail.Message{}, errors.New("auth: the account's address changed since the code was queued")
	}
	c, err := issueCodeTx(ctx, tx, m.Keys, m.now(), PurposeEmailVerify, addr, row.UserID, CeremonyEmailVerify,
		row.UserID.String(), true)
	if err != nil {
		return mail.Message{}, err
	}
	return mail.Code(addr, PurposeEmailVerify, c.Code, name)
}

// BounceHook marks an account's address undeliverable when a send to its
// current address bounced (spec 02 §14.7).
func BounceHook(ctx context.Context, tx pgx.Tx, row mailq.Row) error {
	_, err := tx.Exec(ctx,
		`UPDATE users SET email_undeliverable_at = now() WHERE id = $1 AND email_norm = $2`, *row.UserID, row.Recipient)
	return err
}

// Auth events (spec 02 §10.16).
const (
	EventSignInNew       = "sign_in_new"
	EventPasskeyAdded    = "passkey_added"
	EventPasskeyRemoved  = "passkey_removed"
	EventPasswordSet     = "password_set"
	EventPasswordChanged = "password_changed"
	EventPasswordRemoved = "password_removed"
	EventPasswordReset   = "password_reset"
	EventRecoveryUsed    = "recovery_used"
	EventPhraseViewed    = "phrase_viewed"
	EventPhraseRotated   = "phrase_rotated"
	EventDeviceAdded     = "device_added"
	EventDeviceRemoved   = "device_removed"
	EventEmailChanged    = "email_changed"
	EventEmailVerified   = "email_verified"
	EventAccountFrozen   = "account_frozen"
	EventAccountUnfrozen = "account_unfrozen"
	EventSessionsRevoked = "sessions_revoked"
	EventMailboxLinked   = "mailbox_linked"
	EventMailboxUnlinked = "mailbox_unlinked"

	MethodPasskey  = "passkey"
	MethodPassword = "password"
)

// AuthEvent is one auth_events row.
type AuthEvent struct {
	Kind         string
	Method       string
	WriterID     string
	CredentialID []byte
}

// alertSubkind is the alert an event sends, or "" (spec 02 §10.16's table).
// email_changed is handled by its route (two alerts).
func alertSubkind(e AuthEvent) string {
	switch e.Kind {
	case EventSignInNew:
		return "new_sign_in_" + e.Method
	case EventRecoveryUsed:
		return "recovery_used_" + e.Method
	case EventPasskeyAdded:
		return "new_passkey"
	case EventPasswordSet, EventPasswordChanged, EventPasswordRemoved, EventPasswordReset,
		EventPhraseViewed, EventDeviceRemoved, EventAccountFrozen, EventAccountUnfrozen:
		return e.Kind
	}
	return ""
}

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// RecordQuietEventTx records an event that sends no alert, in the caller's
// transaction: the mailbox link and unlink, whose actions the API runs (spec
// 02 §10.16). An event that carries an alert is refused here; its action
// records it.
func RecordQuietEventTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, e AuthEvent, at time.Time) error {
	if alertSubkind(e) != "" {
		return fmt.Errorf("auth: %s sends an alert; its action records it", e.Kind)
	}
	return recordEventTx(ctx, tx, nil, userID, e, at)
}

// recordEventTx writes the event and enqueues its alert, both in the
// action's transaction: a rolled-back action sends nothing, and a restart
// loses nothing.
func recordEventTx(ctx context.Context, tx pgx.Tx, m *Mailer, userID uuid.UUID, e AuthEvent, at time.Time) error {
	var cred any
	if len(e.CredentialID) > 0 {
		cred = e.CredentialID
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO auth_events (user_id, kind, at, method, writer_id, credential_id) VALUES ($1, $2, $3, $4, $5, $6)`,
		userID, e.Kind, at, nullStr(e.Method), nullStr(e.WriterID), cred); err != nil {
		return fmt.Errorf("auth: record %s: %w", e.Kind, err)
	}
	if sub := alertSubkind(e); sub != "" {
		return m.enqueueAlertTx(ctx, tx, userID, sub, "", at)
	}
	return nil
}
