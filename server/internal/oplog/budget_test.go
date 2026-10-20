package oplog

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// These tests cover the placement the design calls non-negotiable: the
// cumulative ceiling lives INSIDE the append path (appendTx), so no append
// path — today's AppendClient or any later one — can skip it.

// appendOne appends one sealed row to writer's chain through AppendClient.
func appendOne(ctx context.Context, t *testing.T, a *Appender, u uuid.UUID, writer string) error {
	c, head, err := a.Head(ctx, u, writer, blob.StreamHot)
	if err != nil {
		return err
	}
	r, _, err := sealRow(u, writer, blob.StreamHot, c+1, head)
	if err != nil {
		return err
	}
	_, err = a.AppendClient(ctx, u, writer, blob.StreamHot, []Row{r}, testHeadSig(u, writer, []Row{r}))
	return err
}

func ledger(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, resource string) int64 {
	t.Helper()
	amount, err := budget.New(pool).Usage(bg, u, resource)
	if err != nil {
		t.Fatal(err)
	}
	return amount
}

// storedBytes is what the ledger is supposed to equal: exactly what
// internal/verify's reconciliation computes.
func storedBytes(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, stream string) int64 {
	t.Helper()
	var n int64
	if err := pool.QueryRow(bg,
		`SELECT coalesce(sum(octet_length(blob)), 0) FROM op_log WHERE user_id = $1 AND stream = $2`,
		u, stream).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func setOplogCeiling(t *testing.T, pool *pgxpool.Pool, bytes int64) {
	t.Helper()
	if _, err := pool.Exec(bg,
		`UPDATE account_limits SET oplog_bytes = $1 WHERE user_id IS NULL`, bytes); err != nil {
		t.Fatal(err)
	}
}

func refusalCount(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, resource string) int64 {
	t.Helper()
	var n int64
	if err := pool.QueryRow(bg,
		`SELECT coalesce(sum(count), 0) FROM account_refusals WHERE user_id = $1 AND resource = $2`,
		u, resource).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestAppendClientChargesTheAccountForTheBytesItStored(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)

	var prev [32]byte
	r1, h1 := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, prev)
	r1.TypeFlag = TypeFlagEdit
	r2, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, h1)
	r2.TypeFlag = TypeFlagEdit
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, []Row{r1, r2}, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", []Row{r1, r2})); err != nil {
		t.Fatal(err)
	}
	want := storedBytes(t, pool, u, blob.StreamHot)
	if want == 0 {
		t.Fatal("nothing was stored, so this test proves nothing")
	}
	if got := ledger(t, pool, u, budget.ResourceOplogHotBytes); got != want {
		t.Fatalf("hot ledger = %d, stored = %d", got, want)
	}
}

func TestAppendClientIsRefusedAtTheCeiling(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)
	setOplogCeiling(t, pool, 1)

	var prev [32]byte
	r1, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, prev)
	r1.TypeFlag = TypeFlagEdit
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, []Row{r1}, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", []Row{r1}))
	if !errors.Is(err, budget.ErrRefused) {
		t.Fatalf("append client over the ceiling = %v, want budget.ErrRefused", err)
	}
	if got := storedBytes(t, pool, u, blob.StreamHot); got != 0 {
		t.Fatalf("a refused append stored %d bytes", got)
	}
	if got := refusalCount(t, pool, u, budget.ResourceOplogHotBytes); got != 1 {
		t.Fatalf("hot refusals = %d, want 1", got)
	}
	// The rollback restores the counter, so the refusal costs no seq.
	var next int64
	if err := pool.QueryRow(bg, `SELECT next_seq FROM oplog_seq WHERE user_id = $1`, u).Scan(&next); err != nil {
		t.Fatal(err)
	}
	if next != 1 {
		t.Fatalf("next_seq = %d after a refused append, want 1", next)
	}
}

