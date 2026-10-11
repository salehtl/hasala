package mailbox

// mailbox_grants: one row per (user, provider) holding the polling
// credential's digest and health. Read 00035_mailbox.sql's header before
// touching this file — it is the ruling this file implements, not merely a
// schema this file happens to use.

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
)

// ProviderGmail is the one value mailbox_grants.provider may hold today —
// the migration's CHECK constraint enforces the same closed set. Get,
// VerifyAndTouch, MarkReconnect and Delete are scoped by user_id alone
// (no provider argument): UNIQUE(user_id, provider) together with there
// being exactly one provider means "the grant for this user" is
// unambiguous today. Upsert still takes provider explicitly, so admitting a
// second provider later is a call-site change, not a signature change.
const ProviderGmail = "gmail"

// Grant status vocabulary, matching mailbox_grants.status's CHECK
// constraint.
const (
	// GrantStatusActive is the ordinary state: the broker believes the
	// stored digest corresponds to a live refresh token.
	GrantStatusActive = "active"
	// GrantStatusReconnectRequired means Google told the broker the refresh
	// token is dead (D10: a Testing-status token past its 7-day expiry, or
	// an explicit revocation at Google). The row is kept rather than
	// deleted — MarkReconnect — so the sender allowlist survives a
	// reconnect.
	GrantStatusReconnectRequired = "reconnect_required"
)

// ErrGrantMismatch is VerifyAndTouch's one answer for every mismatch shape:
// no grant exists for the calling user, or one exists and its digest does
// not match. See VerifyAndTouch's doc for why the two are never told apart.
var ErrGrantMismatch = errors.New("mailbox: grant verification failed")

// TokenHash is sha256(refreshToken) — the sessions.token_hash discipline
// (internal/auth/session.go's tokenHash) applied to a Google refresh token.
// It is the only representation of a grant's credential this package ever
// persists; see the package doc's D3 section.
func TokenHash(refreshToken string) []byte {
	sum := sha256.Sum256([]byte(refreshToken))
	return sum[:]
}

// Grant is one user's mailbox_grants row, with the digest deliberately
// excluded: nothing outside VerifyAndTouch's own query ever reads
// refresh_token_hash back out of the database.
type Grant struct {
	Provider  string
	Status    string
	CreatedAt time.Time
	// LastBrokerAt is nil until VerifyAndTouch succeeds for the first time.
	LastBrokerAt *time.Time
}

// Grants owns mailbox_grants: the polling credential's digest and its
// health, per user.
type Grants struct {
	DB *pgxpool.Pool
}

// Upsert records userID's holdership of provider with refreshTokenHash. An
// existing row's digest and status flip to the new values in the SAME
// statement — D9's holdership rotation — so there is no window in which
// both an old and a new digest verify: the moment this commits, the
// superseded device's stored digest stops matching, and its next broker
// call fails closed (TestSupersededTokenDigestFailsClosed).
func (s *Grants) Upsert(ctx context.Context, userID uuid.UUID, provider string, refreshTokenHash []byte) error {
	if s.DB == nil {
		return errors.New("mailbox: Grants.DB is nil")
	}
	if userID == uuid.Nil {
		return errors.New("mailbox: upsert grant: user id is zero")
	}
	if len(refreshTokenHash) == 0 {
		return errors.New("mailbox: upsert grant: refresh token hash is empty")
	}
	if _, err := s.DB.Exec(ctx,
		`INSERT INTO mailbox_grants (user_id, provider, status, refresh_token_hash, created_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (user_id, provider) DO UPDATE
		   SET refresh_token_hash = EXCLUDED.refresh_token_hash,
		       status = $3`,
		userID, provider, GrantStatusActive, refreshTokenHash, time.Now()); err != nil {
		return fmt.Errorf("mailbox: upsert grant for user %s: %w", userID, err)
	}
	return nil
}

// Get returns userID's mailbox grant, or (nil, nil) when none exists —
// "not connected" is not an error.
func (s *Grants) Get(ctx context.Context, userID uuid.UUID) (*Grant, error) {
	if s.DB == nil {
		return nil, errors.New("mailbox: Grants.DB is nil")
	}
	var g Grant
	err := s.DB.QueryRow(ctx,
		`SELECT provider, status, created_at, last_broker_at FROM mailbox_grants WHERE user_id = $1`,
		userID).Scan(&g.Provider, &g.Status, &g.CreatedAt, &g.LastBrokerAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("mailbox: get grant for user %s: %w", userID, err)
	}
	return &g, nil
}

