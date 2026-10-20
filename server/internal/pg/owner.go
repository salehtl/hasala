package pg

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Role names (spec 02 §3.1, §5.2). hasala_migrate owns the schema and runs
// `hasalad migrate`; hasala_runtime serves, with DML only.
const (
	RoleMigrate = "hasala_migrate"
	RoleRuntime = "hasala_runtime"
)

// SealedFunctionMD5 is md5(prosrc) of hasala_frame_is_sealed exactly as the
// baseline defines it (spec 01 §8.2, V-F). Startup check O7 compares the live
// function's body with it, so a schema owner who replaces the predicate with
// `SELECT true` is caught at the next start. A test pins it against the
// migration file.
const SealedFunctionMD5 = "cecad4a55664c960ee9e1e301a76c30d"

type SealedConstraint struct {
	Name string
	Def  string
}

var SealedConstraints = []SealedConstraint{
	{"op_log_blob_is_sealed", "CHECK (hasala_frame_is_sealed(blob))"},
	{"op_log_aad_matches_position", "CHECK (\nCASE\n    WHEN (octet_length(blob) < 7) THEN false\n" +
		"    ELSE (SUBSTRING(blob FROM 8 FOR ((get_byte(blob, 5) * 256) + get_byte(blob, 6))) = " +
		"convert_to((((((((user_id)::text || '|'::text) || stream) || '|'::text) || writer_id) || '|'::text) || " +
		"(writer_counter)::text), 'UTF8'::name))\nEND)"},
	{"op_log_stream_is_hot", "CHECK ((stream = 'hot'::text))"},
}

// RefusalError is a failed startup check. Code names the check (O1…O8) so the
// one ERROR line an operator sees says which rule refused; cmd/hasalad exits 2
// on it.
type RefusalError struct {
	Code   string
	Reason string
}

func (e *RefusalError) Error() string { return "startup refused (" + e.Code + "): " + e.Reason }

// IsRefusal reports whether err is a startup refusal.
func IsRefusal(err error) bool {
	var r *RefusalError
	return errors.As(err, &r)
}

func refuse(code, format string, args ...any) error {
	return &RefusalError{Code: code, Reason: fmt.Sprintf(format, args...)}
}