// TestTheLedgerIsUnchangedAfterARolledBackAppend is the case that makes
// transactional co-location worth the trouble. The second append reaches the
// gate, is charged, and then dies on the unique (writer, stream, counter)
// index — so the bytes never landed and the number that counts them must not
// have either.
//
// If Admit ran on its own connection instead of the caller's transaction, the
// ledger would read double here and every failed append would leak budget until
// an honest account was locked out of its own log.
func TestTheLedgerIsUnchangedAfterARolledBackAppend(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)

	var prev [32]byte
	r1, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, prev)
	if _, err := a.appendRaw(bg, []Row{r1}); err != nil {
		t.Fatal(err)
	}
	before := ledger(t, pool, u, budget.ResourceOplogHotBytes)
	if before == 0 {
		t.Fatal("the first append charged nothing, so this test proves nothing")
	}

	// The identical row again: position (dev-a, hot, 1) is taken, so the INSERT
	// fails AFTER the gate has already charged the account inside that same
	// transaction.
	r2, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, prev)
	if _, err := a.appendRaw(bg, []Row{r2}); err == nil {
		t.Fatal("re-appending a taken position succeeded")
	}
	if got := ledger(t, pool, u, budget.ResourceOplogHotBytes); got != before {
		t.Fatalf("ledger = %d after a rolled-back append, want %d — the charge outlived its rollback", got, before)
	}
	if got := storedBytes(t, pool, u, blob.StreamHot); got != before {
		t.Fatalf("stored bytes = %d, ledger = %d: the two have drifted", got, before)
	}
}

// TestConcurrentAppendsFromOneAccountSerializeWithoutDeadlock. The gate runs
// after allocSeq, so these are already serialized on the counter row before
// they reach the usage row — one lock, one order, no deadlock, and every byte
// counted exactly once.
func TestConcurrentAppendsFromOneAccountSerializeWithoutDeadlock(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)

	const n = 10 // one writer each: dev-0 … dev-9
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = appendOne(bg, t, a, u, fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", 0x100+i))
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent append %d: %v", i, err)
		}
	}
	want := storedBytes(t, pool, u, blob.StreamHot)
	if got := ledger(t, pool, u, budget.ResourceOplogHotBytes); got != want || want != n*1024 {
		t.Fatalf("ledger = %d, stored = %d after %d concurrent appends, want %d", got, want, n, n*1024)
	}
}

// TestOneAccountsHeldUsageRowDoesNotBlockAnother pins the isolation claim
// itself: the gate locks rows keyed by account, never anything shared. The
// same-account half of the test is what stops the other half from being
// vacuous — if the lock were not being taken at all, both would pass.
func TestOneAccountsHeldUsageRowDoesNotBlockAnother(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	busy := insertUser(t, pool)
	other := insertUser(t, pool)

	// Hold busy's usage rows for the duration, exactly as an in-flight append
	// would.
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(bg)
	if err := budget.New(pool).Admit(bg, tx, busy, budget.ResourceOplogHotBytes, 1); err != nil {
		t.Fatal(err)
	}

	// A different account is untouched by that lock.
	freeCtx, cancel := context.WithTimeout(bg, 15*time.Second)
	defer cancel()
	if err := appendOne(freeCtx, t, a, other, "ios-00000000-0000-4000-8000-00000000000a"); err != nil {
		t.Fatalf("an append for a different account was blocked: %v", err)
	}

	// The same account waits, which is what proves the lock is real.
	sameCtx, cancelSame := context.WithTimeout(bg, 2*time.Second)
	defer cancelSame()
	err = appendOne(sameCtx, t, a, busy, "ios-00000000-0000-4000-8000-00000000000a")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("an append for the account whose usage row is held = %v, want it to block until the deadline", err)
	}
}

func TestARefusedAppendIsCountedOnAOneConnectionPool(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	setOplogCeiling(t, pool, 1)

	cfg := pool.Config()
	cfg.MaxConns = 1
	cfg.MinConns = 0
	one, err := pgxpool.NewWithConfig(bg, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	a := &Appender{Pool: one}

	const n = 4
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(bg, 3*time.Second)
			defer cancel()
			start := time.Now()
			errs[i] = appendOne(ctx, t, a, u, "ios-00000000-0000-4000-8000-00000000000a")
			if d := time.Since(start); d > 3*time.Second {
				errs[i] = fmt.Errorf("append took %v: %w", d, errs[i])
			}
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if !errors.Is(err, budget.ErrRefused) {
			t.Fatalf("append %d = %v, want only budget.ErrRefused", i, err)
		}
		var refused *budget.RefusedError
		if !errors.As(err, &refused) {
			t.Fatalf("append %d = %v, want a *budget.RefusedError", i, err)
		}
		if err.Error() != fmt.Sprintf("oplog: append: %s", refused.Error()) {
			t.Fatalf("append %d lost its refusal receipt: %v", i, err)
		}
	}
	if got := refusalCount(t, pool, u, budget.ResourceOplogHotBytes); got != n {
		t.Fatalf("hot refusals = %d, want %d", got, n)
	}
	if got := storedBytes(t, pool, u, blob.StreamHot); got != 0 {
		t.Fatalf("refused appends stored %d bytes", got)
	}
}
