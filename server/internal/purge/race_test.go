package purge

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestASecondPurgeOfOneAccountQueuesNoSecondGoodbye(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "raced")
	exec(t, pool, `UPDATE users SET email_norm = 'raced@example.com' WHERE id = $1`, u)
	first, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Rollback(bg) }()
	if _, err := first.Exec(bg, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, u); err != nil {
		t.Fatal(err)
	}
	type result struct {
		rep Report
		err error
	}
	second := make(chan result, 1)
	go func() {
		rep, err := PurgeWith(bg, pool, u, Options{Goodbye: true})
		second <- result{rep, err}
	}()
	time.Sleep(300 * time.Millisecond)
	if _, err := first.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := first.Commit(bg); err != nil {
		t.Fatal(err)
	}
	r := <-second
	if r.err != nil {
		t.Fatal(r.err)
	}
	if len(r.rep.Users) != 0 || r.rep.Goodbyes != 0 {
		t.Fatalf("the second purge reports %v and %d goodbyes", r.rep.Users, r.rep.Goodbyes)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM mail_log WHERE recipient = 'raced@example.com'`); n != 0 {
		t.Fatalf("%d goodbye emails queued by the second purge", n)
	}
}

func lockWaiters(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	return countRows(t, pool, `SELECT count(*) FROM pg_stat_activity
		WHERE datname = current_database() AND wait_event_type = 'Lock'`)
}

func waitForLockWaiter(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	for i := 0; i < 1000; i++ {
		if lockWaiters(t, pool) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("nothing ever waited on a lock")
}

func heldAdvisoryLocks(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	return countRows(t, pool, `SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted`)
}

type ledgerReplay struct {
	rep Report
	err error
}

func startLedgerReplay(t *testing.T, pool *pgxpool.Pool, path string) <-chan ledgerReplay {
	t.Helper()
	done := make(chan ledgerReplay, 1)
	go func() {
		rep, err := ReplayLedger(bg, pool, path)
		done <- ledgerReplay{rep, err}
	}()
	waitForLockWaiter(t, pool)
	return done
}

func replayBesideDeletion(t *testing.T, pool *pgxpool.Pool, path string) <-chan ledgerReplay {
	t.Helper()
	done := make(chan ledgerReplay, 1)
	finished := make(chan struct{})
	go func() {
		rep, err := ReplayLedger(bg, pool, path)
		done <- ledgerReplay{rep, err}
		close(finished)
	}()
	for i := 0; i < 1000; i++ {
		select {
		case <-finished:
			return done
		default:
		}
		if lockWaiters(t, pool) > 0 {
			return done
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the replay neither finished nor waited")
	return done
}

func lineWithRowHeld(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, path string) pgx.Tx {
	t.Helper()
	if err := purgeledger.Append(path, []uuid.UUID{u}, time.Now()); err != nil {
		t.Fatal(err)
	}
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

func ledgerNames(t *testing.T, path string) []uuid.UUID {
	t.Helper()
	entries, err := purgeledger.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	return purgeledger.IDs(entries)
}

func wantDeferredOnly(t *testing.T, r ledgerReplay, u uuid.UUID) {
	t.Helper()
	if r.err != nil || len(r.rep.Users) != 0 || len(r.rep.Deferred) != 1 || r.rep.Deferred[0] != u {
		t.Fatalf("a replay beside a deletion: purged %v, deferred %v, error %v", r.rep.Users, r.rep.Deferred, r.err)
	}
}

func cancelIn(path string) func([]uuid.UUID) error {
	return func(ids []uuid.UUID) error { return purgeledger.AppendCancelled(path, ids, time.Now()) }
}

func TestAReplayDuringADeletionWhoseCommitFailsLeavesTheAccount(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "commit-fails-beside-replay")
	path := filepath.Join(t.TempDir(), "purged")
	var during <-chan ledgerReplay
	rep, err := PurgeWith(bg, pool, u, Options{Goodbye: true,
		Record: func(ids []uuid.UUID) error {
			if err := purgeledger.Append(path, ids, time.Now()); err != nil {
				return err
			}
			during = replayBesideDeletion(t, pool, path)
			endOpenTransaction(t, pool)
			return nil
		},
		Cancel: cancelIn(path),
	})
	wantDeferredOnly(t, <-during, u)
	if err == nil || errors.Is(err, ErrUnsettled) || len(rep.Users) != 0 {
		t.Fatalf("the deletion whose commit failed: %v %v", rep.Users, err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("the replay deleted an account whose deletion failed to commit")
	}
	if ids := ledgerNames(t, path); len(ids) != 0 {
		t.Fatalf("accounts to purge %v, want none after the cancellation", ids)
	}
	if n := heldAdvisoryLocks(t, pool); n != 0 {
		t.Fatalf("%d holds left after the deletion ended", n)
	}
}

func TestAFailedCommitKeepsTheAccountHeldUntilItIsSettled(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "held-until-settled")
	path := filepath.Join(t.TempDir(), "purged")
	inTheGap := make(chan ledgerReplay, 1)
	rep, err := PurgeWith(bg, pool, u, Options{
		Record: func(ids []uuid.UUID) error {
			if err := purgeledger.Append(path, ids, time.Now()); err != nil {
				return err
			}
			next, err := pool.Begin(bg)
			if err != nil {
				return err
			}
			go func() {
				defer func() { _ = next.Rollback(bg) }()
				if _, err := next.Exec(bg, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, u); err != nil {
					inTheGap <- ledgerReplay{err: err}
					return
				}
				ctx, cancel := context.WithTimeout(bg, 5*time.Second)
				defer cancel()
				rep, err := ReplayLedger(ctx, pool, path)
				inTheGap <- ledgerReplay{rep, err}
			}()
			waitForLockWaiter(t, pool)
			endOpenTransaction(t, pool)
			return nil
		},
		Cancel: cancelIn(path),
	})
	wantDeferredOnly(t, <-inTheGap, u)
	if err == nil || errors.Is(err, ErrUnsettled) || len(rep.Users) != 0 {
		t.Fatalf("the deletion whose commit failed: %v %v", rep.Users, err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("a replay between the rollback and the read-back deleted the account")
	}
	if ids := ledgerNames(t, path); len(ids) != 0 {
		t.Fatalf("accounts to purge %v, want none after the cancellation", ids)
	}
	again, err := ReplayLedger(bg, pool, path)
	if err != nil || len(again.Users) != 0 || len(again.Deferred) != 0 {
		t.Fatalf("the next replay: purged %v, deferred %v, error %v", again.Users, again.Deferred, err)
	}
}

func TestAReplayDuringADeletionThatCommitsLeavesItToTheDeletion(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "commit-lands-beside-replay")
	exec(t, pool, `UPDATE users SET email_norm = 'commit-lands@example.com' WHERE id = $1`, u)
	path := filepath.Join(t.TempDir(), "purged")
	var during <-chan ledgerReplay
	rep, err := PurgeWith(bg, pool, u, Options{Goodbye: true,
		Record: func(ids []uuid.UUID) error {
			if err := purgeledger.Append(path, ids, time.Now()); err != nil {
				return err
			}
			during = replayBesideDeletion(t, pool, path)
			return nil
		},
		Cancel: cancelIn(path),
	})
	wantDeferredOnly(t, <-during, u)
	if err != nil || len(rep.Users) != 1 || rep.Goodbyes != 1 {
		t.Fatalf("the deletion: %v, %d goodbyes, %v", rep.Users, rep.Goodbyes, err)
	}
	again, err := ReplayLedger(bg, pool, path)
	if err != nil || len(again.Users) != 0 || len(again.Deferred) != 0 {
		t.Fatalf("the next replay: purged %v, deferred %v, error %v", again.Users, again.Deferred, err)
	}
	if n := heldAdvisoryLocks(t, pool); n != 0 {
		t.Fatalf("%d holds left after the deletion and the replay ended", n)
	}
}

func TestADeletionWaitsForAReplayThatHoldsTheAccount(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "replay-first")
	exec(t, pool, `UPDATE users SET email_norm = 'replay-first@example.com' WHERE id = $1`, u)
	type deletion struct {
		rep Report
		err error
	}
	second := make(chan deletion, 1)
	replayed, err := replayIDs(bg, pool, []uuid.UUID{u}, Options{armed: func(users []uuid.UUID) ([]uuid.UUID, error) {
		go func() {
			rep, err := PurgeWith(bg, pool, u, Options{Goodbye: true, Record: func([]uuid.UUID) error { return nil }})
			second <- deletion{rep, err}
		}()
		waitForLockWaiter(t, pool)
		return users, nil
	}})
	if err != nil || len(replayed.Users) != 1 {
		t.Fatalf("the replay: %v %v", replayed.Users, err)
	}
	d := <-second
	if d.err != nil || len(d.rep.Users) != 0 || d.rep.Goodbyes != 0 {
		t.Fatalf("the deletion after the replay: %v, %d goodbyes, %v", d.rep.Users, d.rep.Goodbyes, d.err)
	}
}

func TestAReplayBehindARowLockSeesALineWrittenWhileItWaited(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "cancelled-while-waiting")
	path := filepath.Join(t.TempDir(), "purged")
	holder := lineWithRowHeld(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := purgeledger.AppendCancelled(path, []uuid.UUID{u}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := holder.Rollback(bg); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || len(r.rep.Users) != 0 {
		t.Fatalf("the replay after the cancellation: %v %v", r.rep.Users, r.err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("the replay deleted an account whose deletion was cancelled while it waited")
	}
}

func TestAReplayBehindARowLockThatIsNoDeletionPurgesAStandingLine(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "line-stands")
	path := filepath.Join(t.TempDir(), "purged")
	holder := lineWithRowHeld(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := holder.Rollback(bg); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || len(r.rep.Users) != 1 {
		t.Fatalf("the replay of a standing line: %v %v", r.rep.Users, r.err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 0 {
		t.Fatal("the account named by a standing line is still there")
	}
}

func TestAReplayBehindARowLockThatDeletesTheRowPurgesNothing(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "commit-lands")
	path := filepath.Join(t.TempDir(), "purged")
	holder := lineWithRowHeld(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if _, err := holder.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := holder.Commit(bg); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || len(r.rep.Users) != 0 {
		t.Fatalf("the replay after the commit: %v %v", r.rep.Users, r.err)
	}
}

func TestAReplayThatCannotReadTheLedgerAgainDeletesNothing(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "unreadable-after-wait")
	path := filepath.Join(t.TempDir(), "purged")
	holder := lineWithRowHeld(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := os.WriteFile(path, []byte("not a ledger line\n"), purgeledger.FileMode); err != nil {
		t.Fatal(err)
	}
	if err := holder.Rollback(bg); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err == nil || len(r.rep.Users) != 0 {
		t.Fatalf("a replay with an unreadable ledger: %v %v", r.rep.Users, r.err)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM users WHERE id = $1`, u); n != 1 {
		t.Fatal("the replay deleted an account although it could not read the ledger again")
	}
}
