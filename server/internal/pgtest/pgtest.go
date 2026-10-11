// Package pgtest boots a throwaway PostgreSQL cluster for tests. It never
// touches a system cluster, never binds TCP, and needs no running service.
//
// Host requirement: initdb and postgres, from $HASALA_TEST_PG_BINDIR, then
// PATH (the repo's devShell, or Homebrew), then Debian's
// /usr/lib/postgresql/*/bin. See postgresBinDir.
// Set HASALA_TEST_POSTGRES_URL to reuse an already-running server instead —
// scripts/check.sh does exactly that so one cluster serves the whole run.
// Per-package boot remains the fallback when that variable is unset, so
// `go test ./internal/pg/` in isolation still works standalone.
//
// # Roles (spec 02 §5.2, §5.7)
//
// Every cluster gets the production roles: hasala_migrate (owns each test
// database and its public schema, and applies the migrations) and
// hasala_runtime (DML only, the session timeouts of the QA host). New returns
// a pool connected AS hasala_runtime, so every test exercises the runtime
// grants — the append-only op_log and key_history, the revoke-once writers —
// exactly as serve does. NewWithOwner also returns the owner's pool, for the
// few tests that must show what the schema owner can and cannot do.
package pgtest

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/pg"
)

var (
	adminDSN  string
	adminPool *pgxpool.Pool // shared for the whole run: CREATE/DROP DATABASE only
	dbSeq     atomic.Int64
)

// EnsureRoles creates hasala_migrate and hasala_runtime on the cluster behind
// adminDSN if they do not exist yet. It is idempotent and safe to race: test
// packages sharing one cluster all call it.
func EnsureRoles(ctx context.Context, admin *pgxpool.Pool) error {
	const ddl = `DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hasala_migrate') THEN
    CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hasala_runtime') THEN
    CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    ALTER ROLE hasala_runtime SET statement_timeout = '15s';
    ALTER ROLE hasala_runtime SET lock_timeout = '5s';
    ALTER ROLE hasala_runtime SET idle_in_transaction_session_timeout = '30s';
  END IF;
END $$`
	var err error
	for attempt := 0; attempt < 10; attempt++ {
		if _, err = admin.Exec(ctx, ddl); err == nil {
			return nil
		}
		// Two packages creating the same role at once: one wins, the other
		// sees a unique violation on pg_authid. Retry; the second pass finds it.
		time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
	}
	return fmt.Errorf("pgtest: create roles: %w", err)
}

// Main boots one cluster for the whole package run and tears it down after.
func Main(m *testing.M) int {
	stop, dsn, err := boot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: %v\n", err)
		return 1
	}
	adminDSN = dsn
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: connect admin pool: %v\n", err)
		stop()
		return 1
	}
	adminPool = pool
	if err := EnsureRoles(context.Background(), pool); err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: %v\n", err)
		adminPool.Close()
		stop()
		return 1
	}
	code := m.Run()
	adminPool.Close()
	stop()
	return code
}

// New returns a pool connected as hasala_runtime on a freshly created
// database, owned by hasala_migrate and migrated as hasala_migrate. The
// database is dropped when the test (and any subtests holding it open)
// finishes.
func New(t *testing.T) *pgxpool.Pool {
	t.Helper()
	runtime, _ := NewWithOwner(t)
	return runtime
}

// NewOwner returns a pool connected as hasala_migrate, the schema owner, on a
// freshly created and migrated database.
func NewOwner(t *testing.T) *pgxpool.Pool {
	t.Helper()
	_, owner := NewWithOwner(t)
	return owner
}

// NewWithOwner returns two pools on one freshly created, migrated database:
// the runtime role's and the schema owner's.
func NewWithOwner(t *testing.T) (runtime, owner *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	name := newDatabase(t)
	owner = openPool(t, dsnFor(adminDSN, pg.RoleMigrate, name))
	if err := pg.Migrate(ctx, owner); err != nil {
		t.Fatal(err)
	}
	runtime = openPool(t, dsnFor(adminDSN, pg.RoleRuntime, name))
	return runtime, owner
}

// NewEmpty creates a database prepared exactly as infra's setup.sql leaves
// one (spec 02 §5.2) but NOT migrated, and returns the DSNs of the schema
// owner and of the runtime role on it: what `hasalad migrate` and then
// `hasalad serve` are pointed at on a fresh host.
func NewEmpty(t *testing.T) (migrateDSN, runtimeDSN string) {
	t.Helper()
	name := newDatabase(t)
	return dsnFor(adminDSN, pg.RoleMigrate, name), dsnFor(adminDSN, pg.RoleRuntime, name)
}

