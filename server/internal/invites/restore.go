package invites

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func RecordRevoked(record func(purgeledger.Entry), id uuid.UUID, at time.Time) {
	if record != nil && id != uuid.Nil {
		record(purgeledger.Entry{ID: id, At: at, Kind: purgeledger.KindInviteRevoked})
	}
}

func ReapplyRevocations(ctx context.Context, pool *pgxpool.Pool, entries []purgeledger.Entry) (int, error) {
	if pool == nil {
		return 0, errors.New("invites: reapply: pool is nil")
	}
	n := 0
	for _, e := range entries {
		if e.Kind != purgeledger.KindInviteRevoked {
			continue
		}
		done, err := reapplyRevocation(ctx, pool, e)
		if err != nil {
			return n, fmt.Errorf("invites: reapply a revocation: %w", err)
		}
		if done {
			n++
		}
	}
	return n, nil
}

func reapplyRevocation(ctx context.Context, pool *pgxpool.Pool, e purgeledger.Entry) (bool, error) {
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return false, err
	}
	defer pgtx.Rollback(ctx, tx)
	var entry *uuid.UUID
	err = tx.QueryRow(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = coalesce(closed_at, $2)
		  WHERE id = $1 AND state IN ('awaiting_testflight','queued','active') RETURNING waitlist_entry_id`,
		e.ID, e.At).Scan(&entry)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if entry != nil {
		if _, err := tx.Exec(ctx,
			`UPDATE waitlist_entries e SET state = 'confirmed', invited_at = NULL, updated_at = $2
			  WHERE e.id = $1 AND e.state = 'invited'
			    AND NOT EXISTS (SELECT 1 FROM invite_codes i WHERE i.waitlist_entry_id = e.id
			                     AND i.state IN ('awaiting_testflight','queued','active'))`, *entry, e.At); err != nil {
			return false, err
		}
	}
	return true, tx.Commit(ctx)
}
