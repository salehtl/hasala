package auth

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

// newSessions is a store whose idle window and absolute cap are both ttl.
func newSessions(pool *pgxpool.Pool, ttl time.Duration, c *clock) *Sessions {
	return &Sessions{Pool: pool, TTL: ttl, Max: ttl, Now: c.now}
}

// newTestUser creates an account row (and its oplog_seq row) the way the
// fixtures of every package do.
func newTestUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	return oplogtest.NewUserWithoutKeys(t, pool)
}

// ---------------------------------------------------------------------------
// Session tokens
// ---------------------------------------------------------------------------

func TestSessionTokenIsNeverStoredInTheClear(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	if tok == "" {
		t.Fatal("issued an empty token")
	}

	var raw []byte
	if err := pool.QueryRow(bgctx, `SELECT token_hash FROM sessions`).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(tok)) {
		t.Fatal("the sessions table contains the bearer token itself")
	}
	want := sha256.Sum256([]byte(tok))
	if !bytes.Equal(raw, want[:]) {
		t.Fatalf("stored %x, want SHA-256 of the token %x", raw, want)
	}

	got, err := s.Resolve(bgctx, tok)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got != u {
		t.Fatalf("resolved to %s, want %s", got, u)
	}
}

// A session token is a bearer credential; it has to be unguessable. 32 bytes
// from crypto/rand is the requirement, and the encoding must not silently
// shrink that.
func TestIssuedTokensAreDistinctAnd32BytesOfEntropy(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	seen := map[string]bool{}
	for i := 0; i < 64; i++ {
		tok, err := s.Issue(bgctx, u)
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatalf("issued a duplicate token after %d draws", i)
		}
		seen[tok] = true
		raw, err := base64.RawURLEncoding.DecodeString(tok)
		if err != nil {
			t.Fatalf("token is not base64url: %v", err)
		}
		if len(raw) != sessionTokenBytes {
			t.Fatalf("token carries %d bytes of entropy, want %d", len(raw), sessionTokenBytes)
		}
	}
}

func TestExpiredSessionIsRejected(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Minute, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Resolve(bgctx, tok); err != nil {
		t.Fatalf("fresh session should resolve: %v", err)
	}

	c.advance(2 * time.Minute)
	_, err = s.Resolve(bgctx, tok)
	if !errors.Is(err, ErrSessionExpired) {
		t.Fatalf("resolve after expiry: %v, want ErrSessionExpired", err)
	}
	// Every rejection reason must also satisfy the general predicate, so a
	// caller can write one check and not accidentally admit a revoked or
	// expired session by matching only the unknown-token case.
	if !errors.Is(err, ErrSessionInvalid) || !errors.Is(ErrSessionIdle, ErrSessionInvalid) {
		t.Fatal("ErrSessionExpired and ErrSessionIdle must wrap ErrSessionInvalid")
	}
}

// Spec 02 §9.2: the idle window slides with use (at most one write per
// session-hour) up to the absolute cap, which nothing extends.
func TestSessionsSlideUpToTheirAbsoluteCap(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := &Sessions{Pool: pool, TTL: 30 * 24 * time.Hour, Max: 90 * 24 * time.Hour, Now: c.now}
	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	created := c.now()
	// Used every 20 days: it never idles out, until the 90-day cap.
	for i := 0; i < 4; i++ {
		c.advance(20 * 24 * time.Hour)
		info, err := s.Info(bgctx, tok)
		if err != nil {
			t.Fatalf("day %d: %v", 20*(i+1), err)
		}
		if !info.LastUsedAt.Equal(c.now()) {
			t.Fatalf("last_used_at did not move: %v", info.LastUsedAt)
		}
		if !info.ExpiresAt.Equal(created.Add(90 * 24 * time.Hour)) {
			t.Fatalf("the cap moved: %v", info.ExpiresAt)
		}
	}
	c.advance(11 * 24 * time.Hour) // day 91
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionExpired) {
		t.Fatalf("past the cap: %v, want ErrSessionExpired", err)
	}

	// One write per session-hour.
	tok2, _ := s.Issue(bgctx, u)
	i1, _ := s.Info(bgctx, tok2)
	c.advance(30 * time.Minute)
	i2, _ := s.Info(bgctx, tok2)
	if !i2.LastUsedAt.Equal(i1.LastUsedAt) {
		t.Fatal("a use within the hour moved last_used_at")
	}
	// Unused for 30 days: dead.
	c.advance(30 * 24 * time.Hour)
	if _, err := s.Resolve(bgctx, tok2); !errors.Is(err, ErrSessionIdle) {
		t.Fatalf("idle 30 days: %v, want ErrSessionIdle", err)
	}
}

