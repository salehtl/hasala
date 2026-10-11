package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// sessionTokenBytes is the entropy in a session token, before encoding.
const sessionTokenBytes = 32

// DefaultSessionMax is the absolute cap of spec 02 §9.2 (PO-15: 90 days),
// used when Sessions.Max is not set.
const DefaultSessionMax = 2160 * time.Hour

// touchGranularity bounds last_used_at writes to one per session-hour.
const touchGranularity = time.Hour

// Who minted a session (spec 02 §9.1: sessions.minted_by).
const (
	MintedRegister       = "register"
	MintedLogin          = "login"
	MintedRecover        = "recover"
	MintedPasswordSignup = "password_signup"
	MintedPasswordLogin  = "password_login"
	MintedPasswordReset  = "password_reset"
)

// Why a session ended (spec 02 §9.3: sessions.revoked_reason).
const (
	RevokedLogout = "logout"
	RevokedWriter = "writer"
	RevokedOthers = "others"
)

// Session rejection reasons. All of them wrap ErrSessionInvalid; the HTTP
// layer answers the same 401 for every one of them except
// ErrSessionAccountDeleted (410, the only wipe signal).
var (
	ErrSessionInvalid        = errors.New("auth: session token is not valid")
	ErrSessionUnknown        = fmt.Errorf("%w: no such session", ErrSessionInvalid)
	ErrSessionExpired        = fmt.Errorf("%w: session expired", ErrSessionInvalid)
	ErrSessionIdle           = fmt.Errorf("%w: session idle too long", ErrSessionInvalid)
	ErrSessionRevoked        = fmt.Errorf("%w: session revoked", ErrSessionInvalid)
	ErrSessionAccountDeleted = fmt.Errorf("%w: the account this session belonged to was deleted", ErrSessionInvalid)
)

// Sessions issues and resolves opaque server-side session tokens (spec 02 §9).
// A live session is a weak capability: it authorizes reading and appending,
// never an authenticator, key or mailbox change on its own (§8).
type Sessions struct {
	Pool *pgxpool.Pool
	// TTL is the sliding idle window (auth.session_idle, 30 days): a session
	// unused for this long is dead. It must be positive.
	TTL time.Duration
	// Max is the absolute cap from creation (auth.session_max, 90 days);
	// zero is DefaultSessionMax, and it is never shorter than TTL.
	Max time.Duration
	// Now defaults to time.Now. Liveness is evaluated against this clock, never
	// Postgres's now(), so one clock decides both minting and expiry.
	Now func() time.Time
}

func (s *Sessions) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Sessions) max() time.Duration {
	m := s.Max
	if m <= 0 {
		m = DefaultSessionMax
	}
	if m < s.TTL {
		m = s.TTL
	}
	return m
}

