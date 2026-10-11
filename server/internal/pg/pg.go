// Package pg owns the Postgres connection pool, the embedded migration set
// (one baseline, spec 02 §5.3), the migration runner behind `hasalad migrate`
// (spec 02 §5.5) and the startup refusals every serving mode runs
// (owner.go, spec 02 §5.6).
package pg

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

// gooseMu serializes every call into goose. SetDialect and SetBaseFS mutate
// unsynchronized package-level globals in the vendored goose source
// (var store in dialect.go, var baseFS in goose.go), which UpContext and
// DownToContext then read while running — goose was never written to be
// called concurrently. Every caller here sets the same dialect ("postgres")
// and the same embedded FS, so the values never actually disagree, but an
// unsynchronized concurrent read/write of the same memory is a data race
// regardless of whether the values agree, and go test -race reports it as
// one. This harness exists specifically so ~20 v2 packages can test
// concurrently (including via t.Parallel() within a package), so this global
// state gets exercised concurrently as soon as any test uses it that way.
var gooseMu sync.Mutex

// Open creates a pool with conservative limits: this process is the only
// writer, and a beta-scale user count needs far fewer connections than the
// server's default 100.
func Open(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.MaxConns = 16
	cfg.MinConns = 2
	return pgxpool.NewWithConfig(ctx, cfg)
}

// Migrate applies every embedded migration. Idempotent.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	return goose.UpContext(ctx, db, "migrations")
}

// MigrateTo applies migrations up to and including version, leaving anything
// later unapplied.
//
// It exists for one reason: a migration that BACKFILLS can only be observed
// against rows that existed before it ran, and Migrate applies the whole set in
// one call, so by the time a test can insert anything the backfill has already
// happened over an empty database. MigrateTo lets a test stop one version
// short, seed, and then step forward — which is the only way the backfill in
// 00031_account_budgets.sql is exercised by anything other than production.
func MigrateTo(ctx context.Context, pool *pgxpool.Pool, version int64) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	return goose.UpToContext(ctx, db, "migrations", version)
}

// MigrateDown reverses every migration. Used only by tests; a Down block that
// nobody runs is a rollback that does not work.
func MigrateDown(ctx context.Context, pool *pgxpool.Pool) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	return goose.DownToContext(ctx, db, "migrations", 0)
}

// EmbeddedVersions returns the version of every embedded migration, ascending.
func EmbeddedVersions() ([]int64, error) {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	ms, err := goose.CollectMigrations("migrations", 0, goose.MaxVersion)
	if err != nil {
		return nil, err
	}
	out := make([]int64, len(ms))
	for i, m := range ms {
		out[i] = m.Version
	}
	return out, nil
}

// LatestEmbedded is the highest embedded migration version.
func LatestEmbedded() (int64, error) {
	vs, err := EmbeddedVersions()
	if err != nil {
		return 0, err
	}
	if len(vs) == 0 {
		return 0, errors.New("pg: no embedded migrations")
	}
	return vs[len(vs)-1], nil
}

// AppliedVersion is the highest applied migration, or 0 when goose_db_version
// does not exist yet (a fresh database). It needs only SELECT on
// goose_db_version, so the runtime and backup roles can call it.
func AppliedVersion(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	// Through the catalog rather than to_regclass: a role without USAGE on
	// the schema (the runtime role before the baseline grants it) gets
	// "permission denied" from to_regclass, where the answer is "not yet".
	var exists bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
		JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public' AND c.relname = 'goose_db_version')`).Scan(&exists); err != nil {
		return 0, fmt.Errorf("pg: look for goose_db_version: %w", err)
	}
	if !exists {
		return 0, nil
	}
	var v *int64
	if err := pool.QueryRow(ctx,
		`SELECT max(version_id) FROM goose_db_version WHERE is_applied`).Scan(&v); err != nil {
		return 0, fmt.Errorf("pg: read goose_db_version: %w", err)
	}
	if v == nil {
		return 0, nil
	}
	return *v, nil
}

// Pending counts the embedded migrations not yet applied (spec 02 §5.5
// --pending): 0 for a fresh database's absent ledger means "nothing to back
// up", not "nothing to apply", so it counts against AppliedVersion = 0.
func Pending(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	applied, err := AppliedVersion(ctx, pool)
	if err != nil {
		return 0, err
	}
	// Through the catalog rather than to_regclass: a role without USAGE on
	// the schema (the runtime role before the baseline grants it) gets
	// "permission denied" from to_regclass, where the answer is "not yet".
	var exists bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
		JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public' AND c.relname = 'goose_db_version')`).Scan(&exists); err != nil {
		return 0, err
	}
	if !exists {
		return 0, nil
	}
	vs, err := EmbeddedVersions()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, v := range vs {
		if v > applied {
			n++
		}
	}
	return n, nil
}
