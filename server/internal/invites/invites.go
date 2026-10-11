// Package invites is the beta's invite state machine (spec 07 §2.5, §3.2,
// §4.4; spec 02 §14.1): codes and link keys, minting, the redeemability rule,
// revocation and the sweeps. It moved out of internal/auth (ledgerd's
// single-use code), which now calls RedeemTx inside the account transaction.
//
// # What a code proves
//
// A code is 120 bits from crypto/rand; possession lets an account be created.
// It never proves an address by itself: only the link key, which only the
// invite email carries (in the URL fragment), does, and only together with an
// address whose email_tag equals the invite's (Resolve). An addressed invite
// is redeemable only with its own address; any mismatch is the same "not
// invited" as an unknown code, so the answer says nothing about whom an
// invite was for.
package invites

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Sizes and defaults.
const (
	codeBytes    = 15 // 120 bits → 24 base32 characters, no padding
	CodeLen      = 24
	LinkKeyBytes = 32
	DefaultTTL   = 14 * 24 * time.Hour
	MinTTL       = 24 * time.Hour
	MaxTTL       = 30 * 24 * time.Hour
	MaxNote      = 200
)

// ErrNotInvited is the one distinguishable signup refusal (spec 02 §14.1):
// unknown, spent, expired, revoked, or addressed to someone else.
var ErrNotInvited = errors.New("invites: not a redeemable invite")

var alphabet = base32.StdEncoding.WithPadding(base32.NoPadding)

// Querier is the surface of a pool and a transaction this package uses.
type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// Normalize is the one definition of "the same code": upper case, separators
// (spaces, tabs, newlines, hyphens, underscores) dropped.
func Normalize(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	for _, r := range raw {
		switch r {
		case ' ', '\t', '\r', '\n', '-', '_':
			continue
		}
		b.WriteRune(r)
	}
	return strings.ToUpper(b.String())
}

// CodeHash is SHA-256(Normalize(code)), the only stored form; nil for an empty
// code, so "no code" never hashes to something a row could hold.
func CodeHash(code string) []byte {
	n := Normalize(code)
	if n == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(n))
	return sum[:]
}

// Display groups a code in fours: ABCD-EFGH-IJKL-MNOP-QRST-UVWX.
func Display(code string) string {
	n := Normalize(code)
	var parts []string
	for len(n) > 4 {
		parts = append(parts, n[:4])
		n = n[4:]
	}
	return strings.Join(append(parts, n), "-")
}

// NewCode returns a fresh code (24 characters of RFC 4648 base32).
func NewCode() (string, error) {
	raw := make([]byte, codeBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("invites: random: %w", err)
	}
	return alphabet.EncodeToString(raw), nil
}

// NewLinkKey returns 32 random bytes, their b64url form (43 characters, the
// URL fragment) and the stored SHA-256.
func NewLinkKey() (raw []byte, encoded string, hash []byte, err error) {
	raw = make([]byte, LinkKeyBytes)
	if _, err := rand.Read(raw); err != nil {
		return nil, "", nil, fmt.Errorf("invites: random: %w", err)
	}
	sum := sha256.Sum256(raw)
	return raw, base64.RawURLEncoding.EncodeToString(raw), sum[:], nil
}

// LinkKeyMatches compares SHA-256(raw) with a stored hash in constant time.
func LinkKeyMatches(raw, stored []byte) bool {
	if len(raw) != LinkKeyBytes || len(stored) != 32 {
		return false
	}
	sum := sha256.Sum256(raw)
	return subtle.ConstantTimeCompare(sum[:], stored) == 1
}

// Link is https://hasala.app/i/<CODE>#<LINK_KEY> on the given web base.
func Link(webBase, code, linkKey string) string {
	return strings.TrimSuffix(webBase, "/") + "/i/" + Normalize(code) + "#" + linkKey
}

// FallbackText is the email's typed form, hasala.app/i/<CODE with hyphens>.
func FallbackText(webBase, code string) string {
	host := strings.TrimPrefix(strings.TrimPrefix(webBase, "https://"), "http://")
	return strings.TrimSuffix(host, "/") + "/i/" + Display(code)
}

// CheckTTL bounds an invite's lifetime (invite_codes_ttl_is_bounded).
func CheckTTL(ttl time.Duration) error {
	if ttl < MinTTL || ttl > MaxTTL {
		return fmt.Errorf("invites: ttl %s is outside 24h–720h", ttl)
	}
	return nil
}

