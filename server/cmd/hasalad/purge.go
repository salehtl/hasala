package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/purge"
)

// runPurgeUser is `hasalad purge-user <uuid> --confirm <uuid> [--dry-run]`
// (spec 02 §15.4): delete one account and everything that references it. The
// account id must be typed twice, so a pasted id that is one character off
// deletes nothing. (The purge ledger and `--replay-ledger` of spec 02 §15.5
// arrive with WS-5's restore runbook.)
func runPurgeUser(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var a config.PurgeArgs
	fs := newFlags(env, "purge-user")
	fs.StringVar(&a.Confirm, "confirm", "", "the same account id again")
	fs.BoolVar(&a.DryRun, "dry-run", false, "report what would be deleted and delete nothing")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 1 || fs.NArg() > 0 {
		return refusal{errors.New("usage: hasalad purge-user <uuid> --confirm <uuid> [--dry-run]")}
	}
	a.User = positional[0]
	target, err := uuid.Parse(a.User)
	if err != nil || target == uuid.Nil {
		return refusal{fmt.Errorf("purge-user: %q is not an account id", a.User)}
	}
	if a.Confirm != a.User {
		return refusal{errors.New("purge-user: --confirm must repeat the account id exactly")}
	}
	cfg, err := env.load("purge-user", func(c *config.Config) { c.Purge = a })
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	if a.DryRun {
		c, err := purge.Classify(ctx, pool)
		if err != nil {
			return err
		}
		if len(c.Unclassified) != 0 {
			return fmt.Errorf("purge-user: a real purge would REFUSE: unclassified relations %v", c.Unclassified)
		}
		if err := dryRunCascades(ctx, pool, c.UserScoped); err != nil {
			return err
		}
		total := 0
		for _, r := range c.UserScoped {
			var n int
			if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+r.SQL()+` WHERE user_id = $1`, target).Scan(&n); err != nil {
				return fmt.Errorf("purge-user: count %s: %w", r, err)
			}
			if n > 0 && r.Kind == 'm' {
				var canRefresh bool
				if err := pool.QueryRow(ctx,
					`SELECT pg_has_role(current_user, c.relowner, 'USAGE') OR has_table_privilege(current_user, c.oid, 'MAINTAIN')
					   FROM pg_class c WHERE c.oid = $1::regclass`, r.SQL()).Scan(&canRefresh); err != nil {
					return fmt.Errorf("purge-user: read %s: %w", r, err)
				}
				if !canRefresh {
					return fmt.Errorf("purge-user: a real purge would REFUSE: materialized view %s holds %d rows "+
						"of the account and this role cannot refresh it", r, n)
				}
			}
			if n > 0 {
				fmt.Fprintf(env.stdout, "  %-40s %d\n", r, n)
			}
			total += n
		}
		fmt.Fprintf(env.stdout, "dry run: %d row(s) of account %s would be deleted, and the goodbye email queued "+
			"to its address. Nothing was deleted.\n", total, target)
		return nil
	}
	// The CLI holds no auth key, so the tag-keyed steps are skipped; the
	// goodbye email is queued like the API's, and serve's worker sends it
	// (spec 02 §15.4).
	rep, err := purge.PurgeWith(ctx, pool, target, purge.Options{Goodbye: true})
	printPurgeReport(env, rep)
	if err != nil {
		return fmt.Errorf("purge-user: %w", err)
	}
	if len(rep.Users) == 0 {
		fmt.Fprintln(env.stdout, "no such account; nothing was deleted")
	}
	return nil
}

func dryRunCascades(ctx context.Context, pool *pgxpool.Pool, rels []purge.Relation) error {
	rows, err := pool.Query(ctx, `
		SELECT ns.nspname || '.' || cl.relname, con.confdeltype::text
		  FROM pg_constraint con
		  JOIN pg_class cl ON cl.oid = con.conrelid
		  JOIN pg_namespace ns ON ns.oid = cl.relnamespace
		 WHERE con.contype = 'f'
		   AND con.confrelid = 'public.users'::regclass
		   AND con.confdeltype <> 'c'
		   AND EXISTS (
		       SELECT 1 FROM pg_attribute a
		        WHERE a.attrelid = con.conrelid
		          AND a.attnum = ANY (con.conkey)
		          AND a.attname = 'user_id')
		 ORDER BY 1, 2`)
	if err != nil {
		return fmt.Errorf("purge-user: read foreign-key actions: %w", err)
	}
	defer rows.Close()
	names := map[string]string{"a": "NO ACTION", "r": "RESTRICT", "n": "SET NULL", "d": "SET DEFAULT"}
	for rows.Next() {
		var rel, action string
		if err := rows.Scan(&rel, &action); err != nil {
			return fmt.Errorf("purge-user: read foreign-key actions: %w", err)
		}
		if !slices.ContainsFunc(rels, func(r purge.Relation) bool { return r.String() == rel }) {
			continue
		}
		name, ok := names[action]
		if !ok {
			name = fmt.Sprintf("confdeltype %q", action)
		}
		return fmt.Errorf("purge-user: a real purge would REFUSE: %s.user_id references users ON DELETE %s, not CASCADE",
			rel, name)
	}
	return rows.Err()
}

func printPurgeReport(env *runEnv, rep purge.Report) {
	for _, u := range rep.Users {
		fmt.Fprintf(env.stdout, "purged account %s\n", u)
	}
	tables := make([]string, 0, len(rep.Rows))
	for t := range rep.Rows {
		tables = append(tables, t)
	}
	sort.Strings(tables)
	for _, t := range tables {
		if rep.Rows[t] > 0 {
			fmt.Fprintf(env.stdout, "  %-40s %d\n", t, rep.Rows[t])
		}
	}
	if len(rep.SweptWithoutCascade) > 0 {
		fmt.Fprintf(env.stdout, "WARNING: these tables needed an explicit sweep because their user_id "+
			"foreign key is missing ON DELETE CASCADE: %v\n", rep.SweptWithoutCascade)
	}
	if rep.Goodbyes > 0 {
		fmt.Fprintln(env.stdout, "queued the goodbye email to the account's address (sent by serve's email worker)")
	}
	if len(rep.RefreshedViews) > 0 {
		fmt.Fprintf(env.stdout, "WARNING: these MATERIALIZED VIEWS held rows for the purged account and had "+
			"to be refreshed: %v\n", rep.RefreshedViews)
	}
}
