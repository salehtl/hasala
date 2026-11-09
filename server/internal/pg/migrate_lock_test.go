package pg_test

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pg"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func emptyOwner(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn, _ := pgtest.NewEmpty(t)
	owner, err := pg.Open(bg, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.Close)
	return owner
}

func awaitCount(t *testing.T, pool *pgxpool.Pool, want int, what, sql string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		var n int
		if err := pool.QueryRow(bg, sql).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: %d, want %d", what, n, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

const heldMigrateLock = `FROM pg_locks WHERE locktype = 'advisory' AND granted
	AND database = (SELECT oid FROM pg_database WHERE datname = current_database())`

func TestAMigrateStopsWhenItsLockSessionDies(t *testing.T) {
	owner := emptyOwner(t)
	if err := pg.MigrateTo(bg, owner, 33); err != nil {
		t.Fatal(err)
	}
	blocker, err := owner.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(bg)
	if _, err := blocker.Exec(bg, `LOCK TABLE mail_log IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- pg.MigrateLocked(bg, owner, 34) }()

	awaitCount(t, owner, 1, "lock holders", `SELECT count(*) `+heldMigrateLock)
	awaitCount(t, owner, 1, "migrations waiting on mail_log", `SELECT count(*) FROM pg_stat_activity
		WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%mail_log_untagged_shape%'`)

	var killed bool
	if err := owner.QueryRow(bg, `SELECT pg_terminate_backend(pid) `+heldMigrateLock).Scan(&killed); err != nil || !killed {
		t.Fatalf("terminate the lock session: %v %v", killed, err)
	}
	awaitCount(t, owner, 0, "lock holders", `SELECT count(*) `+heldMigrateLock)
	if err := blocker.Rollback(bg); err != nil {
		t.Fatal(err)
	}

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("the run carried on after its lock was lost")
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the run did not finish")
	}
	if v, err := pg.AppliedVersion(bg, owner); err != nil || v != 33 {
		t.Fatalf("applied %d, %v; want 33", v, err)
	}

	if err := pg.MigrateLocked(bg, owner, 33); err != nil {
		t.Fatalf("migrate to the applied version: %v", err)
	}
	if err := pg.MigrateLocked(bg, owner, 0); err != nil {
		t.Fatalf("the next migrate: %v", err)
	}
	if n, err := pg.Pending(bg, owner); err != nil || n != 0 {
		t.Fatalf("Pending = %d, %v; want 0", n, err)
	}
}

func TestSimultaneousMigratesApplyEachVersionOnce(t *testing.T) {
	owner := emptyOwner(t)
	const n = 4
	errs := make(chan error, n)
	for range n {
		go func() { errs <- pg.MigrateLocked(bg, owner, 0) }()
	}
	for range n {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	var repeated int
	if err := owner.QueryRow(bg, `SELECT count(*) FROM (SELECT version_id FROM goose_db_version
		GROUP BY version_id HAVING count(*) > 1) r`).Scan(&repeated); err != nil {
		t.Fatal(err)
	}
	if repeated != 0 {
		t.Fatalf("%d versions applied more than once", repeated)
	}
	if p, err := pg.Pending(bg, owner); err != nil || p != 0 {
		t.Fatalf("Pending = %d, %v; want 0", p, err)
	}
}
