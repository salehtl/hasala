package auth

// Invites (spec 07 §2.5, §4.4; spec 02 §14.1). Spec 07 owns minting, sending,
// states and the console; this file owns redemption inside account creation,
// the join hook it calls, and the CLI's printed codes (`invite mint
// [--review]`) until WS-19's invite work replaces them.
//
// A code is 15 random bytes as 24 unpadded base32 characters, stored only as
// SHA-256 of its normalized form. An invite the worker emails carries an
// address (email_tag) and a 32-byte link key (stored as its SHA-256), which
// travel in https://hasala.app/i/<CODE>#<LINK_KEY>: the fragment never reaches
// a server, so only the email proves the address.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ErrNotInvited is the one distinguishable signup answer (403 not_invited):
// an unknown, spent, revoked or expired code, or an addressed invite used with
// another address.
var ErrNotInvited = errors.New("auth: account creation needs a redeemable invite")

const inviteCodeBytes = 15

var inviteAlphabet = base32.StdEncoding.WithPadding(base32.NoPadding)

// NormalizeInviteCode strips spaces, tabs, line breaks, hyphens and
// underscores and uppercases the rest, so a code read aloud, pasted with its
// display hyphens or typed in lowercase still matches.
func NormalizeInviteCode(raw string) string {
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

// InviteCodeHash is SHA-256(NormalizeInviteCode(code)), or nil for a code that
// normalizes to nothing.
func InviteCodeHash(code string) []byte {
	n := NormalizeInviteCode(code)
	if n == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(n))
	return sum[:]
}

// MintOptions describes a printed CLI invite (spec 07 §3.2: `invite mint`).
type MintOptions struct {
	Note   string
	TTL    time.Duration // 1–30 days; zero is 14 days
	Review bool          // a Beta App Review invite (spec 02 §14.2): unaddressed, never emailed
	// EmailTag and LinkKey make an addressed invite (the shape 07's worker
	// mints for an emailed invite). LinkKey needs EmailTag; neither goes with
	// Review.
	EmailTag []byte
	LinkKey  []byte
	Now      time.Time
}

// MintInvite mints one active invite and returns its code, shown once.
func MintInvite(ctx context.Context, q queryExecer, o MintOptions) (string, error) {
	raw := make([]byte, inviteCodeBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("auth: MintInvite: read random: %w", err)
	}
	code := inviteAlphabet.EncodeToString(raw)
	ttl := o.TTL
	if ttl == 0 {
		ttl = 14 * 24 * time.Hour
	}
	now := o.Now
	if now.IsZero() {
		now = time.Now()
	}
	var note, tag, link any
	if o.Note != "" {
		note = o.Note
	}
	if len(o.EmailTag) > 0 {
		tag = o.EmailTag
	}
	if len(o.LinkKey) > 0 {
		h := sha256.Sum256(o.LinkKey)
		link = h[:]
	}
	if _, err := q.Exec(ctx,
		`INSERT INTO invite_codes (code_hash, link_key_hash, email_tag, origin, review, state, note, ttl,
		   created_at, minted_at, expires_at, mint_count)
		 VALUES ($1, $2, $3, 'cli', $4, 'active', $5, $6, $7, $7, $8, 1)`,
		InviteCodeHash(code), link, tag, o.Review, note, ttl, now, now.Add(ttl)); err != nil {
		return "", fmt.Errorf("auth: MintInvite: %w", err)
	}
	return code, nil
}

// InviteSummary is one row of `hasalad invite list`. It never carries a code.
type InviteSummary struct {
	ID         uuid.UUID
	State      string
	Review     bool
	Addressed  bool
	Note       string
	CreatedAt  time.Time
	ExpiresAt  *time.Time
	RedeemedAt *time.Time
	RedeemedBy *uuid.UUID
}

