package main

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/purge"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// runPurgeUser is `hasalad purge-user <uuid> --confirm <uuid> [--dry-run]`
// (spec 02 §15.4): delete one account and everything that references it. The
// account id must be typed twice, so a pasted id that is one character off
// deletes nothing. `hasalad purge-user --replay-ledger` (spec 02 §15.5)
// purges again every account the purge ledger names.
func runPurgeUser(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var a config.PurgeArgs
	fs := newFlags(env, "purge-user")
	fs.StringVar(&a.Confirm, "confirm", "", "the same account id again")
	fs.BoolVar(&a.DryRun, "dry-run", false, "report what would be deleted and delete nothing")
	fs.BoolVar(&a.ReplayLedger, "replay-ledger", false, "purge again every account in the purge ledger (after a restore)")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if a.ReplayLedger {
		if len(positional) != 0 || fs.NArg() > 0 || a.Confirm != "" || a.DryRun {
			return refusal{errors.New("usage: hasalad purge-user --replay-ledger")}
		}
		return replayPurgeLedger(env, a)
	}
	if len(positional) != 1 || fs.NArg() > 0 {
		return refusal{errors.New("usage: hasalad purge-user <uuid> --confirm <uuid> [--dry-run] | purge-user --replay-ledger")}
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
		if err := purge.CheckCascades(ctx, pool, c.UserScoped); err != nil {
			return fmt.Errorf("purge-user: a real purge would REFUSE: %w", err)
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
	opts := purge.Options{Goodbye: true}
	if p := cfg.Server.PurgeLedgerPath; p != "" {
		opts.Record = func(ids []uuid.UUID) error { return purgeledger.Append(p, ids, time.Now()) }
		opts.Cancel = func(ids []uuid.UUID) error { return purgeledger.AppendCancelled(p, ids, time.Now()) }
	} else {
		fmt.Fprintln(env.stderr, "purge-user: warning: HASALA_PURGE_LEDGER_PATH is not set, so restoring a backup would bring this account back")
	}
	rep, err := purge.PurgeWith(ctx, pool, target, opts)
	if errors.Is(err, purge.ErrUnsettled) {
		fmt.Fprintln(env.stderr, "purge-user: the deletion did not finish and the ledger may still name this account: "+
			"check whether it still exists, because a replay that reads such a line deletes it")
		return fmt.Errorf("purge-user: %w", err)
	}
	if err != nil {
		fmt.Fprintln(env.stderr, "purge-user: the purge did not complete: nothing was deleted and no email was queued")
		return fmt.Errorf("purge-user: %w", err)
	}
	printPurgeReport(env, rep)
	if len(rep.Users) == 0 {
		fmt.Fprintln(env.stdout, "no such account; nothing was deleted")
	}
	return nil
}

func replayPurgeLedger(env *runEnv, a config.PurgeArgs) error {
	cfg, err := env.load("purge-user", func(c *config.Config) { c.Purge = a })
	if err != nil {
		return err
	}
	path := cfg.Server.PurgeLedgerPath
	entries, err := purgeledger.Read(path)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	rep, err := purge.Replay(ctx, pool, purgeledger.IDs(entries))
	if err != nil {
		return fmt.Errorf("purge-user --replay-ledger: %w", err)
	}
	again, err := auth.Reapply(ctx, pool, entries, time.Now())
	if err != nil {
		return fmt.Errorf("purge-user --replay-ledger: %w", err)
	}
	left, err := waitlist.ReapplyLeaves(ctx, pool, entries)
	if err != nil {
		return fmt.Errorf("purge-user --replay-ledger: %w", err)
	}
	bounced, err := waitlist.ReapplyUnsent(ctx, pool, entries)
	if err != nil {
		return fmt.Errorf("purge-user --replay-ledger: %w", err)
	}
	revoked, err := invites.ReapplyRevocations(ctx, pool, entries)
	if err != nil {
		return fmt.Errorf("purge-user --replay-ledger: %w", err)
	}
	dropped, err := purgeledger.Prune(path, time.Now().Add(-purgeledger.Retention))
	if err != nil {
		return err
	}
	fmt.Fprintf(env.stdout, "purge ledger: %d entries, %d account(s) purged again (%d rows), %d freeze(s), %d unfreeze(s), "+
		"%d device removal(s), %d password change(s), %d passkey removal(s), %d first view(s) of the 12 words, %d waitlist leave(s) and %d bounced-invite waitlist "+
		"deletion(s) applied again, %d sign-out(s) of all sessions, %d email change(s) and %d invite revocation(s) applied again, "+
		"%d freeze(s) lifted because the replay left the account no passkey and no password, "+
		"%d device removal(s) whose signer is not in the database (signed out only), %d entries past retention removed\n",
		len(entries), len(rep.Users), rep.Total(), again.Freezes, again.Unfreezes, again.Devices, again.Passwords, again.Passkeys,
		again.PhrasesSeen, left, bounced, again.Sessions, again.Emails, revoked, again.Lifted, again.Unsigned, dropped)
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
	if rep.Goodbyes > 0 {
		fmt.Fprintln(env.stdout, "queued the goodbye email to the account's address (sent by serve's email worker)")
	}
	if len(rep.RefreshedViews) > 0 {
		fmt.Fprintf(env.stdout, "WARNING: these MATERIALIZED VIEWS held rows for the purged account and had "+
			"to be refreshed: %v\n", rep.RefreshedViews)
	}
}
