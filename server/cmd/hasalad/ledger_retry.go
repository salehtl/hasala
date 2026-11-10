package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/salehtl/hasala/server/internal/purgeledger"
)

const (
	ledgerRetryInterval = time.Minute
	ledgerWriteFailed   = "hasalad serve: the restore ledger write failed; a line still held is written by the next sweep of held lines"
)

type ledgerWriter struct {
	write func(purgeledger.Entry) error
	every time.Duration

	mu      sync.Mutex
	waiting []purgeledger.Entry
}

func newLedgerWriter(path string) *ledgerWriter {
	return &ledgerWriter{
		every: ledgerRetryInterval,
		write: func(e purgeledger.Entry) error { return purgeledger.AppendEntries(path, e) },
	}
}

func (w *ledgerWriter) record(e purgeledger.Entry) {
	err := w.write(e)
	if err == nil {
		return
	}
	if !errors.Is(err, purgeledger.ErrNotWritten) {
		slog.Error(ledgerWriteFailed, "kind", string(e.Kind), "err", err)
		return
	}
	slog.Warn("hasalad serve: the restore ledger did not record a waitlist deletion; it will be retried", "kind", string(e.Kind), "err", err)
	w.mu.Lock()
	defer w.mu.Unlock()
	w.waiting = append(w.waiting, e)
}

func (w *ledgerWriter) retry(context.Context) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	var (
		left    []purgeledger.Entry
		first   error
		written int
	)
	for _, e := range w.waiting {
		err := w.write(e)
		switch {
		case err == nil:
			written++
		case errors.Is(err, purgeledger.ErrNotWritten):
			left = append(left, e)
			if first == nil {
				first = err
			}
		default:
			slog.Error(ledgerWriteFailed, "kind", string(e.Kind), "err", err)
		}
	}
	w.waiting = left
	if first != nil {
		return written, fmt.Errorf("%d restore ledger line(s) still not written: %w", len(left), first)
	}
	return written, nil
}

func (w *ledgerWriter) run(ctx context.Context) <-chan struct{} {
	retry := countSweep("wrote %d restore ledger line(s) that had failed", w.retry)
	started := false
	loop := startSweepEvery(ctx, "restore ledger retry", w.every, func(ctx context.Context) (string, error) {
		if !started {
			started = true
			return "", nil
		}
		return retry(ctx)
	})
	done := make(chan struct{})
	go func() {
		defer close(done)
		<-loop
		if _, err := w.retry(context.WithoutCancel(ctx)); err != nil {
			slog.Error("hasalad serve: stopping with restore ledger lines not written", "err", err)
		}
	}()
	return done
}