// newDatabase creates a database owned by hasala_migrate and does what
// infra's setup.sql does as the bootstrap superuser (spec 02 §5.2): the
// schema owned by hasala_migrate, PUBLIC with no rights on the database or
// the schema, and CONNECT for the runtime role. It is dropped when the test
// finishes.
func newDatabase(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	name := fmt.Sprintf("t%d_%d", os.Getpid(), dbSeq.Add(1))
	if _, err := adminPool.Exec(ctx, "CREATE DATABASE "+name+" OWNER hasala_migrate"); err != nil {
		t.Fatal(err)
	}
	// Registered immediately after CREATE succeeds, before anything below can
	// fail: t.Fatal runs only the cleanups already registered. Cleanups run
	// last-registered-first, so every pool opened later is closed before this.
	t.Cleanup(func() {
		if _, err := adminPool.Exec(context.Background(),
			"DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
			t.Errorf("pgtest: drop database %s: %v", name, err)
		}
	})
	su, err := pg.Open(ctx, dsnFor(adminDSN, "", name))
	if err != nil {
		t.Fatal(err)
	}
	defer su.Close()
	for _, stmt := range []string{
		"ALTER SCHEMA public OWNER TO hasala_migrate",
		"REVOKE ALL ON SCHEMA public FROM PUBLIC",
		"REVOKE ALL ON DATABASE " + name + " FROM PUBLIC",
		"GRANT CONNECT ON DATABASE " + name + " TO hasala_runtime",
	} {
		if _, err := su.Exec(ctx, stmt); err != nil {
			t.Fatalf("pgtest: %s: %v", stmt, err)
		}
	}
	return name
}

func openPool(t *testing.T, dsn string) *pgxpool.Pool {
	t.Helper()
	p, err := pg.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p
}

