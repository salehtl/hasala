package auth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

// Accounts owns the account ceremonies of spec 02 §10.4 and §10.7–§10.13:
// signup and account creation, password sign-in, set, change, remove and the
// two resets, access recovery, email change and re-verification, freeze and
// unfreeze. Passkeys owns the WebAuthn halves; StepUp the step-ups; Sessions
// the tokens.
type Accounts struct {
	Pool     *pgxpool.Pool
	Keys     *authkeys.Keys
	Gate     *authkeys.Gate // the PBKDF2 gate (spec 02 §16.2); nil runs ungated
	Sessions *Sessions
	Passkeys *Passkeys
	StepUp   *StepUp
	Mail     *Mailer
	Now      func() time.Time
	Record   func(purgeledger.Entry)
}

func (a *Accounts) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

// Errors the account ceremonies share. Each maps to one answer (spec 02 §6.3).
var (
	ErrBadRequest        = errors.New("auth: malformed request")                         // 400 bad_request
	ErrBadEmail          = errors.New("auth: not an address this beta accepts")          // 400 bad_email
	ErrEmailInUse        = errors.New("auth: the proven address already has an account") // 409 email_in_use
	ErrPasswordRejected  = errors.New("auth: password sign-in failed")                   // 403 password_rejected
	ErrRecoveryRefused   = errors.New("auth: recovery refused")                          // 403 recovery_refused
	ErrResetRefused      = errors.New("auth: reset refused")                             // 403 reset_refused
	ErrNotApproved       = errors.New("auth: the reset is not approved yet")             // 409 not_approved
	ErrFreezeRefused     = errors.New("auth: device freeze refused")                     // 403 freeze_refused
	ErrAccountFrozen     = errors.New("auth: the account is frozen")                     // 403 account_frozen
	ErrAccountSuspended  = errors.New("auth: the account is suspended")                  // 403 account_suspended
	ErrConflict          = errors.New("auth: the account already has a password")        // 409 conflict
	ErrLastAuthenticator = errors.New("auth: it is the account's last authenticator")    // 409 last_authenticator
	ErrUnavailable       = errors.New("auth: try again shortly")                         // 503 unavailable
	ErrNoSuchAccount     = errors.New("auth: no such account")                           // 404 not_found (#7)
)

// gateErr maps the PBKDF2 gate's refusal.
func gateErr(err error) error {
	if errors.Is(err, authkeys.ErrGateBusy) {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	return err
}

func uniqueViolation(err error) *pgconn.PgError {
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "23505" {
		return pg
	}
	return nil
}

// newCeremonyIDN is b64url of n random bytes.
func newCeremonyIDN(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("auth: mint ceremony id: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func randBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("auth: read random: %w", err)
	}
	return b, nil
}

// accountState is what the ceremonies read about an account.
type accountState struct {
	ID              uuid.UUID
	EmailNorm       string
	DisplayName     string
	Status          string
	PasswordHash    []byte
	PasswordSalt    []byte
	PasswordVersion *int16
	PasswordSetAt   *time.Time
	Failures        int
	PausedUntil     *time.Time
	FrozenAt        *time.Time
	FreezeTriggerAt *time.Time
	FrozenBy        *string
	HasKeys         bool
}

func (s accountState) frozen() bool      { return s.FrozenAt != nil }
func (s accountState) active() bool      { return s.Status == "active" }
func (s accountState) hasPassword() bool { return len(s.PasswordHash) > 0 }
func (s accountState) operatorFrozen() bool {
	return s.FrozenBy != nil && *s.FrozenBy == FrozenByOperator
}

const accountColumns = `u.id, u.email_norm, u.display_name, u.status, u.password_hash, u.password_salt,
	u.password_version, u.password_set_at, u.password_failures, u.password_paused_until, u.frozen_at,
	u.freeze_trigger_at, u.frozen_by, EXISTS (SELECT 1 FROM account_keys k WHERE k.user_id = u.id)`

func scanAccount(row pgx.Row) (accountState, error) {
	var s accountState
	err := row.Scan(&s.ID, &s.EmailNorm, &s.DisplayName, &s.Status, &s.PasswordHash, &s.PasswordSalt,
		&s.PasswordVersion, &s.PasswordSetAt, &s.Failures, &s.PausedUntil, &s.FrozenAt, &s.FreezeTriggerAt,
		&s.FrozenBy, &s.HasKeys)
	return s, err
}

// readAccount reads an account by id; forUpdate locks the row in tx.
func readAccount(ctx context.Context, q querier, userID uuid.UUID, forUpdate bool) (accountState, error) {
	sql := `SELECT ` + accountColumns + ` FROM users u WHERE u.id = $1`
	if forUpdate {
		sql += ` FOR UPDATE OF u`
	}
	s, err := scanAccount(q.QueryRow(ctx, sql, userID))
	if errors.Is(err, pgx.ErrNoRows) {
		return accountState{}, ErrNoSuchAccount
	}
	if err != nil {
		return accountState{}, fmt.Errorf("auth: read account: %w", err)
	}
	return s, nil
}

// accountByEmail reads an account by address, or ok = false.
func accountByEmail(ctx context.Context, q querier, emailNorm string) (accountState, bool, error) {
	s, err := scanAccount(q.QueryRow(ctx, `SELECT `+accountColumns+` FROM users u WHERE u.email_norm = $1`, emailNorm))
	if errors.Is(err, pgx.ErrNoRows) {
		return accountState{}, false, nil
	}
	if err != nil {
		return accountState{}, false, fmt.Errorf("auth: read account: %w", err)
	}
	return s, true, nil
}

// AccountStatus is the gate requireSession applies (spec 02 §9.6, §9.8).
type AccountStatus struct {
	Suspended bool
	Frozen    bool
	FrozenBy  string
}

// Status reads an account's suspension and freeze.
func (a *Accounts) Status(ctx context.Context, userID uuid.UUID) (AccountStatus, error) {
	var (
		status string
		frozen *time.Time
		by     *string
	)
	if err := a.Pool.QueryRow(ctx, `SELECT status, frozen_at, frozen_by FROM users WHERE id = $1`, userID).
		Scan(&status, &frozen, &by); err != nil {
		return AccountStatus{}, fmt.Errorf("auth: account status: %w", err)
	}
	out := AccountStatus{Suspended: status == "suspended", Frozen: frozen != nil}
	if by != nil {
		out.FrozenBy = *by
	}
	return out, nil
}

// normEmail applies email_norm, mapping a refusal to ErrBadEmail.
func normEmail(x string) (string, error) {
	n, err := keyproto.EmailNorm(x)
	if err != nil {
		return "", ErrBadEmail
	}
	return n, nil
}