// tokenHash is the only representation of a session token ever persisted.
func tokenHash(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

// SessionHash is tokenHash, for the API layer's rows that name a session
// (APNs tokens) without holding a usable credential.
func SessionHash(token string) []byte { return tokenHash(token) }

// forgetPushTokens deletes the APNs tokens a revocation must silence, inside
// the caller's transaction (spec 02 §9.3, F4). `where` names columns of
// apns_tokens.
func forgetPushTokens(ctx context.Context, tx pgx.Tx, where string, args ...any) error {
	if _, err := tx.Exec(ctx, `DELETE FROM apns_tokens WHERE `+where, args...); err != nil {
		return fmt.Errorf("auth: forget push tokens: %w", err)
	}
	return nil
}

// Mint describes a session a ceremony issues.
type Mint struct {
	UserID       uuid.UUID
	MintedBy     string
	CredentialID []byte // the passkey that finished the ceremony, or nil
	WriterID     string // the writer the session is bound to, or ""
	Restricted   bool   // minted while the account is frozen (spec 02 §9.8)
}

// Minted is an issued session: the bearer token, returned exactly once.
type Minted struct {
	Token     string
	ExpiresAt time.Time // the absolute cap
}

type queryExecer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// IssueTx mints a session inside q (a pool or the ceremony's transaction).
func (s *Sessions) IssueTx(ctx context.Context, q queryExecer, m Mint) (Minted, error) {
	if m.UserID == uuid.Nil {
		return Minted{}, errors.New("auth: issue session: user id is zero")
	}
	if s.TTL <= 0 {
		return Minted{}, fmt.Errorf("auth: issue session: idle window is %v, want a positive duration", s.TTL)
	}
	switch m.MintedBy {
	case MintedRegister, MintedLogin, MintedRecover, MintedPasswordSignup, MintedPasswordLogin, MintedPasswordReset:
	default:
		return Minted{}, fmt.Errorf("auth: issue session: minted_by %q", m.MintedBy)
	}
	raw := make([]byte, sessionTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return Minted{}, fmt.Errorf("auth: issue session: read random: %w", err)
	}
	// RawURLEncoding: it travels only in an Authorization header, never a URL.
	// It is hashed in its encoded form, the form that arrives on the wire.
	token := base64.RawURLEncoding.EncodeToString(raw)
	now := s.now()
	var cred, writer any
	if len(m.CredentialID) > 0 {
		cred = m.CredentialID
	}
	if m.WriterID != "" {
		writer = m.WriterID
	}
	exp := now.Add(s.max())
	if _, err := q.Exec(ctx,
		`INSERT INTO sessions (token_hash, user_id, minted_by, credential_id, writer_id, restricted,
		   created_at, last_used_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $8)`,
		tokenHash(token), m.UserID, m.MintedBy, cred, writer, m.Restricted, now, exp); err != nil {
		return Minted{}, fmt.Errorf("auth: issue session for user %s: %w", m.UserID, err)
	}
	return Minted{Token: token, ExpiresAt: exp}, nil
}

// Issue mints an unattributed, unbound login session. Tests use it.
func (s *Sessions) Issue(ctx context.Context, userID uuid.UUID) (string, error) {
	return s.IssueForCredential(ctx, userID, nil)
}

// IssueForCredential mints an unbound login session attributed to a passkey.
// Production ceremonies call IssueTx inside their own transaction; this is the
// pool-level shortcut tests and fixtures use.
func (s *Sessions) IssueForCredential(ctx context.Context, userID uuid.UUID, credentialID []byte) (string, error) {
	if s.Pool == nil {
		return "", errors.New("auth: Sessions.Pool is nil")
	}
	m, err := s.IssueTx(ctx, s.Pool, Mint{UserID: userID, MintedBy: MintedLogin, CredentialID: credentialID})
	return m.Token, err
}

// SessionInfo is the calling session, as a route needs it.
type SessionInfo struct {
	UserID       uuid.UUID
	Hash         []byte
	WriterID     string // "" when unbound (spec 02 §9.4)
	CredentialID []byte
	MintedBy     string
	Restricted   bool
	CreatedAt    time.Time
	LastUsedAt   time.Time
	ExpiresAt    time.Time // the absolute cap
	IdleExpires  time.Time // min(ExpiresAt, LastUsedAt + idle)
}

// CredentialForSession returns the credential that minted token's session, or
// nil. It does not judge liveness; its caller resolved the session already.
func (s *Sessions) CredentialForSession(ctx context.Context, token string) ([]byte, error) {
	if token == "" {
		return nil, nil
	}
	var cred []byte
	err := s.Pool.QueryRow(ctx, `SELECT credential_id FROM sessions WHERE token_hash = $1`, tokenHash(token)).Scan(&cred)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("auth: credential for session: %w", err)
	}
	return cred, nil
}

// Resolve returns the account of a live session, or an error wrapping
// ErrSessionInvalid.
func (s *Sessions) Resolve(ctx context.Context, token string) (uuid.UUID, error) {
	i, err := s.Info(ctx, token)
	return i.UserID, err
}

