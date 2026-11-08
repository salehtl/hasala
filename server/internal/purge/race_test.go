package purge

import (
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

func startLedgerReplay(t *testing.T, pool *pgxpool.Pool, path string) <-chan ledgerReplay {
	t.Helper()
	var waiting int
	done := make(chan ledgerReplay, 1)
	go func() {
		rep, err := ReplayLedger(bg, pool, path)
		done <- ledgerReplay{rep, err}
	}()
	for i := 0; i < 1000; i++ {
		waiting = countRows(t, pool, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock'`)
		if waiting > 0 {
			return done
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the replay never waited on the account's row")
	return done
}

type ledgerReplay struct {
	rep Report
	err error
}

func deletionInFlight(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, path string) pgx.Tx {
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

func TestAReplayWaitingOnADeletionSeesTheLineThatCancelledIt(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "cancelled-while-waiting")
	path := filepath.Join(t.TempDir(), "purged")
	deleting := deletionInFlight(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := purgeledger.AppendCancelled(path, []uuid.UUID{u}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := deleting.Rollback(bg); err != nil {
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

func TestAReplayWaitingOnADeletionPurgesWhenTheLineStands(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "line-stands")
	path := filepath.Join(t.TempDir(), "purged")
	deleting := deletionInFlight(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := deleting.Rollback(bg); err != nil {
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

func TestAReplayWaitingOnADeletionThatCommitsPurgesNothing(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "commit-lands")
	path := filepath.Join(t.TempDir(), "purged")
	deleting := deletionInFlight(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if _, err := deleting.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := deleting.Commit(bg); err != nil {
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
	deleting := deletionInFlight(t, pool, u, path)
	done := startLedgerReplay(t, pool, path)
	if err := os.WriteFile(path, []byte("not a ledger line\n"), purgeledger.FileMode); err != nil {
		t.Fatal(err)
	}
	if err := deleting.Rollback(bg); err != nil {
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
