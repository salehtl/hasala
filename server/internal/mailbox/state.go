package mailbox

// Single-use OAuth state rows: mailbox_oauth_states, the webauthn_ceremonies
// shape (00035_mailbox.sql's header names that precedent explicitly, and
// NOT writer_challenges — see internal/auth/writer.go's consumeChallenge,
// which marks a row `used_at` and keeps it, versus
// internal/auth/passkey_store.go's claimCeremony, which spends a row with
// `DELETE ... RETURNING`). Claim below mirrors claimCeremony: the delete IS
// the claim, and expiry is decided in Go against s.now() rather than in the
// WHERE clause against Postgres's own now() — one clock decides both when a
// state was minted and when it dies, and a claim that lands just past
// expiry still consumes the row (it was single-use and has now been used).

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	// StateTTL bounds how long a begun OAuth ceremony may be finished. Short,
	// like every other single-use ceremony row in this tree (writer
	// challenges, webauthn ceremonies): the legitimate path — a browser
	// popup completing Google's consent screen — takes at most a couple of
	// minutes, and every second beyond that only helps a captured state
	// token.
	StateTTL = 5 * time.Minute

	// stateTokenBytes is the entropy in a state token, before encoding — the
	// same 32 bytes (sessionTokenBytes) auth.Sessions.Issue uses for a
	// session bearer token, because this token plays an equivalent role: the
	// single secret that authorizes claiming one ceremony.
	stateTokenBytes = 32

	// pkceVerifierBytes is 32 random bytes, base64url-encoded to 43
	// characters — RFC 7636's minimum code_verifier length, and the
	// unreserved character set base64url already produces (no '+', '/' or
	// '=').
	pkceVerifierBytes = 32
)

// ErrStateUnknown covers every reason a state token does not currently name
// a live ceremony: it was never minted, it was already claimed, or it
// expired. All three collapse to one answer for the same reason
// ErrCeremonyUnknown does in internal/auth/passkey_store.go — which one it
// was is an oracle in a response and belongs in the operator log instead.
var ErrStateUnknown = errors.New("mailbox: oauth state unknown, used, or expired")

// States mints and consumes single-use OAuth ceremony rows.
//
// It holds no state beyond its dependencies, so constructing one per request
// is correct and free — the same reasoning auth.Writers' doc comment gives
// for itself.
type States struct {
	DB *pgxpool.Pool
	// Now defaults to time.Now. Expiry is evaluated against THIS clock and
	// never against Postgres's now(), on auth.Sessions' and auth.Writers'
	// precedent: one clock decides both when a state was minted and when it
	// dies, and a test can advance it to exercise TTL expiry without
	// sleeping five minutes.
	Now func() time.Time
}

func (s *States) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Begin mints a single-use OAuth state row for userID and returns the raw
// state token and PKCE verifier. Both are returned exactly once; only their
// derived forms (state's sha256, in state_hash; the verifier itself, stored
// in the clear per 00035_mailbox.sql's ruling — it must be replayed to
// Google at token-exchange, not merely compared against) ever reach the
// database.
func (s *States) Begin(ctx context.Context, userID uuid.UUID) (state, pkceVerifier string, err error) {
	if s.DB == nil {
		return "", "", errors.New("mailbox: States.DB is nil")
	}
	if userID == uuid.Nil {
		return "", "", errors.New("mailbox: begin oauth state: user id is zero")
	}
	stateRaw := make([]byte, stateTokenBytes)
	if _, err := rand.Read(stateRaw); err != nil {
		// Unreachable on Go 1.25 (crypto/rand panics rather than failing),
		// but a silently short token would be a weak CSRF state, so this is
		// checked rather than assumed.
		return "", "", fmt.Errorf("mailbox: begin oauth state: read random: %w", err)
	}
	verifierRaw := make([]byte, pkceVerifierBytes)
	if _, err := rand.Read(verifierRaw); err != nil {
		return "", "", fmt.Errorf("mailbox: begin oauth state: read random: %w", err)
	}
	state = base64.RawURLEncoding.EncodeToString(stateRaw)
	pkceVerifier = base64.RawURLEncoding.EncodeToString(verifierRaw)

	now := s.now()
	if _, err := s.DB.Exec(ctx,
		`INSERT INTO mailbox_oauth_states (state_hash, user_id, pkce_verifier, expires_at)
		 VALUES ($1, $2, $3, $4)`,
		stateHash(state), userID, pkceVerifier, now.Add(StateTTL)); err != nil {
		return "", "", fmt.Errorf("mailbox: begin oauth state for user %s: %w", userID, err)
	}
	return state, pkceVerifier, nil
}

// Claim consumes a state token: it is read and DELETED in one statement, so
// a replay of the same token finds nothing. See claimCeremony
// (internal/auth/passkey_store.go) for the full argument; this is that
// pattern applied to a different table.
func (s *States) Claim(ctx context.Context, state string) (userID uuid.UUID, pkceVerifier string, err error) {
	if s.DB == nil {
		return uuid.Nil, "", errors.New("mailbox: States.DB is nil")
	}
	if state == "" {
		return uuid.Nil, "", ErrStateUnknown
	}
	var expires time.Time
	err = s.DB.QueryRow(ctx,
		`DELETE FROM mailbox_oauth_states WHERE state_hash = $1
		 RETURNING user_id, pkce_verifier, expires_at`,
		stateHash(state)).Scan(&userID, &pkceVerifier, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		// Unknown or already spent — both are the same answer to the
		// caller; see ErrStateUnknown.
		return uuid.Nil, "", ErrStateUnknown
	}
	if err != nil {
		return uuid.Nil, "", fmt.Errorf("mailbox: claim oauth state: %w", err)
	}
	if !expires.After(s.now()) {
		// Claimed and found expired: the row stays deleted (it was
		// single-use and has now been used), and the caller is told the
		// same thing an unknown token would say, with the reason kept for
		// whoever reads the wrapped error rather than the caller.
		return uuid.Nil, "", fmt.Errorf("%w: state expired at %s", ErrStateUnknown, expires.UTC())
	}
	return userID, pkceVerifier, nil
}

// ReapExpired deletes state rows past their expiry and reports how many it
// removed.
//
// A row is spent by the callback that claims it, so what this removes is the
// ABANDONED ceremonies: a user who dismissed Google's consent screen, a popup
// that was closed, and anything a caller began for no reason at all. Begin is
// session-authenticated and rate limited, which bounds how fast rows appear;
// only this bounds how long they stay.
//
// It is called from cmd/ledgerd's sweep loop and NOT from Begin or Claim, on
// the same reasoning as auth.Passkeys.ReapExpiredCeremonies and
// auth.Sessions.ReapDeletedAccountTombstones: a sweep hung off a request path
// is a write that path's callers can trigger. The bound is s.now(), the clock
// Claim judges expiry against, so one clock decides both.
func (s *States) ReapExpired(ctx context.Context) (int64, error) {
	if s.DB == nil {
		return 0, errors.New("mailbox: States.DB is nil")
	}
	tag, err := s.DB.Exec(ctx, `DELETE FROM mailbox_oauth_states WHERE expires_at < $1`, s.now())
	if err != nil {
		return 0, fmt.Errorf("mailbox: reap expired oauth states: %w", err)
	}
	return tag.RowsAffected(), nil
}

func stateHash(state string) []byte {
	sum := sha256.Sum256([]byte(state))
	return sum[:]
}
