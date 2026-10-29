package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

// runInvite is spec 07 §14.3's invite CLI:
//
//	hasalad invite mint [--note TEXT] [--ttl 336h] [--review]   prints one code, once
//	hasalad invite mint --email ADDRESS [--note TEXT] [--ttl …]  queues an invite email; prints the id
//	hasalad invite list
//	hasalad invite revoke <id prefix, ≥ 8 hex>
//
// A printed code is stored only as a hash. An emailed invite's code is minted
// by the mail worker in `serve` at send time and never shown here: admin modes
// have no network (spec 05 §5.7). State-changing modes write admin_audit rows
// with actor cli:<operator>.
func runInvite(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var (
		note, email string
		ttl         time.Duration
		review      bool
	)
	fs := newFlags(env, "invite")
	fs.StringVar(&note, "note", "", "mint: the operator's own words about who this invite is for (never emailed)")
	fs.StringVar(&email, "email", "", "mint: queue an invite email to this address instead of printing a code")
	fs.DurationVar(&ttl, "ttl", invites.DefaultTTL, "mint: how long the invite stays redeemable (24h–720h)")
	fs.BoolVar(&review, "review", false, "mint: a Beta App Review invite (printed, unaddressed)")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	usageErr := refusal{errors.New("usage: hasalad invite mint [--note TEXT] [--ttl 336h] [--review | --email ADDRESS]" +
		" | hasalad invite list | hasalad invite revoke <id prefix>")}
	if len(positional) == 0 || fs.NArg() > 0 {
		return usageErr
	}
	action := positional[0]
	mintFlags := note != "" || email != "" || review || ttl != invites.DefaultTTL
	switch action {
	case "mint":
		if len(positional) != 1 {
			return usageErr
		}
		if review && email != "" {
			return refusal{errors.New("invite mint: --review and --email are exclusive: a review invite is never addressed")}
		}
		if err := invites.CheckTTL(ttl); err != nil {
			return refusal{err}
		}
		if err := invites.CheckNote(note); err != nil {
			return refusal{err}
		}
	case "list":
		if len(positional) != 1 || mintFlags {
			return refusal{errors.New("invite list takes no flags")}
		}
	case "revoke":
		if len(positional) != 2 || mintFlags {
			return usageErr
		}
	default:
		return usageErr
	}

	cfg, err := env.load("invite", nil)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	actor := adminActor(env)

	switch action {
	case "list":
		return listInvites(ctx, env, pool)
	case "revoke":
		var revoked uuid.UUID
		if err := withTx(ctx, pool, func(tx pgx.Tx) error {
			id, err := invites.Revoke(ctx, tx, positional[1], time.Now())
			if err != nil {
				if errors.Is(err, invites.ErrNoSuchInvite) || errors.Is(err, invites.ErrAmbiguous) {
					return refusal{err}
				}
				return err
			}
			if err := audit(ctx, tx, actor, "cli.invite_revoke", "invite", id.String(), nil); err != nil {
				return err
			}
			revoked = id
			return nil
		}); err != nil {
			return err
		}
		fmt.Fprintf(env.stdout, "revoked invite %s\n", invites.ShortID(revoked))
		p := cfg.Server.PurgeLedgerPath
		if p == "" {
			fmt.Fprintln(env.stderr, "invite revoke: warning: HASALA_PURGE_LEDGER_PATH is not set, "+
				"so restoring a backup would bring this invite back")
			return nil
		}
		e := purgeledger.Entry{ID: revoked, At: time.Now(), Kind: purgeledger.KindInviteRevoked}
		if err := purgeledger.AppendEntries(p, e); err != nil {
			return fmt.Errorf("invite revoke: the invite is revoked, but the restore ledger did not record it: %w", err)
		}
		return nil
	}
	if email != "" {
		// The CLI has no auth key and no mail token: the row is queued without a
		// tag, and serve's worker tags it, mints the code and sends.
		q := mailq.New(pool, nil, nil)
		return withTx(ctx, pool, func(tx pgx.Tx) error {
			id, err := invites.EnqueueEmailed(ctx, tx, q, email, note, ttl)
			if err != nil {
				return refusal{err}
			}
			if err := audit(ctx, tx, actor, "cli.invite_mint", "invite", id.String(), map[string]any{"email": true}); err != nil {
				return err
			}
			fmt.Fprintf(env.stdout, "queued invite %s\n", invites.ShortID(id))
			fmt.Fprintln(env.stderr, "the invite email is sent by `hasalad serve`; its code is minted at send and never shown here")
			return nil
		})
	}
	var code string
	err = withTx(ctx, pool, func(tx pgx.Tx) error {
		id, c, err := invites.MintPrinted(ctx, tx, note, ttl, review, time.Now())
		if err != nil {
			return err
		}
		code = c
		return audit(ctx, tx, actor, "cli.invite_mint", "invite", id.String(), map[string]any{"review": review})
	})
	if err != nil {
		return err
	}
	// The bare 24 characters, as ledgerd printed them (spec 07 §14.3:
	// unchanged behaviour); the app ignores hyphens either way.
	fmt.Fprintln(env.stdout, code)
	fmt.Fprintln(env.stderr, "this code is single use, gates ACCOUNT CREATION only, and is not "+
		"recoverable: it is stored as a hash. Hand it over out of band.")
	return nil
}