// ListInvites lists every invite, newest first.
func ListInvites(ctx context.Context, q interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}) ([]InviteSummary, error) {
	rows, err := q.Query(ctx,
		`SELECT id, state, review, email_tag IS NOT NULL, coalesce(note, ''), created_at, expires_at, redeemed_at, redeemed_by
		   FROM invite_codes ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, fmt.Errorf("auth: ListInvites: %w", err)
	}
	defer rows.Close()
	var out []InviteSummary
	for rows.Next() {
		var s InviteSummary
		if err := rows.Scan(&s.ID, &s.State, &s.Review, &s.Addressed, &s.Note, &s.CreatedAt, &s.ExpiresAt,
			&s.RedeemedAt, &s.RedeemedBy); err != nil {
			return nil, fmt.Errorf("auth: ListInvites: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// invite is what signup reads about a redeemable invite.
type invite struct {
	ID          uuid.UUID
	EmailTag    []byte
	LinkKeyHash []byte
	Review      bool
}

// redeemableInvite reads the invite a code names if it is redeemable now
// (state = 'active' AND expires_at > now).
func redeemableInvite(ctx context.Context, q querier, codeHash []byte, now time.Time) (invite, error) {
	if len(codeHash) == 0 {
		return invite{}, ErrNotInvited
	}
	var inv invite
	err := q.QueryRow(ctx,
		`SELECT id, email_tag, link_key_hash, review FROM invite_codes
		  WHERE code_hash = $1 AND state = 'active' AND expires_at > $2`, codeHash, now).
		Scan(&inv.ID, &inv.EmailTag, &inv.LinkKeyHash, &inv.Review)
	if errors.Is(err, pgx.ErrNoRows) {
		return invite{}, ErrNotInvited
	}
	if err != nil {
		return invite{}, fmt.Errorf("auth: read invite: %w", err)
	}
	return inv, nil
}

// redeemInviteTx spends the invite inside the account-creation transaction
// (spec 02 §14.1): exactly one active, unexpired row, still bound to this
// address when it is addressed, or ErrNotInvited and the transaction fails.
func redeemInviteTx(ctx context.Context, tx pgx.Tx, codeHash, emailTag []byte, userID uuid.UUID, now time.Time) (invite, error) {
	var inv invite
	err := tx.QueryRow(ctx,
		`UPDATE invite_codes SET state = 'redeemed', redeemed_at = $2, redeemed_by = $3, closed_at = $2
		  WHERE code_hash = $1 AND state = 'active' AND expires_at > $2
		    AND (email_tag IS NULL OR email_tag = $4)
		 RETURNING id, email_tag, link_key_hash, review`, codeHash, now, userID, emailTag).
		Scan(&inv.ID, &inv.EmailTag, &inv.LinkKeyHash, &inv.Review)
	if errors.Is(err, pgx.ErrNoRows) {
		return invite{}, ErrNotInvited
	}
	if err != nil {
		return invite{}, fmt.Errorf("auth: redeem invite: %w", err)
	}
	return inv, nil
}

// onInviteRedeemedTx is spec 07 §3.1's join hook, in the account-creation
// transaction: the entry linked to the invite, and every other entry with the
// account's address tag, joins and loses its plaintext address. Steps 2 and 3
// (bank requests, TestFlight enrolments) arrive with those tables (WS-19).
func onInviteRedeemedTx(ctx context.Context, tx pgx.Tx, inviteID uuid.UUID, emailTag []byte, now time.Time) error {
	if _, err := tx.Exec(ctx,
		`UPDATE waitlist_entries
		    SET state = 'joined', joined_at = $3, email_norm = NULL, updated_at = $3,
		        confirmed_at = coalesce(confirmed_at, $3), invited_at = coalesce(invited_at, $3)
		  WHERE state <> 'joined'
		    AND (id = (SELECT waitlist_entry_id FROM invite_codes WHERE id = $1) OR email_tag = $2)`,
		inviteID, emailTag, now); err != nil {
		return fmt.Errorf("auth: join hook: %w", err)
	}
	return nil
}
