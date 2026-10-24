package invites

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

func MailUnsent(record func(purgeledger.Entry)) func(context.Context, pgx.Tx, mailq.Row) (func(), error) {
	return func(ctx context.Context, tx pgx.Tx, row mailq.Row) (func(), error) {
		if row.Kind != "invite" || row.InviteID == nil {
			return nil, nil
		}
		_, gone, err := closeUnsentTx(ctx, tx, *row.InviteID, []string{"queued", "active"})
		if err != nil || gone == uuid.Nil || record == nil {
			return nil, err
		}
		return func() { recordUnsent(record, gone) }, nil
	}
}

func recordUnsent(record func(purgeledger.Entry), entry uuid.UUID) {
	if record != nil && entry != uuid.Nil {
		record(purgeledger.Entry{ID: entry, At: time.Now(), Kind: purgeledger.KindWaitlistUnsent})
	}
}

func closeUnsentTx(ctx context.Context, tx pgx.Tx, id uuid.UUID, states []string) (bool, uuid.UUID, error) {
	var entry *uuid.UUID
	err := tx.QueryRow(ctx,
		`SELECT waitlist_entry_id FROM invite_codes WHERE id = $1 AND state = ANY($2::text[]) FOR UPDATE`,
		id, states).Scan(&entry)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, uuid.Nil, nil
	}
	if err != nil {
		return false, uuid.Nil, fmt.Errorf("invites: lock an unsent invite: %w", err)
	}
	var pending bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM mail_log WHERE invite_id = $1 AND status IN ('queued','sending','sent'))`,
		id).Scan(&pending); err != nil {
		return false, uuid.Nil, fmt.Errorf("invites: read an invite's mail: %w", err)
	}
	if pending {
		return false, uuid.Nil, nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = now() WHERE id = $1`, id); err != nil {
		return false, uuid.Nil, fmt.Errorf("invites: revoke an unsent invite: %w", err)
	}
	if entry == nil {
		return true, uuid.Nil, nil
	}
	var (
		state string
		open  bool
	)
	err = tx.QueryRow(ctx,
		`SELECT e.state, EXISTS (SELECT 1 FROM invite_codes i WHERE i.waitlist_entry_id = e.id
		                          AND i.state IN ('awaiting_testflight','queued','active'))
		   FROM waitlist_entries e WHERE e.id = $1 FOR UPDATE OF e`, *entry).Scan(&state, &open)
	if errors.Is(err, pgx.ErrNoRows) {
		return true, uuid.Nil, nil
	}
	if err != nil {
		return false, uuid.Nil, fmt.Errorf("invites: read the unsent invite's entry: %w", err)
	}
	if state != "invited" || open {
		return true, uuid.Nil, nil
	}
	var bounced bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM mail_log WHERE invite_id = $1 AND status = 'bounced')`, id).Scan(&bounced); err != nil {
		return false, uuid.Nil, fmt.Errorf("invites: read the unsent invite's bounce: %w", err)
	}
	if !bounced {
		if _, err := tx.Exec(ctx,
			`UPDATE waitlist_entries SET state = 'confirmed', invited_at = NULL, updated_at = now() WHERE id = $1`,
			*entry); err != nil {
			return false, uuid.Nil, fmt.Errorf("invites: put the unsent invite's entry back on the list: %w", err)
		}
		return true, uuid.Nil, nil
	}
	if err := waitlist.DeleteBouncedEntryTx(ctx, tx, *entry); err != nil {
		return false, uuid.Nil, err
	}
	return true, *entry, nil
}

func sweepUnsent(ctx context.Context, db *pgxpool.Pool, record func(purgeledger.Entry)) (int64, error) {
	rows, err := db.Query(ctx,
		`SELECT id FROM invite_codes i WHERE state = 'queued' AND created_at < now() - interval '1 hour'
		    AND NOT EXISTS (SELECT 1 FROM mail_log m WHERE m.invite_id = i.id AND m.status IN ('queued','sending','sent'))
		  ORDER BY created_at`)
	if err != nil {
		return 0, fmt.Errorf("invites: unsent sweep: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return 0, fmt.Errorf("invites: unsent sweep: %w", err)
	}
	var n int64
	for _, id := range ids {
		closed, err := sweepOne(ctx, db, id, record)
		if err != nil {
			return n, fmt.Errorf("invites: unsent sweep: %w", err)
		}
		if closed {
			n++
		}
	}
	return n, nil
}

func sweepOne(ctx context.Context, db *pgxpool.Pool, id uuid.UUID, record func(purgeledger.Entry)) (bool, error) {
	tx, err := pgtx.BeginReadCommitted(ctx, db)
	if err != nil {
		return false, err
	}
	defer pgtx.Rollback(ctx, tx)
	closed, gone, err := closeUnsentTx(ctx, tx, id, []string{"queued"})
	if err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	recordUnsent(record, gone)
	return closed, nil
}
