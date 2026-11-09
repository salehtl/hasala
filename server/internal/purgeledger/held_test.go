package purgeledger

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var heldCtx = context.Background()

func held(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(heldCtx, `SELECT count(*) FROM restore_ledger_held`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func hold(t *testing.T, pool *pgxpool.Pool, entries ...Entry) {
	t.Helper()
	if err := pgx.BeginFunc(heldCtx, pool, func(tx pgx.Tx) error {
		_, err := HoldFunc(HoldTx).Tx(heldCtx, tx, entries...)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

func TestAHeldLineReachesTheLedgerOnceAndInOrder(t *testing.T) {
	pool := pgtest.New(t)
	path := filepath.Join(t.TempDir(), "purged")
	at := time.Date(2026, 10, 20, 9, 30, 0, 0, time.UTC)
	a, b := uuid.New(), uuid.New()
	hold(t, pool, Entry{ID: a, At: at, Kind: KindFreeze, Trigger: at.Add(-time.Hour)})
	hold(t, pool, Entry{ID: b, At: at, Kind: KindPassword}, Entry{ID: a, At: at.Add(time.Minute), Kind: KindUnfreeze})

	if n, err := Flush(heldCtx, pool, path); err != nil || n != 3 {
		t.Fatalf("flush: %d %v", n, err)
	}
	entries, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 || entries[0].Kind != KindFreeze || entries[0].ID != a || !entries[0].Trigger.Equal(at.Add(-time.Hour)) ||
		entries[1].Kind != KindPassword || entries[1].ID != b || entries[2].Kind != KindUnfreeze {
		t.Fatalf("ledger %+v", entries)
	}
	if n := held(t, pool); n != 0 {
		t.Fatalf("%d lines still held after a flush", n)
	}
	if n, err := Flush(heldCtx, pool, path); err != nil || n != 0 {
		t.Fatalf("a second flush: %d %v", n, err)
	}
	if entries, _ := Read(path); len(entries) != 3 {
		t.Fatalf("a second flush left %d entries", len(entries))
	}
}

func TestARolledBackHoldLeavesNoLine(t *testing.T) {
	pool := pgtest.New(t)
	refused := errors.New("the change failed")
	err := pgx.BeginFunc(heldCtx, pool, func(tx pgx.Tx) error {
		if _, err := HoldFunc(HoldTx).Tx(heldCtx, tx, Entry{ID: uuid.New(), At: time.Now(), Kind: KindPassword}); err != nil {
			return err
		}
		return refused
	})
	if !errors.Is(err, refused) {
		t.Fatal(err)
	}
	if n := held(t, pool); n != 0 {
		t.Fatalf("%d lines held for a change that rolled back", n)
	}
}

func TestAFailedFlushKeepsTheLineForTheNextOne(t *testing.T) {
	pool := pgtest.New(t)
	id := uuid.New()
	hold(t, pool, Entry{ID: id, At: time.Now(), Kind: KindSessions})
	dir := t.TempDir()
	path := filepath.Join(dir, "missing", "purged")
	if _, err := Flush(heldCtx, pool, path); !errors.Is(err, ErrNotWritten) {
		t.Fatalf("a flush to a missing directory: %v", err)
	}
	if n := held(t, pool); n != 1 {
		t.Fatalf("%d lines held after a failed flush, want 1", n)
	}
	if err := os.Mkdir(filepath.Dir(path), 0o770); err != nil {
		t.Fatal(err)
	}
	if n, err := Flush(heldCtx, pool, path); err != nil || n != 1 {
		t.Fatalf("the retry: %d %v", n, err)
	}
	if entries, err := Read(path); err != nil || len(entries) != 1 || entries[0].ID != id {
		t.Fatalf("ledger %+v %v", entries, err)
	}
}

func TestConcurrentFlushesWriteEachLineOnce(t *testing.T) {
	pool := pgtest.New(t)
	path := filepath.Join(t.TempDir(), "purged")
	const lines = 40
	var wg sync.WaitGroup
	errs := make(chan error, 2*lines)
	for i := 0; i < lines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := pgx.BeginFunc(heldCtx, pool, func(tx pgx.Tx) error {
				return HoldTx(heldCtx, tx, Entry{ID: uuid.New(), At: time.Now(), Kind: KindSessions})
			}); err != nil {
				errs <- err
				return
			}
			if _, err := Flush(heldCtx, pool, path); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	entries, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[uuid.UUID]bool{}
	for _, e := range entries {
		if seen[e.ID] {
			t.Fatalf("%s was written twice", e.ID)
		}
		seen[e.ID] = true
	}
	if len(seen) != lines {
		t.Fatalf("%d lines reached the ledger, want %d", len(seen), lines)
	}
	if n := held(t, pool); n != 0 {
		t.Fatalf("%d lines still held", n)
	}
}

func TestHoldRefusesWhatItCouldNotWrite(t *testing.T) {
	pool := pgtest.New(t)
	err := pgx.BeginFunc(heldCtx, pool, func(tx pgx.Tx) error {
		return HoldTx(heldCtx, tx, Entry{ID: uuid.Nil, At: time.Now(), Kind: KindPassword})
	})
	if !errors.Is(err, ErrNotWritten) {
		t.Fatalf("a hold with no id: %v", err)
	}
}

func TestAnInterruptedWriteLeavesTheLedgerReadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "purged")
	first := uuid.New()
	if err := Append(path, []uuid.UUID{first}, time.Now()); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	writeEntries = func(f *os.File, b []byte) (int, error) {
		n, _ := f.Write(b[:10])
		return n, errors.New("no space left on device")
	}
	werr := Append(path, []uuid.UUID{uuid.New()}, time.Now())
	writeEntries = (*os.File).Write
	if !errors.Is(werr, ErrNotWritten) {
		t.Fatalf("a write cut short: %v, want ErrNotWritten", werr)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(raw), "\n") || int64(len(raw)) != st.Size() {
		t.Fatalf("the ledger after a write cut short: %q", raw)
	}
	second := uuid.New()
	if err := Append(path, []uuid.UUID{second}, time.Now()); err != nil {
		t.Fatal(err)
	}
	entries, err := Read(path)
	if err != nil || len(entries) != 2 || entries[0].ID != first || entries[1].ID != second {
		t.Fatalf("ledger %+v %v", entries, err)
	}
}
