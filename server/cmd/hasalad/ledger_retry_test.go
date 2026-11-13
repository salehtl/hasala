package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/waitlist"
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

func TestAFlushThatFailsDuringAnOutageTellsTheTruthAboutItsLine(t *testing.T) {
	pool := pgtest.New(t)
	bg := context.Background()
	path := filepath.Join(t.TempDir(), "purged")
	e := purgeledger.Entry{ID: uuid.New(), At: time.Now().Truncate(time.Second), Kind: purgeledger.KindWaitlistLeave}
	if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error { return purgeledger.HoldTx(bg, tx, e) }); err != nil {
		t.Fatal(err)
	}
	down, err := pgxpool.NewWithConfig(bg, pool.Config())
	if err != nil {
		t.Fatal(err)
	}
	down.Close()

	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	outage := true
	w := &ledgerWriter{write: func(purgeledger.Entry) error {
		if outage {
			_, err := purgeledger.Flush(bg, down, path)
			return err
		}
		return fmt.Errorf("%w: disk", purgeledger.ErrNotWritten)
	}}
	check := func(when string) {
		t.Helper()
		logged := buf.String()
		buf.Reset()
		if strings.Contains(logged, "not retried") || !strings.Contains(logged, "next sweep of held lines") {
			t.Fatalf("%s the log says %q; want it to say the next sweep writes a held line", when, logged)
		}
	}
	w.record(e)
	check("a flush during an outage:")

	outage = false
	w.record(e)
	buf.Reset()
	outage = true
	if n, err := w.retry(bg); n != 0 || err != nil {
		t.Fatalf("retry: %d, %v", n, err)
	}
	check("a retry during an outage:")

	if entries, err := purgeledger.Read(path); err != nil || len(entries) != 0 {
		t.Fatalf("ledger %+v %v during the outage, want nothing", entries, err)
	}
	if n, err := purgeledger.Flush(bg, pool, path); err != nil || n != 1 {
		t.Fatalf("the sweep after the outage: %d, %v; want the held line", n, err)
	}
	entries, err := purgeledger.Read(path)
	if err != nil || len(entries) != 1 || entries[0].ID != e.ID {
		t.Fatalf("ledger %+v %v after the sweep, want the held line", entries, err)
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

func TestAWaitingLineIsWrittenWhileTheServerRuns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-there-yet", "purged")
	w := newLedgerWriter(path)
	w.every = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := w.run(ctx)
	defer func() {
		cancel()
		<-done
	}()
	w.record(purgeledger.Entry{ID: uuid.New(), At: time.Now(), Kind: purgeledger.KindWaitlistLeave})
	if err := os.Mkdir(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		entries, err := purgeledger.Read(path)
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) == 1 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("ledger %+v while the server runs, want the waiting line", entries)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestServeWritesALeaveTheLedgerMissedWhenItStops(t *testing.T) {
	pool := pgtest.New(t)
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	ledgerDir := filepath.Join(dir, "ledger")
	path := filepath.Join(ledgerDir, "purged")
	env := []string{
		"HASALA_PG_DSN=x",
		"HASALA_AUTH_KEY_FILE=" + write("auth", strings.Repeat("cd", 32)+"\n"),
		"HASALA_WEB_ORIGINS=https://hasala.app",
		"HASALA_EMAIL_CF_ACCOUNT_ID=" + strings.Repeat("0a", 16),
		"HASALA_EMAIL_API_TOKEN_FILE=" + write("cftoken", "test-token\n"),
		"HASALA_PURGE_LEDGER_PATH=" + path,
	}
	cfg, err := config.LoadEnv("", func(name string) (string, bool) {
		for _, kv := range env {
			if k, v, ok := strings.Cut(kv, "="); ok && k == name {
				return v, true
			}
		}
		return "", false
	}, env)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	srv := &api.Server{Pool: pool}
	ex, err := wireExtras(ctx, cfg, pool, srv)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Web == nil {
		t.Fatal("the waitlist routes were not mounted")
	}

	var entry uuid.UUID
	if err := pool.QueryRow(context.Background(), `INSERT INTO waitlist_entries (email_tag, email_norm, state, source,
		created_at, updated_at, confirmed_at) VALUES ($1, 'leave@example.test', 'confirmed', 'web', now(), now(), now())
		RETURNING id`, []byte(strings.Repeat("7", 32))).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	var token string
	if err := pgx.BeginFunc(context.Background(), pool, func(tx pgx.Tx) error {
		var err error
		token, err = waitlist.MintToken(context.Background(), tx, entry, "leave")
		return err
	}); err != nil {
		t.Fatal(err)
	}

	before := time.Now().Truncate(time.Second)
	if err := srv.Web.Waitlist.Leave(context.Background(), token); err != nil {
		t.Fatal(err)
	}
	left := time.Now()
	if entries, err := purgeledger.Read(path); err != nil || len(entries) != 0 {
		t.Fatalf("ledger %+v %v before it can be written, want nothing", entries, err)
	}

	time.Sleep(1100 * time.Millisecond)
	if err := os.Mkdir(ledgerDir, 0o700); err != nil {
		t.Fatal(err)
	}
	cancel()
	ex.wait()

	entries, err := purgeledger.Read(path)
	if err != nil || len(entries) != 1 {
		t.Fatalf("ledger %+v %v after the stop, want the one line", entries, err)
	}
	got := entries[0]
	if got.ID != entry || got.Kind != purgeledger.KindWaitlistLeave || got.At.Before(before) || got.At.After(left) {
		t.Fatalf("line %+v, want entry %s as %s between %s and %s", got, entry, purgeledger.KindWaitlistLeave, before, left)
	}
}
