package accounts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/purgeledger"
)

const (
	AuditSuspend   = "cli.account_suspend"
	AuditUnsuspend = "cli.account_unsuspend"
)

func Suspend(ctx context.Context, tx pgx.Tx, userID uuid.UUID) (since time.Time, changed bool, err error) {
	var was *time.Time
	err = tx.QueryRow(ctx, `SELECT suspended_at FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&was)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, ErrNoSuchAccount
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("accounts: read the suspension: %w", err)
	}
	if was != nil {
		return *was, false, nil
	}
	if err := tx.QueryRow(ctx,
		`UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1 RETURNING suspended_at`,
		userID).Scan(&since); err != nil {
		return time.Time{}, false, fmt.Errorf("accounts: suspend: %w", err)
	}
	return since, true, nil
}

func Unsuspend(ctx context.Context, tx pgx.Tx, userID uuid.UUID) (at time.Time, changed bool, err error) {
	var was *time.Time
	err = tx.QueryRow(ctx, `SELECT suspended_at FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&was)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, ErrNoSuchAccount
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("accounts: read the suspension: %w", err)
	}
	if was == nil {
		return time.Time{}, false, nil
	}
	if err := tx.QueryRow(ctx,
		`UPDATE users SET status = 'active', suspended_at = NULL WHERE id = $1 RETURNING now()`, userID).Scan(&at); err != nil {
		return time.Time{}, false, fmt.Errorf("accounts: unsuspend: %w", err)
	}
	return at, true, nil
}

func LastUnsuspend(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, userID uuid.UUID) (*time.Time, error) {
	var at *time.Time
	err := q.QueryRow(ctx,
		`SELECT max(at) FROM admin_audit WHERE target_kind = 'account' AND target_id = $1 AND action = $2`,
		userID.String(), AuditUnsuspend).Scan(&at)
	return at, err
}

type Reapplied struct {
	Suspensions   int
	Unsuspensions int
}

func ReapplySuspensions(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry) (Reapplied, error) {
	var rep Reapplied
	if pool == nil {
		return rep, errors.New("accounts: reapply: pool is nil")
	}
	latest := map[uuid.UUID]int{}
	for i, e := range entries {
		if e.Kind != purgeledger.KindSuspend && e.Kind != purgeledger.KindUnsuspend {
			continue
		}
		if j, ok := latest[e.ID]; !ok || !entries[j].At.After(e.At) {
			latest[e.ID] = i
		}
	}
	for i, e := range entries {
		if j, ok := latest[e.ID]; !ok || j != i {
			continue
		}
		done, err := reapplySuspension(ctx, pool, e)
		if err != nil {
			return rep, fmt.Errorf("accounts: reapply %s of %s: %w", e.Kind, e.At.UTC().Format(time.RFC3339), err)
		}
		if !done {
			continue
		}
		if e.Kind == purgeledger.KindSuspend {
			rep.Suspensions++
		} else {
			rep.Unsuspensions++
		}
	}
	return rep, nil
}

const unseenSince = `NOT EXISTS (SELECT 1 FROM admin_audit WHERE target_kind = 'account' AND target_id = $3
	    AND action IN ($4, $5) AND date_trunc('second', at) >= $2)`

func reapplySuspension(ctx context.Context, pool *pgxpool.Pool, e purgeledger.Entry) (bool, error) {
	sql := `UPDATE users SET status = 'suspended', suspended_at = $2
	  WHERE id = $1 AND status = 'active' AND ` + unseenSince
	if e.Kind == purgeledger.KindUnsuspend {
		sql = `UPDATE users SET status = 'active', suspended_at = NULL
		  WHERE id = $1 AND status = 'suspended' AND date_trunc('second', suspended_at) <= $2 AND ` + unseenSince
	}
	tag, err := pool.Exec(ctx, sql, e.ID, e.At, e.ID.String(), AuditSuspend, AuditUnsuspend)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}