// CheckServing runs spec 02 §5.6's startup refusals O1–O8 for a pool that is
// about to serve (serve, console and every CLI mode except migrate). It
// refuses to run as a superuser, as the schema owner or a member of it, behind
// the embedded migrations, without the sealed-frame CHECKs validated, with
// DELETE on op_log, with a replaced predicate body, or with a nullable blob
// column. O9 (the auth_key fingerprint) arrives with internal/authkeys (WS-3)
// and O10 (admin_audit) with spec 07's tables.
//
// A database AHEAD of the binary is allowed (expand-only migrations, spec 02
// §5.5): warn is called with both versions and the check passes, so a binary
// rollback works.
func CheckServing(ctx context.Context, pool *pgxpool.Pool, warn func(string)) error {
	var user string
	var super bool
	if err := pool.QueryRow(ctx,
		`SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&user, &super); err != nil {
		return fmt.Errorf("pg: read the connected role: %w", err)
	}
	// O1
	if super {
		return refuse("O1", "connected as %s, a superuser; serve as %s", user, RoleRuntime)
	}
	// O2
	var owned []string
	rows, err := pool.Query(ctx, `SELECT tablename FROM pg_tables
		 WHERE schemaname = 'public' AND tablename IN ('op_log','key_history','writers')
		   AND tableowner = current_user ORDER BY tablename`)
	if err != nil {
		return fmt.Errorf("pg: read table owners: %w", err)
	}
	owned, err = pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("pg: read table owners: %w", err)
	}
	if len(owned) > 0 {
		return refuse("O2", "connected as %s, which owns %v: the schema owner can disable the append-only "+
			"triggers and rewrite history; serve as %s", user, owned, RoleRuntime)
	}
	// O3
	var member bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)
		   AND pg_has_role(current_user, $1, 'MEMBER')`, RoleMigrate).Scan(&member); err != nil {
		return fmt.Errorf("pg: read role membership: %w", err)
	}
	if member {
		return refuse("O3", "connected as %s, which is a member of %s", user, RoleMigrate)
	}
	// O4
	applied, err := AppliedVersion(ctx, pool)
	if err != nil {
		return err
	}
	latest, err := LatestEmbedded()
	if err != nil {
		return err
	}
	if applied < latest {
		return refuse("O4", "the database is at migration %d and this binary needs %d: run `hasalad migrate` first",
			applied, latest)
	}
	if applied > latest && warn != nil {
		warn(fmt.Sprintf("the database is at migration %d, ahead of this binary's %d (expand-only rollback)", applied, latest))
	}
	// O5
	for _, want := range SealedConstraints {
		var validated *bool
		var def *string
		err := pool.QueryRow(ctx, `SELECT c.convalidated, pg_get_constraintdef(c.oid) FROM pg_constraint c
			 JOIN pg_class t ON t.oid = c.conrelid
			WHERE c.conname = $1 AND c.contype = 'c' AND t.relname = 'op_log'
			  AND t.relnamespace = 'public'::regnamespace`, want.Name).Scan(&validated, &def)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (validated == nil || !*validated)) {
			return refuse("O5", "op_log constraint %s is missing or NOT VALID", want.Name)
		}
		if err != nil {
			return fmt.Errorf("pg: read constraint %s: %w", want.Name, err)
		}
		if def == nil || *def != want.Def {
			return refuse("O5", "op_log constraint %s has been replaced with a different definition", want.Name)
		}
	}
	// O6
	var canDelete bool
	if err := pool.QueryRow(ctx,
		`SELECT has_table_privilege(current_user, 'public.op_log', 'DELETE')`).Scan(&canDelete); err != nil {
		return fmt.Errorf("pg: read op_log privileges: %w", err)
	}
	if canDelete {
		return refuse("O6", "%s may DELETE from op_log: the runtime grants were widened", user)
	}
	// O7
	var sum *string
	err = pool.QueryRow(ctx, `SELECT md5(prosrc) FROM pg_proc
		 WHERE proname = 'hasala_frame_is_sealed' AND pronamespace = 'public'::regnamespace`).Scan(&sum)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && sum == nil) {
		return refuse("O7", "the function hasala_frame_is_sealed is missing")
	}
	if err != nil {
		return fmt.Errorf("pg: read hasala_frame_is_sealed: %w", err)
	}
	if *sum != SealedFunctionMD5 {
		return refuse("O7", "hasala_frame_is_sealed has been replaced (md5 %s, want %s)", *sum, SealedFunctionMD5)
	}
	// O8
	var notNull int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
		 WHERE table_schema = 'public' AND table_name = 'op_log'
		   AND column_name = 'blob' AND is_nullable = 'NO'`).Scan(&notNull); err != nil {
		return fmt.Errorf("pg: read op_log.blob: %w", err)
	}
	if notNull != 1 {
		return refuse("O8", "op_log.blob is nullable: the STRICT predicate passes NULL, so NOT NULL is part of the guarantee")
	}
	return nil
}

// CheckMigrator refuses a migrate connection that is not hasala_migrate (spec
// 02 §5.5).
func CheckMigrator(ctx context.Context, pool *pgxpool.Pool) error {
	var user string
	if err := pool.QueryRow(ctx, `SELECT current_user`).Scan(&user); err != nil {
		return fmt.Errorf("pg: read the connected role: %w", err)
	}
	if user != RoleMigrate {
		return refuse("M1", "migrate is connected as %s; it runs only as %s", user, RoleMigrate)
	}
	return nil
}

// MigrateLocked applies the embedded migrations (up to `to` when positive)
// under the session advisory lock hashtext('hasala/migrate'), so two migrate
// runs cannot interleave.
func MigrateLocked(ctx context.Context, pool *pgxpool.Pool, to int64) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(hashtext('hasala/migrate'))`); err != nil {
		return fmt.Errorf("pg: take the migrate lock: %w", err)
	}
	defer func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(hashtext('hasala/migrate'))`)
	}()
	if to > 0 {
		return MigrateTo(ctx, pool, to)
	}
	return Migrate(ctx, pool)
}