// Info resolves token and answers the whole session. A session is live iff it
// is not revoked, now < expires_at and now < last_used_at + idle (spec 02
// §9.2). A successful resolve moves last_used_at forward at most once an hour.
//
// The lookup is by primary key on SHA-256(token); what makes it safe is the
// hashing, and the constant-time compare below only pins that structure.
func (s *Sessions) Info(ctx context.Context, token string) (SessionInfo, error) {
	if s.Pool == nil {
		return SessionInfo{}, errors.New("auth: Sessions.Pool is nil")
	}
	if token == "" {
		return SessionInfo{}, ErrSessionUnknown
	}
	want := tokenHash(token)
	var (
		i       SessionInfo
		stored  []byte
		writer  *string
		revoked *time.Time
	)
	err := s.Pool.QueryRow(ctx,
		`SELECT token_hash, user_id, writer_id, credential_id, minted_by, restricted, created_at, last_used_at,
		        expires_at, revoked_at
		   FROM sessions WHERE token_hash = $1`, want).
		Scan(&stored, &i.UserID, &writer, &i.CredentialID, &i.MintedBy, &i.Restricted, &i.CreatedAt,
			&i.LastUsedAt, &i.ExpiresAt, &revoked)
	if errors.Is(err, pgx.ErrNoRows) {
		return SessionInfo{}, s.deletedOrUnknown(ctx, want)
	}
	if err != nil {
		return SessionInfo{}, fmt.Errorf("auth: resolve session: %w", err)
	}
	if subtle.ConstantTimeCompare(stored, want) != 1 {
		return SessionInfo{}, ErrSessionUnknown
	}
	now := s.now()
	if revoked != nil {
		return SessionInfo{}, ErrSessionRevoked
	}
	if !i.ExpiresAt.After(now) {
		return SessionInfo{}, ErrSessionExpired
	}
	if !i.LastUsedAt.Add(s.TTL).After(now) {
		return SessionInfo{}, ErrSessionIdle
	}
	if writer != nil {
		i.WriterID = *writer
	}
	i.Hash = want
	if now.Sub(i.LastUsedAt) >= touchGranularity {
		if _, err := s.Pool.Exec(ctx,
			`UPDATE sessions SET last_used_at = $2 WHERE token_hash = $1 AND last_used_at < $3`,
			want, now, now.Add(-touchGranularity)); err != nil {
			return SessionInfo{}, fmt.Errorf("auth: touch session: %w", err)
		}
		i.LastUsedAt = now
	}
	i.IdleExpires = i.LastUsedAt.Add(s.TTL)
	if i.ExpiresAt.Before(i.IdleExpires) {
		i.IdleExpires = i.ExpiresAt
	}
	return i, nil
}

// deletedOrUnknown answers whether an unrecognized token belonged to an
// account that was deleted (the tombstone of 00001's BEFORE DELETE trigger).
// A tombstone past its session's own expiry answers nothing.
func (s *Sessions) deletedOrUnknown(ctx context.Context, tokenHash []byte) error {
	var expires time.Time
	err := s.Pool.QueryRow(ctx,
		`SELECT expires_at FROM deleted_account_sessions WHERE token_hash = $1`, tokenHash).Scan(&expires)
	if err != nil || !expires.After(s.now()) {
		return ErrSessionUnknown
	}
	return ErrSessionAccountDeleted
}

// tombstoneGrace bounds the deleted-account tombstone table past expiry.
const tombstoneGrace = 30 * 24 * time.Hour

// ReapDeletedAccountTombstones deletes tombstones whose sessions expired more
// than tombstoneGrace ago, on this package's clock.
func (s *Sessions) ReapDeletedAccountTombstones(ctx context.Context) (int64, error) {
	if s.Pool == nil {
		return 0, errors.New("auth: Sessions.Pool is nil")
	}
	tag, err := s.Pool.Exec(ctx, `DELETE FROM deleted_account_sessions WHERE expires_at < $1`, s.now().Add(-tombstoneGrace))
	if err != nil {
		return 0, fmt.Errorf("auth: reap deleted-account tombstones: %w", err)
	}
	return tag.RowsAffected(), nil
}