// Every revocation says why (spec 02 §9.3): logout, writer, others.
func TestRevocationsRecordTheirReason(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)
	a, _ := s.Issue(bgctx, u)
	b, _ := s.Issue(bgctx, u)
	if err := s.Revoke(bgctx, a); err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeAllForUser(bgctx, u); err != nil {
		t.Fatal(err)
	}
	for tok, want := range map[string]string{a: "logout", b: "others"} {
		var got string
		if err := pool.QueryRow(bgctx, `SELECT revoked_reason FROM sessions WHERE token_hash = $1`, SessionHash(tok)).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("reason %q, want %q", got, want)
		}
	}
}

func TestRevokedSessionIsRejected(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(bgctx, tok); err != nil {
		t.Fatal(err)
	}
	_, err = s.Resolve(bgctx, tok)
	if !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("resolve after revoke: %v, want ErrSessionRevoked", err)
	}
	if !errors.Is(err, ErrSessionInvalid) {
		t.Fatal("ErrSessionRevoked must wrap ErrSessionInvalid")
	}

	// Revocation is permanent and idempotent: a second Revoke must not move
	// the recorded time, and must certainly not un-revoke.
	var first time.Time
	if err := pool.QueryRow(bgctx, `SELECT revoked_at FROM sessions`).Scan(&first); err != nil {
		t.Fatal(err)
	}
	c.advance(time.Minute)
	if err := s.Revoke(bgctx, tok); err != nil {
		t.Fatal(err)
	}
	var second time.Time
	if err := pool.QueryRow(bgctx, `SELECT revoked_at FROM sessions`).Scan(&second); err != nil {
		t.Fatal(err)
	}
	if !first.Equal(second) {
		t.Fatalf("second revoke moved revoked_at from %v to %v", first, second)
	}
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("still revoked check: %v", err)
	}
}

func TestResolveRejectsUnknownAndEmptyTokens(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)
	if _, err := s.Issue(bgctx, u); err != nil {
		t.Fatal(err)
	}

	for _, tok := range []string{"", "not-a-token", base64.RawURLEncoding.EncodeToString(make([]byte, 32))} {
		got, err := s.Resolve(bgctx, tok)
		if !errors.Is(err, ErrSessionInvalid) {
			t.Fatalf("resolve(%q) = %v, want ErrSessionInvalid", tok, err)
		}
		if got != uuid.Nil {
			t.Fatalf("a rejected token resolved to %s", got)
		}
	}
}

// "Sign out everywhere" and, later, the account-deletion path both need this.
// It must not touch another user's sessions.
func TestRevokeAllForUserRevokesOnlyThatUser(t *testing.T) {
	pool := pgtest.New(t)
	mine := newTestUser(t, pool)
	theirs := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	var myTokens []string
	for i := 0; i < 3; i++ {
		tok, err := s.Issue(bgctx, mine)
		if err != nil {
			t.Fatal(err)
		}
		myTokens = append(myTokens, tok)
	}
	theirToken, err := s.Issue(bgctx, theirs)
	if err != nil {
		t.Fatal(err)
	}

	if err := s.RevokeAllForUser(bgctx, mine); err != nil {
		t.Fatal(err)
	}
	for i, tok := range myTokens {
		if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionRevoked) {
			t.Fatalf("my token %d: %v, want ErrSessionRevoked", i, err)
		}
	}
	if got, err := s.Resolve(bgctx, theirToken); err != nil || got != theirs {
		t.Fatalf("another user's session was collateral damage: %s %v", got, err)
	}
}

func TestIssueRejectsAnUnusableConfiguration(t *testing.T) {
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()

	if _, err := (&Sessions{Pool: pool, TTL: 0, Now: c.now}).Issue(bgctx, u); err == nil {
		t.Fatal("a zero TTL must be rejected, not silently issue a dead session")
	}
	if _, err := (&Sessions{Pool: pool, TTL: -time.Hour, Now: c.now}).Issue(bgctx, u); err == nil {
		t.Fatal("a negative TTL must be rejected")
	}
	if _, err := newSessions(pool, time.Hour, c).Issue(bgctx, uuid.Nil); err == nil {
		t.Fatal("the zero user id must be rejected")
	}
}
