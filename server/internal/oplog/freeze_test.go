package oplog

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

const freezeWriter = "ios-00000000-0000-4000-8000-00000000000a"

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func freezeRow(t *testing.T, q execer, u uuid.UUID) {
	t.Helper()
	if _, err := q.Exec(bg,
		`UPDATE users SET frozen_at = now(), freeze_trigger_at = now(), frozen_by = 'holder' WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
}

func firstRow(t *testing.T, u uuid.UUID) []Row {
	t.Helper()
	rows, _ := chainFrom(t, u, freezeWriter, blob.StreamHot, 1, blob.ZeroHash, 1)
	return rows
}

func appendFirstRow(a *Appender, t *testing.T, u uuid.UUID, rows []Row) (bool, error) {
	_, stored, err := a.AppendClientStored(bg, u, freezeWriter, blob.StreamHot, rows, testHeadSig(u, freezeWriter, rows))
	return stored, err
}

func lockedUser(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) interface {
	execer
	Commit(context.Context) error
	Rollback(context.Context) error
} {
	t.Helper()
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(bg) })
	if _, err := tx.Exec(bg, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, u); err != nil {
		t.Fatal(err)
	}
	return tx
}

func TestAnAppendIsRefusedOnceTheAccountIsFrozen(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	freezeRow(t, pool, u)

	stored, err := appendFirstRow(a, t, u, firstRow(t, u))
	if !errors.Is(err, ErrAccountFrozen) {
		t.Fatalf("an append to a frozen account: %v, want ErrAccountFrozen", err)
	}
	if stored {
		t.Fatal("a refused append was reported as stored")
	}
	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1", got)
	}
}

func TestAnAppendWaitingOnAFreezeIsRefusedWhenTheFreezeCommits(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	rows := firstRow(t, u)
	freeze := lockedUser(t, pool, u)
	result := make(chan error, 1)
	go func() {
		_, err := appendFirstRow(a, t, u, rows)
		result <- err
	}()
	waitForLockWaiter(t, pool)
	freezeRow(t, freeze, u)
	if err := freeze.Commit(bg); err != nil {
		t.Fatal(err)
	}
	if err := <-result; !errors.Is(err, ErrAccountFrozen) {
		t.Fatalf("an append that waited on the freeze: %v, want ErrAccountFrozen", err)
	}
	assertGapFree(t, pool, u, 0)
}

func TestAnAppendWaitingOnAFreezeLandsWhenTheFreezeRollsBack(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	rows := firstRow(t, u)
	freeze := lockedUser(t, pool, u)
	result := make(chan error, 1)
	go func() {
		_, err := appendFirstRow(a, t, u, rows)
		result <- err
	}()
	waitForLockWaiter(t, pool)
	freezeRow(t, freeze, u)
	if err := freeze.Rollback(bg); err != nil {
		t.Fatal(err)
	}
	if err := <-result; err != nil {
		t.Fatalf("an append behind a freeze that rolled back: %v", err)
	}
	assertGapFree(t, pool, u, 1)
}
