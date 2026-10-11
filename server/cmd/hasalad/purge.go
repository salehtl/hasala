package main

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/google/uuid"

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
		total := 0
		for _, r := range c.UserScoped {
			var n int
			if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+r.SQL()+` WHERE user_id = $1`, target).Scan(&n); err != nil {
				return fmt.Errorf("purge-user: count %s: %w", r, err)
			}
			if n > 0 {
				fmt.Fprintf(env.stdout, "  %-40s %d\n", r, n)
			}
			total += n
		}
		fmt.Fprintf(env.stdout, "dry run: %d row(s) of account %s would be deleted. Nothing was deleted.\n", total, target)
		return nil
	}
	rep, err := purge.Purge(ctx, pool, target)
	printPurgeReport(env, rep)
	if err != nil {
		return fmt.Errorf("purge-user: %w", err)
	}
	if len(rep.Users) == 0 {
		fmt.Fprintln(env.stdout, "no such account; nothing was deleted")
	}
	return nil
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
	if len(rep.RefreshedViews) > 0 {
		fmt.Fprintf(env.stdout, "WARNING: these MATERIALIZED VIEWS held rows for the purged account and had "+
			"to be refreshed: %v\n", rep.RefreshedViews)
	}
}
