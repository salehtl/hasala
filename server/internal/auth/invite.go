package auth

// Invite codes: the closed beta's gate on account CREATION. The state machine,
// minting and the redeemability rule live in internal/invites (spec 07 §2.5,
// §15.1); this file is auth's side of it, the redemption inside the account
// transaction.
//
// # What this gates, and what it deliberately does not
//
// It gates the creation of a `users` row and nothing else. An account that
// already exists signs in with no code, for ever, and a code presented by a
// returning user is ignored rather than spent.
//
// # The one distinguishable rejection in the whole auth surface
//
// Every other authentication failure collapses to a byte-identical 401.
// `not_invited` is a fact about the deployment's policy, not about the
// credential, and it reveals nothing an attacker could not learn by trying a
// code.

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// ErrNotInvited means account creation was required and no redeemable invite
// authorized it. It is invites.ErrNotInvited, so either name matches.
var ErrNotInvited = invites.ErrNotInvited

// NormalizeInviteCode is invites.Normalize.
func NormalizeInviteCode(raw string) string { return invites.Normalize(raw) }

// InviteCodeHash is invites.CodeHash: nil for an empty code.
func InviteCodeHash(code string) []byte { return invites.CodeHash(code) }

// MintInvite creates one active, unaddressed invite with the default lifetime
// and returns its code (printed once; only its hash is stored).
func MintInvite(ctx context.Context, pool *pgxpool.Pool, note string, now time.Time) (string, error) {
	if pool == nil {
		return "", errors.New("auth: MintInvite: pool is nil")
	}
	_, code, err := invites.MintPrinted(ctx, pool, note, invites.DefaultTTL, false, now)
	return code, err
}

// redeemInviteTx spends one invite inside the caller's transaction, which MUST
// be the transaction that creates the account, and runs the waitlist's join
// hook in the same transaction (spec 07 §3.1): a failed signup leaves every
// row as it was.
func redeemInviteTx(ctx context.Context, tx pgx.Tx, codeHash []byte, userID uuid.UUID, now time.Time) error {
	r, err := invites.RedeemTx(ctx, tx, codeHash, userID, now)
	if err != nil {
		return err
	}
	// The account's email_tag (step 4 of the hook) needs the auth key, which
	// the passkey ceremony does not hold; the signup work passes it.
	return waitlist.OnInviteRedeemedTx(ctx, tx, r.InviteID, userID, nil)
}