// OpenAs returns a pool connected as role to the same database as p. The role
// must already exist and be allowed to log in.
func OpenAs(t *testing.T, p *pgxpool.Pool, role string) *pgxpool.Pool {
	t.Helper()
	db := p.Config().ConnConfig.Database
	pool, err := pg.Open(context.Background(), dsnFor(adminDSN, role, db))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// Superuser returns a pool connected as the cluster's bootstrap superuser to
// the same database as p. It is for the handful of tests that must show what
// even a superuser cannot do (an append-only trigger binds every role) or
// that must set up a hostile schema; nothing else should use it.
func Superuser(t *testing.T, p *pgxpool.Pool) *pgxpool.Pool {
	t.Helper()
	db := p.Config().ConnConfig.Database
	su, err := pg.Open(context.Background(), dsnFor(adminDSN, "", db))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(su.Close)
	return su
}

// dsnFor swaps the user (when non-empty) and the database name in a DSN of
// the form produced by boot(): postgres://postgres@/postgres?host=...&port=...&sslmode=disable.
// The admin DSN always connects to the "postgres" maintenance database as the
// bootstrap superuser, so this replaces the URL's user and path.
//
// This is NOT the same as pgxpool.ParseConfig + mutating cfg.ConnConfig.Database
// + cfg.ConnString(): pgx's ConnConfig.ConnString() returns the exact string
// it was originally parsed from (a cached field), not a re-serialization of
// the mutated struct, so that approach silently keeps connecting to
// "postgres" no matter what Database is set to. Rewriting the URL path
// directly is what actually changes which database pgx connects to.
func dsnFor(adminDSN, user, name string) string {
	u, err := url.Parse(adminDSN)
	if err != nil || u.Scheme == "" {
		// Fallback for keyword/value DSNs (e.g. "host=... user=... dbname=x"),
		// which HASALA_TEST_POSTGRES_URL could in principle be set to. pgx
		// takes the last value it sees for a key, so appending wins.
		out := adminDSN + " dbname=" + name
		if user != "" {
			out += " user=" + user
		}
		return out
	}
	if user != "" {
		u.User = url.User(user)
	}
	u.Path = "/" + name
	return u.String()
}

func boot() (func(), string, error) {
	if u := os.Getenv("HASALA_TEST_POSTGRES_URL"); u != "" {
		return func() {}, u, nil
	}
	dir, srv, dsn, err := bootCluster(false)
	if err != nil {
		return nil, "", err
	}
	stop := func() {
		_ = srv.Process.Signal(syscall.SIGQUIT)
		_, _ = srv.Process.Wait()
		_ = os.RemoveAll(dir)
	}
	return stop, dsn, nil
}

// BootStandalone starts a cluster that outlives the calling process: the
// postgres server is started in its own session (SysProcAttr.Setsid) so it
// is not in the caller's process group and is not killed by any signal the
// caller's group receives, and is left running (no Signal/Wait) when
// BootStandalone returns. It is used by cmd/boot, whose whole purpose is to
// print connection info and exit while the server keeps running — see
// scripts/check.sh, which does `eval "$(go run ./internal/pgtest/cmd/boot)"`
// to share one cluster across every v2 package's test run instead of each
// package's own TestMain (via boot() above) paying for its own initdb.
//
// It returns the admin DSN and the path to a self-contained shell script
// that stops the server and removes its data directory; the caller is
// responsible for eventually running that script.
func BootStandalone() (dsn string, stopScript string, err error) {
	dir, srv, dsn, err := bootCluster(true)
	if err != nil {
		return "", "", err
	}
	// Reap the child the moment it exits, whatever the caller's own
	// lifetime looks like. cmd/boot's process exits right after this
	// function returns, so on that path the postgres child is reparented to
	// init and reaped automatically anyway — but a caller that stays alive
	// longer (e.g. a test invoking BootStandalone directly, in-process)
	// would otherwise leave an exited child as an unreaped zombie, which
	// still answers `kill -0` as "running". stop.sh below polls exactly
	// that, so an unreaped zombie makes it wait out its full ~10s timeout
	// on every stop instead of noticing the shutdown immediately.
	go func() { _, _ = srv.Process.Wait() }()
	script := filepath.Join(dir, "stop.sh")
	contents := fmt.Sprintf("#!/bin/sh\nkill -QUIT %d 2>/dev/null\nfor i in $(seq 1 100); do kill -0 %d 2>/dev/null || break; sleep 0.1; done\nrm -rf %s\n",
		srv.Process.Pid, srv.Process.Pid, dir)
	if err := os.WriteFile(script, []byte(contents), 0o700); err != nil {
		// The server is already running and detached at this point (that's
		// the whole point of bootCluster(true)) — without an explicit kill
		// here, a WriteFile failure (e.g. disk full) would leak it running
		// forever with nothing left holding a reference to stop it. The
		// reaper goroutine above already owns the Wait(); calling it again
		// here would race that goroutine for no benefit, since both discard
		// the result anyway.
		_ = srv.Process.Kill()
		_ = os.RemoveAll(dir)
		return "", "", fmt.Errorf("write stop script: %w", err)
	}
	return dsn, script, nil
}

// bootCluster does the actual initdb + postgres start shared by boot() and
// BootStandalone; detach controls whether the server process is placed in
// its own session (required when the caller is a short-lived `go run`
// process that must not take the server down with it on exit).
func bootCluster(detach bool) (dir string, srv *exec.Cmd, dsn string, err error) {
	binDir, err := postgresBinDir()
	if err != nil {
		return "", nil, "", err
	}
	dir, err = os.MkdirTemp("", "pgtest-")
	if err != nil {
		return "", nil, "", err
	}
	// From here on, dir exists on disk. Every early return below on error
	// must not leak it — found by literally forcing one of these paths
	// (HASALA_TEST_PG_USER pointed at a nonexistent user) and finding a
	// stray /tmp/pgtest-* directory afterward, which is exactly the kind of
	// leak that only shows up after enough failed/flaky boots accumulate.
	//
	// bootDir, not dir, is what the cleanup defer below closes over: dir is
	// this function's named return value, and every early "return "", nil,
	// "", err" below assigns "" to it before the deferred function runs —
	// os.RemoveAll(dir) at that point would silently remove nothing. A
	// plain local variable can't be reassigned out from under the defer by
	// a return statement, so it stays correct.
	bootDir := dir
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(bootDir)
		}
	}()
	data := filepath.Join(dir, "data")
	cred, err := unprivileged()
	if err != nil {
		return "", nil, "", err
	}
	if cred != nil {
		// initdb refuses to run as root; the whole tree must be owned by the
		// unprivileged user that will own the server process.
		if err := os.Chown(dir, int(cred.Uid), int(cred.Gid)); err != nil {
			return "", nil, "", err
		}
	}
	// cmd returns a fresh, never-yet-run *exec.Cmd with no Stdout/Stderr set.
	// That matters: exec.Cmd.CombinedOutput panics with "exec: Stdout already
	// set" if either stream is already assigned, so the one-shot initdb call
	// below (which wants captured output) and the long-running postgres
	// process (which wants to stream to os.Stderr) each set the streams
	// exactly once, on their own Cmd, and never reuse a Cmd across the two.
	cmd := func(name string, args ...string) *exec.Cmd {
		c := exec.Command(filepath.Join(binDir, name), args...)
		if cred != nil || detach {
			attr := &syscall.SysProcAttr{}
			if cred != nil {
				attr.Credential = cred
			}
			if detach {
				attr.Setsid = true
			}
			c.SysProcAttr = attr
		}
		return c
	}
	// --locale=C.UTF-8 matches the production cluster (Task D5), not the
	// initdb default. If this is ever changed to --locale=C for expediency,
	// note it here: `C` collates byte-wise and does not match the
	// linguistic/case-folding behavior C.UTF-8 gives production, so
	// ORDER BY, LIKE and index usability on text columns could diverge
	// between test and prod. Do not make that change silently.
	if out, err := cmd("initdb", "-D", data, "-U", "postgres", "-A", "trust",
		"--encoding=UTF8", "--locale=C.UTF-8").CombinedOutput(); err != nil {
		return "", nil, "", fmt.Errorf("initdb: %v: %s", err, out)
	}
	// 5433 is hardcoded and reused by every cluster this package boots,
	// concurrently or not: listen_addresses="" (below) means postgres never
	// binds a TCP port at all, so "port" only names the unix socket file
	// (.s.PGSQL.5433) inside this cluster's own -k dir. Two clusters in two
	// different temp dirs using the same number don't collide — there is no
	// shared namespace to collide in.
	port := 5433
	srv = cmd("postgres", "-D", data, "-k", dir, "-p", strconv.Itoa(port),
		"-c", "listen_addresses=", "-c", "fsync=off", "-c", "full_page_writes=off",
		"-c", "synchronous_commit=off")
	srv.Stdout, srv.Stderr = os.Stderr, os.Stderr // long-running: stream, never capture
	if err := srv.Start(); err != nil {
		return "", nil, "", err
	}
	dsn = fmt.Sprintf("postgres://postgres@/postgres?host=%s&port=%d&sslmode=disable", dir, port)
	if err := waitReady(dsn); err != nil {
		_ = srv.Process.Kill()
		_, _ = srv.Process.Wait() // reap now: nothing else is going to
		return "", nil, "", err
	}
	ok = true
	return dir, srv, dsn, nil
}

