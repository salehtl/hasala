package purgeledger

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtx"
)

const flushLockKey int64 = 0x48534c4c4447

type HoldFunc func(context.Context, pgx.Tx, Entry) error

type Held struct {
	entries []Entry
}

func HoldTx(ctx context.Context, tx pgx.Tx, e Entry) error {
	if err := check(e); err != nil {
		return fmt.Errorf("%w: %w", ErrNotWritten, err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO restore_ledger_held (line) VALUES ($1)`, formatEntry(e)); err != nil {
		return fmt.Errorf("purgeledger: hold a %q line: %w", e.Kind, err)
	}
	return nil
}

func (h HoldFunc) Tx(ctx context.Context, tx pgx.Tx, entries ...Entry) (Held, error) {
	if h != nil {
		for _, e := range entries {
			if err := h(ctx, tx, e); err != nil {
				return Held{}, err
			}
		}
	}
	return Held{entries: entries}, nil
}

func (h Held) Release(record func(Entry)) {
	if record == nil {
		return
	}
	for _, e := range h.entries {
		record(e)
	}
}

func Flush(ctx context.Context, pool *pgxpool.Pool, path string) (int, error) {
	if path == "" {
		return 0, errors.New("purgeledger: no ledger path")
	}
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, flushLockKey); err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	rows, err := tx.Query(ctx, `SELECT id, line FROM restore_ledger_held ORDER BY id`)
	if err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	var (
		ids []int64
		buf bytes.Buffer
	)
	for rows.Next() {
		var (
			id   int64
			line string
		)
		if err := rows.Scan(&id, &line); err != nil {
			rows.Close()
			return 0, fmt.Errorf("purgeledger: flush: %w", err)
		}
		ids = append(ids, id)
		buf.WriteString(line)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	if len(ids) == 0 {
		return 0, nil
	}
	unlock, err := lock(path)
	if err != nil {
		return 0, fmt.Errorf("%w: %w", ErrNotWritten, err)
	}
	defer unlock()
	if err := appendLocked(path, buf.Bytes()); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM restore_ledger_held WHERE id = ANY($1::bigint[])`, ids); err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("purgeledger: flush: %w", err)
	}
	return len(ids), nil
}
