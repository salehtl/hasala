package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
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
			code, realOut, realMsg := hasalad(t, env, "purge-user", user, "--confirm", user)
			if code == 0 {
				t.Fatalf("the real purge succeeded where the dry run refused (%s)", realMsg)
			}
			if strings.Contains(realOut, "purged account") || strings.Contains(realOut, "queued the goodbye") ||
				!strings.Contains(realMsg, "nothing was deleted and no email was queued") {
				t.Fatalf("a refused purge reported %q (%s)", realOut, realMsg)
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

func TestAPurgeSurvivesARestoreThroughTheLedger(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	user := oplogtest.NewUser(t, pool)
	stays := oplogtest.NewUser(t, pool)
	ledger := filepath.Join(t.TempDir(), "purged")
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}
	if code, out, msg := hasalad(t, env, "purge-user", user.String(), "--confirm", user.String()); code != 0 {
		t.Fatalf("purge exited %d: %s %s", code, out, msg)
	}
	entries, err := purgeledger.Read(ledger)
	if err != nil || len(entries) != 1 || entries[0].ID != user {
		t.Fatalf("ledger %v %v, want the purged account", entries, err)
	}

	if _, err := pool.Exec(ctx, `INSERT INTO users (id, user_handle, created_at, email_norm, email_verified_at, display_name)
	    VALUES ($1::uuid, sha256(convert_to($1::uuid::text, 'UTF8')), now(), 'restored@example.test', now(), 'Test User')`, user); err != nil {
		t.Fatal(err)
	}
	code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger")
	if code != 0 || !strings.Contains(out, "1 entries, 1 account(s) purged again") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	if strings.Contains(out, user.String()) {
		t.Fatalf("the replay printed the account id: %q", out)
	}
	var left int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = $1`, user).Scan(&left); err != nil || left != 0 {
		t.Fatalf("%d restored accounts left (%v), want 0", left, err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = $1`, stays).Scan(&left); err != nil || left != 1 {
		t.Fatalf("the other account: %d (%v), want 1", left, err)
	}
	if code, out, _ := hasalad(t, env, "purge-user", "--replay-ledger"); code != 0 || !strings.Contains(out, "0 account(s) purged again") {
		t.Fatalf("a second replay exited %d with %q", code, out)
	}
}

func TestReplayNeedsTheLedgerAndNoAccount(t *testing.T) {
	env := []string{"HASALA_PG_DSN=host=/nonexistent dbname=hasala"}
	if code, _, msg := hasalad(t, env, "purge-user", "--replay-ledger"); code != 2 || !strings.Contains(msg, "HASALA_PURGE_LEDGER_PATH") {
		t.Fatalf("replay without a ledger exited %d (%s)", code, msg)
	}
	id := "00000000-0000-4000-8000-000000000001"
	env = append(env, "HASALA_PURGE_LEDGER_PATH=/nonexistent/purged")
	for _, argv := range [][]string{{"purge-user", id, "--replay-ledger"}, {"purge-user", "--replay-ledger", "--dry-run"},
		{"purge-user", "--replay-ledger", "--confirm", id}} {
		if code, _, _ := hasalad(t, env, argv...); code != 2 {
			t.Fatalf("%v exited %d, want 2", argv, code)
		}
	}
}

func TestReplayAppliesEveryRecordedEventAgain(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	gone := oplogtest.NewUser(t, pool)
	changed := oplogtest.NewUser(t, pool)
	frozen := oplogtest.NewUser(t, pool)
	if _, err := pool.Exec(ctx, `UPDATE users SET password_hash = decode(repeat('11', 32), 'hex'), password_salt = decode(repeat('22', 16), 'hex'),
	    password_version = 1, password_set_at = now() - interval '2 days' WHERE id = $1`, changed); err != nil {
		t.Fatal(err)
	}
	var entry string
	if err := pool.QueryRow(ctx, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at, confirmed_at)
	    VALUES (decode(repeat('33', 32), 'hex'), 'left@example.test', 'confirmed', 'web', now(), now(), now()) RETURNING id::text`).
		Scan(&entry); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	ledger := filepath.Join(t.TempDir(), "purged")
	body := gone.String() + " " + at + "\n" +
		changed.String() + " " + at + " password\n" +
		frozen.String() + " " + at + " freeze " + at + "\n" +
		entry + " " + at + " waitlist-leave\n"
	if err := os.WriteFile(ledger, []byte(body), 0o640); err != nil {
		t.Fatal(err)
	}
	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "HASALA_PURGE_LEDGER_PATH=" + ledger}
	code, out, msg := hasalad(t, env, "purge-user", "--replay-ledger")
	if code != 0 || !strings.Contains(out, "4 entries, 1 account(s) purged again") ||
		!strings.Contains(out, "1 freeze(s), 0 device removal(s), 1 password change(s) and 1 waitlist leave(s) applied again") {
		t.Fatalf("replay exited %d with %q (%s)", code, out, msg)
	}
	for _, id := range []string{gone.String(), changed.String(), frozen.String(), entry} {
		if strings.Contains(out, id) {
			t.Fatalf("the replay printed an id: %q", out)
		}
	}
	var n int
	for q, want := range map[string]int{
		`SELECT count(*) FROM users WHERE id = '` + gone.String() + `'`:                                  0,
		`SELECT count(*) FROM users WHERE id = '` + changed.String() + `' AND password_hash IS NULL`:     1,
		`SELECT count(*) FROM users WHERE id = '` + frozen.String() + `' AND frozen_by = 'holder'`:       1,
		`SELECT count(*) FROM waitlist_entries WHERE id = '` + entry + `'`:                               0,
		`SELECT count(*) FROM users WHERE id IN ('` + changed.String() + `', '` + frozen.String() + `')`: 2,
	} {
		if err := pool.QueryRow(ctx, q).Scan(&n); err != nil || n != want {
			t.Fatalf("%s: %d (%v), want %d", q, n, err, want)
		}
	}
	code, out, _ = hasalad(t, env, "purge-user", "--replay-ledger")
	if code != 0 || !strings.Contains(out, "0 account(s) purged again") ||
		!strings.Contains(out, "0 freeze(s), 0 device removal(s), 0 password change(s) and 0 waitlist leave(s) applied again") {
		t.Fatalf("a second replay exited %d with %q", code, out)
	}
}
