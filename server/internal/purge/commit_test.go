package purge

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func endOpenTransaction(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	var pid int
	if err := pool.QueryRow(bg, `SELECT pid FROM pg_stat_activity
		WHERE datname = current_database() AND state = 'idle in transaction' AND pid <> pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	var ended bool
	if err := pool.QueryRow(bg, `SELECT pg_terminate_backend($1)`, pid).Scan(&ended); err != nil || !ended {
		t.Fatalf("terminate backend: %v %v", ended, err)
	}
	for i := 0; i < 500; i++ {
		if n := countRows(t, pool, `SELECT count(*) FROM pg_stat_activity WHERE pid = $1`, pid); n == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the backend did not stop")
}

func TestAFailedCommitCancelsTheLedgerLineAndTheReplayKeepsTheAccount(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "commit-fails")
	path := filepath.Join(t.TempDir(), "purged")
	opts := Options{Goodbye: true,
		Record: func(ids []uuid.UUID) error {
			if err := purgeledger.Append(path, ids, time.Now()); err != nil {
				return err
			}
			endOpenTransaction(t, pool)
			return nil
		},
		Cancel: func(ids []uuid.UUID) error { return purgeledger.AppendCancelled(path, ids, time.Now()) },
	}
	rep, err := PurgeWith(bg, pool, u, opts)
	if err == nil || errors.Is(err, ErrUnsettled) || len(rep.Users) != 0 {
		t.Fatalf("a failed commit: %+v %v", rep.Users, err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("the account went although its commit failed")
	}
	entries, err := purgeledger.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0].Kind != purgeledger.KindPurge || entries[1].Kind != purgeledger.KindPurgeCancelled ||
		entries[1].ID != u {
		t.Fatalf("ledger %+v, want a deletion and its cancellation", entries)
	}
	if rep, err := Replay(bg, pool, purgeledger.IDs(entries)); err != nil || len(rep.Users) != 0 {
		t.Fatalf("a replay after the failed commit: %+v %v", rep.Users, err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("the replay deleted the live account")
	}

	again := Options{
		Record: func(ids []uuid.UUID) error { return purgeledger.Append(path, ids, time.Now()) },
		Cancel: opts.Cancel,
	}
	if rep, err := PurgeWith(bg, pool, u, again); err != nil || len(rep.Users) != 1 {
		t.Fatalf("the holder's second deletion: %+v %v", rep.Users, err)
	}
	if entries, err = purgeledger.Read(path); err != nil {
		t.Fatal(err)
	}
	if ids := purgeledger.IDs(entries); len(ids) != 1 || ids[0] != u {
		t.Fatalf("accounts to purge %v, want the second deletion", ids)
	}
}

func TestARequestCancelledAfterTheLedgerLineStillCommits(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "client-left")
	ctx, cancel := context.WithCancel(bg)
	defer cancel()
	rep, err := PurgeWith(ctx, pool, u, Options{Record: func([]uuid.UUID) error {
		cancel()
		return nil
	}})
	if err != nil || len(rep.Users) != 1 {
		t.Fatalf("a request cancelled before the commit: %+v %v", rep.Users, err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 0 {
		t.Fatal("the recorded deletion did not commit")
	}
}

func TestACommitThatLandedIsAnsweredAsADeletion(t *testing.T) {
	pool := pgtest.New(t)
	called := false
	cause := errors.New("connection lost")
	committed, err := settleFailedCommit(bg, pool, []uuid.UUID{uuid.New()},
		Options{Cancel: func([]uuid.UUID) error { called = true; return nil }}, cause)
	if err != nil || !committed || called {
		t.Fatalf("settled %v %v, cancelled %v", committed, err, called)
	}
}

func TestAnUnreadableOrUncancellableCommitIsUnsettled(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "unsettled")
	cause := errors.New("connection lost")
	refused := errors.New("disk full")
	committed, err := settleFailedCommit(bg, pool, []uuid.UUID{u},
		Options{Cancel: func([]uuid.UUID) error { return refused }}, cause)
	if committed || !errors.Is(err, ErrUnsettled) {
		t.Fatalf("a cancellation that failed: %v %v", committed, err)
	}
	closed, err := pgxpool.NewWithConfig(bg, pool.Config())
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	called := false
	committed, err = settleFailedCommit(bg, closed, []uuid.UUID{u},
		Options{Cancel: func([]uuid.UUID) error { called = true; return nil }}, cause)
	if committed || called || !errors.Is(err, ErrUnsettled) {
		t.Fatalf("a read-back that failed: %v %v, cancelled %v", committed, err, called)
	}
}