// postgresBinDir returns the directory holding initdb and postgres.
//
// PATH comes first: the Hasala devShell (flake.nix) puts postgresql_17 there,
// and so does Homebrew when its postgresql bin directory is on PATH. initdb
// and postgres must sit side by side, because bootCluster runs both from one
// directory; a symlink farm that links only initdb is resolved to the real
// install directory. Debian keeps the server binaries off PATH, under
// /usr/lib/postgresql/<major>/bin, so that remains the fallback ledgerd had.
func postgresBinDir() (string, error) {
	hasPostgres := func(dir string) bool {
		_, err := os.Stat(filepath.Join(dir, "postgres"))
		return err == nil
	}
	if dir := os.Getenv("HASALA_TEST_PG_BINDIR"); dir != "" {
		if hasPostgres(dir) {
			return dir, nil
		}
		return "", fmt.Errorf("HASALA_TEST_PG_BINDIR=%s holds no postgres binary", dir)
	}
	if initdb, err := exec.LookPath("initdb"); err == nil {
		if dir := filepath.Dir(initdb); hasPostgres(dir) {
			return dir, nil
		}
		if real, err := filepath.EvalSymlinks(initdb); err == nil {
			if dir := filepath.Dir(real); hasPostgres(dir) {
				return dir, nil
			}
		}
	}
	if bin, err := filepath.Glob("/usr/lib/postgresql/*/bin/initdb"); err == nil && len(bin) > 0 {
		return filepath.Dir(bin[len(bin)-1]), nil
	}
	return "", fmt.Errorf("initdb (with postgres beside it) not found on PATH or under /usr/lib/postgresql; " +
		"run inside the devShell: `direnv exec . <cmd>` or `nix develop`")
}

// unprivileged returns the credential to run the server under, or nil when
// this process is already unprivileged.
func unprivileged() (*syscall.Credential, error) {
	if os.Geteuid() != 0 {
		return nil, nil
	}
	name := os.Getenv("HASALA_TEST_PG_USER")
	if name == "" {
		name = "nobody"
	}
	u, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("lookup %q: %w", name, err)
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	return &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}, nil
}

func waitReady(dsn string) error {
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		pool, err := pgxpool.New(context.Background(), dsn)
		if err == nil {
			if err = pool.Ping(context.Background()); err == nil {
				pool.Close()
				return nil
			}
			pool.Close()
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("postgres did not become ready")
}