// Revoke is logout (#15): this session revoked with reason 'logout' and its
// APNs token deleted, in one transaction. Idempotent.
func (s *Sessions) Revoke(ctx context.Context, token string) error {
	if s.Pool == nil {
		return errors.New("auth: Sessions.Pool is nil")
	}
	if token == "" {
		return nil
	}
	hash := tokenHash(token)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("auth: revoke session: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $2, revoked_reason = 'logout' WHERE token_hash = $1 AND revoked_at IS NULL`,
		hash, s.now()); err != nil {
		return fmt.Errorf("auth: revoke session: %w", err)
	}
	if err := forgetPushTokens(ctx, tx, `session_hash = $1`, hash); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("auth: revoke session: commit: %w", err)
	}
	return nil
}

// RevokeAllForUser revokes every session of the account ('others') and
// deletes every APNs token, in one transaction.
func (s *Sessions) RevokeAllForUser(ctx context.Context, userID uuid.UUID) error {
	if s.Pool == nil {
		return errors.New("auth: Sessions.Pool is nil")
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return fmt.Errorf("auth: revoke all sessions: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if _, err := RevokeOtherSessionsTx(ctx, tx, userID, nil, s.now()); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// RevokeOtherSessionsTx is spec 02 §9.3's RevokeOtherSessions: every live
// session of the account except keep is revoked with reason 'others', and
// their APNs tokens deleted, inside the action's transaction. Writers, keys
// and wraps are untouched. It answers the deleted tokens, so the caller can
// wake those devices once its transaction commits (§12.5: "for every revoked
// session, its token collected before deletion").
func RevokeOtherSessionsTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, keep [][]byte, now time.Time) ([]pushv2.Target, error) {
	if keep == nil {
		keep = [][]byte{}
	}
	rows, err := tx.Query(ctx,
		`DELETE FROM apns_tokens
		  WHERE user_id = $1 AND session_hash IN (SELECT token_hash FROM sessions
		    WHERE user_id = $1 AND revoked_at IS NULL AND NOT (token_hash = ANY($2::bytea[])))
		 RETURNING token_hex, environment`, userID, keep)
	if err != nil {
		return nil, fmt.Errorf("auth: forget push tokens: %w", err)
	}
	revoked, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (pushv2.Target, error) {
		var t pushv2.Target
		err := r.Scan(&t.TokenHex, &t.Environment)
		return t, err
	})
	if err != nil {
		return nil, fmt.Errorf("auth: forget push tokens: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $3, revoked_reason = 'others'
		  WHERE user_id = $1 AND revoked_at IS NULL AND NOT (token_hash = ANY($2::bytea[]))`, userID, keep, now); err != nil {
		return nil, fmt.Errorf("auth: revoke other sessions: %w", err)
	}
	return revoked, nil
}

// ErrSessionBound means a bind was asked of a session that is already bound
// (409 session_bound): a bound session is never re-bound.
var ErrSessionBound = errors.New("auth: the session is already bound to a writer")

// bindSessionTx binds an unbound, live session of userID to writerID inside
// the caller's transaction (bootstrap and writer registration, spec 02 §9.4).
func bindSessionTx(ctx context.Context, tx pgx.Tx, sessionHash []byte, userID uuid.UUID, writerID string) error {
	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET writer_id = $3
		  WHERE token_hash = $1 AND user_id = $2 AND writer_id IS NULL AND revoked_at IS NULL`,
		sessionHash, userID, writerID)
	if err != nil {
		return fmt.Errorf("auth: bind session: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return ErrSessionBound
	}
	return nil
}

// ReapSessions is spec 02 §9.7's sessions sweep.
func (s *Sessions) ReapSessions(ctx context.Context) (int64, error) {
	now := s.now()
	tag, err := s.Pool.Exec(ctx,
		`DELETE FROM sessions WHERE revoked_at < $1 OR expires_at < $1 OR last_used_at < $2`,
		now.Add(-30*24*time.Hour), now.Add(-s.TTL-30*24*time.Hour))
	if err != nil {
		return 0, fmt.Errorf("auth: reap sessions: %w", err)
	}
	return tag.RowsAffected(), nil
}