func listInvites(ctx context.Context, env *runEnv, pool *pgxpool.Pool) error {
	rows, err := invites.List(ctx, pool)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		fmt.Fprintln(env.stdout, "no invites have been minted")
		return nil
	}
	outstanding := 0
	for _, r := range rows {
		if r.State == "active" || r.State == "queued" || r.State == "awaiting_testflight" {
			outstanding++
		}
		expires := "-"
		if r.ExpiresAt != nil {
			expires = r.ExpiresAt.UTC().Format(time.RFC3339)
		}
		yes := func(b bool) string {
			if b {
				return "yes"
			}
			return "no"
		}
		// The account an invite created, for `account review` and
		// `purge-user` (a beta review account is found this way).
		by := ""
		if r.RedeemedBy != nil {
			by = " by=" + r.RedeemedBy.String()
		}
		fmt.Fprintf(env.stdout, "%s  %-9s  %-5s  review=%s  created %s  expires %s  mints %d  redeemed=%s%s  %s\n",
			invites.ShortID(r.ID), r.State, r.Origin, yes(r.Review), r.CreatedAt.UTC().Format(time.RFC3339), expires,
			r.MintCount, yes(r.Redeemed), by, r.Note)
	}
	fmt.Fprintf(env.stdout, "%d invite(s), %d still outstanding\n", len(rows), outstanding)
	return nil
}

// runWaitlist is `hasalad waitlist`: counts by state and by bank, never an
// address (spec 07 §14.3).
func runWaitlist(env *runEnv, args []string) error {
	fs := newFlags(env, "waitlist")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return refusal{errors.New("usage: hasalad waitlist")}
	}
	cfg, err := env.load("waitlist", nil)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	rows, err := pool.Query(ctx,
		`SELECT 'state', state, count(*) FROM waitlist_entries GROUP BY state
		 UNION ALL
		 SELECT 'bank', coalesce(bank_slug, CASE WHEN other_bank_key IS NULL THEN 'other (unnamed)' ELSE 'other' END), count(*)
		   FROM waitlist_entries WHERE state <> 'joined' GROUP BY 2
		 ORDER BY 1 DESC, 3 DESC, 2`)
	if err != nil {
		return err
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var kind, key string
		var count int64
		if err := rows.Scan(&kind, &key, &count); err != nil {
			return err
		}
		fmt.Fprintf(env.stdout, "%-5s  %-20s  %d\n", kind, key, count)
		n++
	}
	if n == 0 {
		fmt.Fprintln(env.stdout, "the waitlist is empty")
	}
	return rows.Err()
}

// runEmail is `hasalad email test <address>`: queues one `test` row for the
// worker in serve (spec 07 §14.3; spec 05 §5.7).
func runEmail(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	fs := newFlags(env, "email")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 2 || positional[0] != "test" || fs.NArg() > 0 {
		return refusal{errors.New("usage: hasalad email test <address>")}
	}
	cfg, err := env.load("email", nil)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	return withTx(ctx, pool, func(tx pgx.Tx) error {
		id, err := mailq.EnqueueTest(ctx, tx, mailq.New(pool, nil, nil), positional[1])
		if err != nil {
			return refusal{err}
		}
		if err := audit(ctx, tx, adminActor(env), "cli.email_test", "mail", fmt.Sprint(id), nil); err != nil {
			return err
		}
		fmt.Fprintf(env.stdout, "queued test email %d\n", id)
		return nil
	})
}

func withTx(ctx context.Context, pool *pgxpool.Pool, f func(pgx.Tx) error) error {
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	if err := f(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

var actorName = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

// adminActor is cli:<operator> from HASALA_ADMIN_ACTOR, else SUDO_USER, else
// USER; anything that is not a plain user name becomes cli:operator.
func adminActor(env *runEnv) string {
	for _, k := range []string{"HASALA_ADMIN_ACTOR", "SUDO_USER", "USER"} {
		if v, ok := env.lookup(k); ok {
			v = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(v)), "cli:")
			if actorName.MatchString(v) {
				return "cli:" + v
			}
		}
	}
	return "cli:operator"
}

// audit writes one admin_audit row (spec 07 §2.9, §8.6). params carry no
// address, name or code.
func audit(ctx context.Context, tx pgx.Tx, actor, action, kind, target string, params map[string]any) error {
	if params == nil {
		params = map[string]any{}
	}
	b, _ := json.Marshal(params)
	_, err := tx.Exec(ctx,
		`INSERT INTO admin_audit (actor, action, target_kind, target_id, params, result) VALUES ($1, $2, $3, $4, $5, 'ok')`,
		actor, action, kind, target, b)
	return err
}
