package main

import (
	"context"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestPurgeDryRunRunsTheRealPreflight(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		setup []string
		wants []string
	}{
		{
			name: "set null",
			setup: []string{
				`CREATE TABLE later_task_rows (id bigserial PRIMARY KEY,
				   user_id uuid REFERENCES users(id) ON DELETE SET NULL, note text NOT NULL)`,
				`GRANT SELECT, INSERT, DELETE ON later_task_rows TO hasala_runtime`,
				`INSERT INTO later_task_rows (user_id, note) SELECT id, 'x' FROM users`,
			},
			wants: []string{"later_task_rows", "SET NULL"},
		},
		{
			name: "restrict",
			setup: []string{
				`CREATE TABLE later_task_rows (id bigserial PRIMARY KEY,
				   user_id uuid REFERENCES users(id) ON DELETE RESTRICT, note text NOT NULL)`,
				`GRANT SELECT, INSERT, DELETE ON later_task_rows TO hasala_runtime`,
			},
			wants: []string{"later_task_rows", "RESTRICT"},
		},
		{
			name: "matview",
			setup: []string{
				`CREATE MATERIALIZED VIEW user_copy AS SELECT id AS user_id FROM users`,
				`GRANT SELECT ON user_copy TO hasala_runtime`,
			},
			wants: []string{"user_copy", "materialized view"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pool, owner := pgtest.NewWithOwner(t)
			user := oplogtest.NewUser(t, pool).String()
			for _, sql := range c.setup {
				if _, err := owner.Exec(ctx, sql); err != nil {
					t.Fatalf("%s: %v", sql, err)
				}
			}
			env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString()}
			code, out, msg := hasalad(t, env, "purge-user", user, "--confirm", user, "--dry-run")
			if code == 0 || strings.Contains(out, "Nothing was deleted") {
				t.Fatalf("dry run exited %d with %q (%s), want a refusal", code, out, msg)
			}
			for _, w := range c.wants {
				if !strings.Contains(msg, w) {
					t.Fatalf("dry run message %q does not name %q", msg, w)
				}
			}
			code, _, realMsg := hasalad(t, env, "purge-user", user, "--confirm", user)
			if code == 0 {
				t.Fatalf("the real purge succeeded where the dry run refused (%s)", realMsg)
			}
			var left int
			if err := pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = $1`, user).Scan(&left); err != nil || left != 1 {
				t.Fatalf("%d accounts left (%v), want 1", left, err)
			}
		})
	}
}

func TestPurgeDryRunPassesWhenTheRealPurgeWould(t *testing.T) {
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool).String()
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString()}
	if code, out, msg := hasalad(t, env, "purge-user", user, "--confirm", user, "--dry-run"); code != 0 ||
		!strings.Contains(out, "Nothing was deleted") {
		t.Fatalf("dry run exited %d with %q (%s)", code, out, msg)
	}
}
