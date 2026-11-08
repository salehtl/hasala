package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestARestoreLedgerLineThatFailedIsWrittenOnRetry(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "not-there-yet")
	path := filepath.Join(dir, "purged")
	w := newLedgerWriter(path)
	at := time.Now().Add(-time.Hour).Truncate(time.Second)
	e := purgeledger.Entry{ID: uuid.New(), At: at, Kind: purgeledger.KindWaitlistLeave}
	w.record(e)

	if n, err := w.retry(context.Background()); n != 0 || err == nil {
		t.Fatalf("retry while the ledger cannot be written: %d, %v; want 0 and an error", n, err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if n, err := w.retry(context.Background()); n != 1 || err != nil {
		t.Fatalf("retry once the ledger can be written: %d, %v; want 1", n, err)
	}
	entries, err := purgeledger.Read(path)
	if err != nil || len(entries) != 1 || entries[0].ID != e.ID || entries[0].Kind != e.Kind || !entries[0].At.Equal(at) {
		t.Fatalf("ledger %+v %v, want the line with its first time", entries, err)
	}
	if n, err := w.retry(context.Background()); n != 0 || err != nil {
		t.Fatalf("a retry with nothing waiting: %d, %v", n, err)
	}
	if entries, err := purgeledger.Read(path); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after a third retry, want one line", entries, err)
	}
}

func TestALineThatMayHaveReachedTheLedgerIsNotWrittenAgain(t *testing.T) {
	calls := 0
	w := &ledgerWriter{write: func(purgeledger.Entry) error {
		calls++
		return errors.New("sync failed after the write")
	}}
	w.record(purgeledger.Entry{ID: uuid.New(), At: time.Now(), Kind: purgeledger.KindWaitlistUnsent})
	if n, err := w.retry(context.Background()); n != 0 || err != nil || calls != 1 {
		t.Fatalf("retry: %d, %v after %d writes; want no second write", n, err, calls)
	}
}

func TestOneLineThatStillFailsDoesNotHoldBackTheOthers(t *testing.T) {
	bad := uuid.New()
	var mu sync.Mutex
	failing := true
	var written []uuid.UUID
	w := &ledgerWriter{write: func(e purgeledger.Entry) error {
		mu.Lock()
		defer mu.Unlock()
		if failing || e.ID == bad {
			return fmt.Errorf("%w: disk", purgeledger.ErrNotWritten)
		}
		written = append(written, e.ID)
		return nil
	}}
	good := uuid.New()
	w.record(purgeledger.Entry{ID: bad, At: time.Now(), Kind: purgeledger.KindWaitlistLeave})
	w.record(purgeledger.Entry{ID: good, At: time.Now(), Kind: purgeledger.KindWaitlistLeave})
	failing = false
	if n, err := w.retry(context.Background()); n != 1 || err == nil {
		t.Fatalf("retry: %d, %v; want one written and an error for the other", n, err)
	}
	if len(written) != 1 || written[0] != good {
		t.Fatalf("written %v, want %v", written, good)
	}
}

func TestALineThatFailsDuringStopIsTriedOnceMore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gone", "purged")
	w := newLedgerWriter(path)
	w.record(purgeledger.Entry{ID: uuid.New(), At: time.Now(), Kind: purgeledger.KindWaitlistLeave})
	if err := os.Mkdir(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := w.run(ctx)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the retry loop did not stop")
	}
	if entries, err := purgeledger.Read(path); err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v, want the waiting line", entries, err)
	}
}
