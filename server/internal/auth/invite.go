package auth

// Invites (spec 07 §2.5, §4.4; spec 02 §14.1). internal/invites owns the
// state machine: codes and link keys, minting, the redeemability rule,
// revocation and the sweeps. This file is auth's side of it: the check at
// signup/begin (invites.Resolve), the redemption inside the account-creation
// transaction, bound to the signup's address, and spec 07's join hook
// (waitlist.OnInviteRedeemedTx) in the same transaction.
//
// It gates the creation of a `users` row and nothing else. An account that
// already exists signs in with no code, and `not_invited` is the one
// distinguishable refusal in the auth surface: it is a fact about the
// deployment's policy, not about a credential.

import (
	"context"
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// ErrNotInvited is the one distinguishable signup answer (403 not_invited):
// an unknown, spent, revoked or expired code, or an addressed invite used with
// another address. It is invites.ErrNotInvited, so either name matches.
var ErrNotInvited = invites.ErrNotInvited

// NormalizeInviteCode is invites.Normalize.
func NormalizeInviteCode(raw string) string { return invites.Normalize(raw) }

// InviteCodeHash is invites.CodeHash: nil for a code that normalizes to nothing.
func InviteCodeHash(code string) []byte { return invites.CodeHash(code) }

// MintOptions describes one active invite minted directly (tests, and the
// shape spec 07's worker mints for an emailed invite). The operator's CLI
// mints through invites.MintPrinted.
type MintOptions struct {
	Note   string
	TTL    time.Duration // 1–30 days; zero is 14 days
	Review bool          // a Beta App Review invite (spec 02 §14.2): unaddressed, never emailed
	// EmailTag and LinkKey make an addressed invite. LinkKey needs EmailTag;
	// neither goes with Review.
	EmailTag []byte
	LinkKey  []byte
	Now      time.Time
}

// MintInvite mints one active invite and returns its code, shown once.
func MintInvite(ctx context.Context, q queryExecer, o MintOptions) (string, error) {
	code, err := invites.NewCode()
	if err != nil {
		return "", fmt.Errorf("auth: MintInvite: %w", err)
	}
	ttl := o.TTL
	if ttl == 0 {
		ttl = invites.DefaultTTL
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

// redeemInviteTx spends the invite inside the account-creation transaction
// (spec 02 §14.1): exactly one active, unexpired row, still bound to this
// address when it is addressed, or ErrNotInvited and the transaction fails.
func redeemInviteTx(ctx context.Context, tx pgx.Tx, codeHash, emailTag []byte, userID uuid.UUID, now time.Time) (invites.Redeemed, error) {
	return invites.RedeemTx(ctx, tx, codeHash, emailTag, userID, now)
}

// onInviteRedeemedTx is spec 07 §3.1's join hook, in the account-creation
// transaction: the entry linked to the invite, and every other entry with the
// account's address tag, joins and loses its plaintext address, and their
// bank requests move to the account.
func onInviteRedeemedTx(ctx context.Context, tx pgx.Tx, inviteID, userID uuid.UUID, emailTag []byte) error {
	return waitlist.OnInviteRedeemedTx(ctx, tx, inviteID, userID, emailTag)
}
