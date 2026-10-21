package waitlist

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func ReapplyLeaves(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry) (int, error) {
	return reapplyDeletions(ctx, pool, entries, purgeledger.KindWaitlistLeave)
}

func ReapplyUnsent(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry) (int, error) {
	return reapplyDeletions(ctx, pool, entries, purgeledger.KindWaitlistUnsent)
}

func reapplyDeletions(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry, kind purgeledger.Kind) (int, error) {
	if pool == nil {
		return 0, errors.New("waitlist: reapply: pool is nil")
	}
	n := 0
	for _, e := range entries {
		if e.Kind != kind {
			continue
		}
		gone, err := reapplyDeletion(ctx, pool, e.ID, kind == purgeledger.KindWaitlistUnsent)
		if err != nil {
			return n, fmt.Errorf("waitlist: reapply a %s: %w", kind, err)
		}
		if gone {
			n++
		}
	}
	return n, nil
}

func reapplyDeletion(ctx context.Context, pool *pgxpool.Pool, entry uuid.UUID, detachInviteMail bool) (bool, error) {
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return false, err
	}
	defer pgtx.Rollback(ctx, tx)
	var id uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM waitlist_entries WHERE id = $1 FOR UPDATE`, entry).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if detachInviteMail {
		if _, err := tx.Exec(ctx,
			`UPDATE mail_log SET waitlist_entry_id = NULL, recipient = NULL
			  WHERE waitlist_entry_id = $1 AND kind = 'invite' AND final_at IS NOT NULL`, entry); err != nil {
			return false, err
		}
	}
	if err := DeleteEntryTx(ctx, tx, entry); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
