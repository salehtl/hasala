// Package accounts holds the operator's account switches (spec 02 §14.2,
// §18.3): today the review flag, which marks an account whose data is the
// sample a Beta App Review reviewer may load. It is one of the few packages
// spec 02's fence 6 lets read or write that flag (cmd/hasalad/fence_test.go);
// the API reports it only through GET /api/v1/account.
package accounts

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ErrNoSuchAccount is a switch for an account id that names no account.
var ErrNoSuchAccount = errors.New("accounts: no such account")

// SetReview sets the account's review flag inside tx and answers what it was
// before. A review account is otherwise an ordinary account: the flag changes
// what #40 reports and nothing the server does.
func SetReview(ctx context.Context, tx pgx.Tx, userID uuid.UUID, on bool) (was bool, err error) {
	err = tx.QueryRow(ctx,
		`WITH old AS (SELECT id, review_account FROM users WHERE id = $1 FOR UPDATE)
		 UPDATE users u SET review_account = $2 FROM old WHERE u.id = old.id RETURNING old.review_account`,
		userID, on).Scan(&was)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNoSuchAccount
	}
	if err != nil {
		return false, fmt.Errorf("accounts: set the review flag: %w", err)
	}
	return was, nil
}

// Review reads the account's review flag.
func Review(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, userID uuid.UUID) (bool, error) {
	var on bool
	err := q.QueryRow(ctx, `SELECT review_account FROM users WHERE id = $1`, userID).Scan(&on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNoSuchAccount
	}
	return on, err
}