// CheckNote bounds an operator's note.
func CheckNote(note string) error {
	if len([]rune(note)) > MaxNote {
		return fmt.Errorf("invites: a note is at most %d characters", MaxNote)
	}
	return nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func pgInterval(d time.Duration) string { return fmt.Sprintf("%d seconds", int64(d/time.Second)) }

// MintPrinted creates an active, unaddressed CLI invite and returns its id and
// code, printed once (spec 07 §14.3: `invite mint [--review]`). A review
// invite marks the account it creates as a review account (spec 07 §2.5).
func MintPrinted(ctx context.Context, q Querier, note string, ttl time.Duration, review bool, now time.Time) (uuid.UUID, string, error) {
	if err := CheckTTL(ttl); err != nil {
		return uuid.Nil, "", err
	}
	if err := CheckNote(note); err != nil {
		return uuid.Nil, "", err
	}
	code, err := NewCode()
	if err != nil {
		return uuid.Nil, "", err
	}
	var id uuid.UUID
	err = q.QueryRow(ctx,
		`INSERT INTO invite_codes (code_hash, origin, review, state, note, ttl, created_at, minted_at, expires_at, mint_count)
		 VALUES ($1, 'cli', $2, 'active', $3, $4::interval, $5::timestamptz, $5::timestamptz, $5::timestamptz + $4::interval, 1)
		 RETURNING id`,
		CodeHash(code), review, nullable(note), pgInterval(ttl), now).Scan(&id)
	if err != nil {
		return uuid.Nil, "", fmt.Errorf("invites: mint: %w", err)
	}
	return id, code, nil
}

// Summary is one row of `invite list`.
type Summary struct {
	ID         uuid.UUID
	State      string
	Origin     string
	Review     bool
	Addressed  bool
	CreatedAt  time.Time
	ExpiresAt  *time.Time
	MintCount  int
	Redeemed   bool
	Note       string
	EntryID    *uuid.UUID
	RedeemedBy *uuid.UUID
}

// List returns every invite, newest first.
func List(ctx context.Context, q Querier) ([]Summary, error) {
	rows, err := q.Query(ctx,
		`SELECT id, state, origin, review, email_tag IS NOT NULL, created_at, expires_at, mint_count,
		        redeemed_at IS NOT NULL, coalesce(note, ''), waitlist_entry_id, redeemed_by
		   FROM invite_codes ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, fmt.Errorf("invites: list: %w", err)
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Summary, error) {
		var s Summary
		var mc int16
		err := r.Scan(&s.ID, &s.State, &s.Origin, &s.Review, &s.Addressed, &s.CreatedAt, &s.ExpiresAt, &mc,
			&s.Redeemed, &s.Note, &s.EntryID, &s.RedeemedBy)
		s.MintCount = int(mc)
		return s, err
	})
}

// ErrNoSuchInvite is a revoke whose prefix matches no open invite.
var ErrNoSuchInvite = errors.New("invites: no open invite matches")

// ErrAmbiguous is a prefix that matches more than one invite.
var ErrAmbiguous = errors.New("invites: the id prefix matches more than one invite")

// Revoke closes an open invite by id prefix (≥ 8 hex characters) and moves an
// invited entry back to confirmed (spec 07 §3.2, C10). It returns the id.
func Revoke(ctx context.Context, tx pgx.Tx, prefix string, now time.Time) (uuid.UUID, error) {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if len(prefix) < 8 || strings.Trim(prefix, "0123456789abcdef-") != "" {
		return uuid.Nil, fmt.Errorf("invites: an id prefix is at least 8 hex characters")
	}
	rows, err := tx.Query(ctx,
		`SELECT id FROM invite_codes WHERE id::text LIKE $1 || '%' AND state IN ('awaiting_testflight','queued','active')
		 FOR UPDATE`, prefix)
	if err != nil {
		return uuid.Nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return uuid.Nil, err
	}
	switch len(ids) {
	case 0:
		return uuid.Nil, ErrNoSuchInvite
	case 1:
	default:
		return uuid.Nil, ErrAmbiguous
	}
	var entry *uuid.UUID
	if err := tx.QueryRow(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = $2 WHERE id = $1 RETURNING waitlist_entry_id`,
		ids[0], now).Scan(&entry); err != nil {
		return uuid.Nil, err
	}
	if entry != nil {
		if _, err := tx.Exec(ctx,
			`UPDATE waitlist_entries SET state = 'confirmed', invited_at = NULL, updated_at = $2
			  WHERE id = $1 AND state = 'invited'`, *entry, now); err != nil {
			return uuid.Nil, err
		}
	}
	return ids[0], nil
}

// Resolution is what Resolve learned about a code at signup/begin.
type Resolution struct {
	InviteID uuid.UUID
	// Proven is true when the link key matched and the address is the one the
	// invite was mailed to: no signup code is needed (spec 07 §4.4).
	Proven bool
	Review bool
}

// Resolve applies spec 02 §14.1 / spec 07 §2.5 at signup/begin: the code must
// be redeemable; an addressed invite must be used with its own address
// (emailTag); the address is proven only by a matching link key. linkKey may be
// nil. Every refusal is ErrNotInvited.
func Resolve(ctx context.Context, q Querier, code string, linkKey, emailTag []byte, now time.Time) (Resolution, error) {
	h := CodeHash(code)
	if h == nil {
		return Resolution{}, ErrNotInvited
	}
	var (
		r        Resolution
		tag, lkh []byte
	)
	err := q.QueryRow(ctx,
		`SELECT id, email_tag, link_key_hash, review FROM invite_codes
		  WHERE code_hash = $1 AND state = 'active' AND expires_at > $2`, h, now).Scan(&r.InviteID, &tag, &lkh, &r.Review)
	if errors.Is(err, pgx.ErrNoRows) {
		return Resolution{}, ErrNotInvited
	}
	if err != nil {
		return Resolution{}, fmt.Errorf("invites: resolve: %w", err)
	}
	if tag != nil {
		if len(emailTag) != 32 || subtle.ConstantTimeCompare(tag, emailTag) != 1 {
			return Resolution{}, ErrNotInvited
		}
		r.Proven = linkKey != nil && LinkKeyMatches(linkKey, lkh)
	}
	return r, nil
}

// Redeemed is what RedeemTx spent.
type Redeemed struct {
	InviteID uuid.UUID
	EntryID  *uuid.UUID
	Review   bool
}

// RedeemTx spends the invite inside the account-creation transaction (spec 02
// §14.1): exactly one row moves active → redeemed, else ErrNotInvited and the
// caller rolls the whole account back. Two transactions presenting one code
// serialize on the row; the loser's predicate fails after the winner commits.
func RedeemTx(ctx context.Context, tx pgx.Tx, codeHash []byte, userID uuid.UUID, now time.Time) (Redeemed, error) {
	if len(codeHash) == 0 {
		return Redeemed{}, ErrNotInvited
	}
	var r Redeemed
	err := tx.QueryRow(ctx,
		`UPDATE invite_codes SET state = 'redeemed', redeemed_at = $1, redeemed_by = $2, closed_at = $1
		  WHERE code_hash = $3 AND state = 'active' AND expires_at > $1
		  RETURNING id, waitlist_entry_id, review`, now, userID, codeHash).Scan(&r.InviteID, &r.EntryID, &r.Review)
	if errors.Is(err, pgx.ErrNoRows) {
		return Redeemed{}, ErrNotInvited
	}
	if err != nil {
		return Redeemed{}, fmt.Errorf("invites: redeem: %w", err)
	}
	return r, nil
}

// Redeemable reports whether a code hash names a redeemable invite now (the
// passkey ceremony's early check; RedeemTx is the authority).
func Redeemable(ctx context.Context, q Querier, codeHash []byte, now time.Time) (bool, error) {
	if len(codeHash) == 0 {
		return false, nil
	}
	var ok bool
	err := q.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM invite_codes WHERE code_hash = $1 AND state = 'active' AND expires_at > $2)`,
		codeHash, now).Scan(&ok)
	return ok, err
}

// Sweep runs spec 07 §2.11's invite sweeps: expiry (an expired invite's entry
// goes back to confirmed), forget (30 days after closing, the tag, note and
// link key go) and delete. It reports what it did.
func Sweep(ctx context.Context, q Querier) (string, error) {
	tag, err := q.Exec(ctx, `
		WITH expired AS (
		  UPDATE invite_codes SET state = 'expired', closed_at = now()
		   WHERE state = 'active' AND expires_at <= now() RETURNING waitlist_entry_id)
		UPDATE waitlist_entries SET state = 'confirmed', invited_at = NULL, updated_at = now()
		 WHERE state = 'invited' AND id IN (SELECT waitlist_entry_id FROM expired WHERE waitlist_entry_id IS NOT NULL)`)
	if err != nil {
		return "", fmt.Errorf("invites: expiry sweep: %w", err)
	}
	back := tag.RowsAffected()
	forgot, err := q.Exec(ctx,
		`UPDATE invite_codes SET email_tag = NULL, note = NULL, link_key_hash = NULL
		  WHERE closed_at < now() - interval '30 days'
		    AND (email_tag IS NOT NULL OR note IS NOT NULL OR link_key_hash IS NOT NULL)`)
	if err != nil {
		return "", fmt.Errorf("invites: forget sweep: %w", err)
	}
	deleted, err := q.Exec(ctx,
		`DELETE FROM invite_codes WHERE closed_at < now() - interval '30 days'
		    AND (state IN ('expired','revoked') OR (state = 'redeemed' AND redeemed_by IS NULL))`)
	if err != nil {
		return "", fmt.Errorf("invites: delete sweep: %w", err)
	}
	if back+forgot.RowsAffected()+deleted.RowsAffected() == 0 {
		return "", nil
	}
	return fmt.Sprintf("%d entries back to the list, %d invites forgotten, %d deleted",
		back, forgot.RowsAffected(), deleted.RowsAffected()), nil
}