// VerifyAndTouch checks that userID currently holds a grant whose stored
// digest equals refreshTokenHash, and records the success as
// last_broker_at. It is the one check both /api/v1/mailbox/token and
// /api/v1/mailbox/revoke (Task 4) run before doing anything with a refresh
// token a caller presented.
//
// Every mismatch — no grant row for this user, or a grant whose digest does
// not equal refreshTokenHash — returns the identical ErrGrantMismatch.
// Distinguishing "wrong digest" from "no such user's grant" in a response
// would be D3a's oracle: any authenticated session could learn whether
// another account has a live grant at all, or narrow down which digest is
// current, by watching which error came back. Task 4 collapses this one
// error to one generic HTTP refusal, byte-identical regardless of which
// case it was.
func (s *Grants) VerifyAndTouch(ctx context.Context, userID uuid.UUID, refreshTokenHash []byte) error {
	if s.DB == nil {
		return errors.New("mailbox: Grants.DB is nil")
	}
	if userID == uuid.Nil || len(refreshTokenHash) == 0 {
		return ErrGrantMismatch
	}
	var stored []byte
	err := s.DB.QueryRow(ctx,
		`SELECT refresh_token_hash FROM mailbox_grants WHERE user_id = $1`, userID).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrGrantMismatch
	}
	if err != nil {
		return fmt.Errorf("mailbox: verify grant for user %s: %w", userID, err)
	}
	// subtle.ConstantTimeCompare is a structural guard, not what makes this
	// safe — the value being compared is a preimage-resistant digest, on
	// the same reasoning auth.Sessions.Resolve gives for its own compare.
	// See TestSupersededTokenDigestFailsClosed and
	// TestVerifyAndTouchRejectsWrongDigest (Step 4's mutation proof inverts
	// this comparison and watches both fail) for why this line is
	// load-bearing regardless of the timing argument.
	if subtle.ConstantTimeCompare(stored, refreshTokenHash) != 1 {
		return ErrGrantMismatch
	}
	if _, err := s.DB.Exec(ctx,
		`UPDATE mailbox_grants SET last_broker_at = $2 WHERE user_id = $1`,
		userID, time.Now()); err != nil {
		return fmt.Errorf("mailbox: touch grant for user %s: %w", userID, err)
	}
	return nil
}

// MarkReconnect flips userID's grant to reconnect_required. The row is kept
// rather than deleted: mailbox_senders' allowlist should not be lost just
// because the token needs refreshing through Google's consent screen again
// (00035_mailbox.sql's header states the same reasoning).
func (s *Grants) MarkReconnect(ctx context.Context, userID uuid.UUID) error {
	if s.DB == nil {
		return errors.New("mailbox: Grants.DB is nil")
	}
	if _, err := s.DB.Exec(ctx,
		`UPDATE mailbox_grants SET status = $2 WHERE user_id = $1`,
		userID, GrantStatusReconnectRequired); err != nil {
		return fmt.Errorf("mailbox: mark reconnect for user %s: %w", userID, err)
	}
	return nil
}

// Delete disconnects userID's mailbox: it removes the grant row AND sweeps
// that account's mailbox_senders allowlist, in one transaction. The revoke
// route calls this after Google.Revoke, and DELETE /api/v1/mailbox/grant calls
// it on its own; account purge reaches both tables through users ON DELETE
// CASCADE and needs no call here at all.
//
// # Why the allowlist goes with the grant, and why MarkReconnect keeps it
//
// mailbox_senders is the list of domains this user's banks mail them from. It
// is real mail metadata — which institutions this person banks with — so a
// user who has disconnected their mailbox has asked for it to stop being on
// this server, and leaving it behind would be a retention nobody consented to.
//
// That is NOT a contradiction of 00035_mailbox.sql's header, which says the
// list must survive the reconnect_required flip: those are two different
// events. A token going stale (D10's seven-day Testing-status expiry, or a
// revocation at Google) happens to an account that is still connected, and
// making the user re-type their banks over it would be gratuitous —
// MarkReconnect therefore still touches nothing but `status`, and
// TestMarkReconnectKeepsTheSenderAllowlist holds it to that. A DISCONNECT is
// the user ending the connection. Only the second sweeps.
//
// # Why here rather than in the HTTP handlers
//
// Both disconnect routes already funnel through this one method, so the sweep
// living here means neither can forget it and a third caller cannot be added
// that does. One transaction is also the only shape that cannot be left half
// done: two client-issued requests would let a tab closed in between strand a
// grantless account still holding its bank list, with no UI left that could
// clear it.
func (s *Grants) Delete(ctx context.Context, userID uuid.UUID) error {
	if s.DB == nil {
		return errors.New("mailbox: Grants.DB is nil")
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.DB)
	if err != nil {
		return fmt.Errorf("mailbox: delete grant for user %s: begin: %w", userID, err)
	}
	defer pgtx.Rollback(ctx, tx)

	// The senders sweep runs even when there is no grant row left to delete:
	// another device may have disconnected first, and the list must still be
	// clearable rather than stranded. Both statements are scoped to the one
	// account — a sweep that lost its WHERE would take every user's list.
	if _, err := tx.Exec(ctx, `DELETE FROM mailbox_senders WHERE user_id = $1`, userID); err != nil {
		return fmt.Errorf("mailbox: delete sender allowlist for user %s: %w", userID, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM mailbox_grants WHERE user_id = $1`, userID); err != nil {
		return fmt.Errorf("mailbox: delete grant for user %s: %w", userID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("mailbox: delete grant for user %s: commit: %w", userID, err)
	}
	return nil
}
