package main

import (
	"context"
	"fmt"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
)

// runInvite is `hasalad invite mint [--note TEXT] [--review]` and `hasalad invite list`.
// It mints spec 07 §2.5 printed CLI invites (active, unaddressed; --review
// makes a Beta App Review invite, spec 02 §14.2). The code is printed
// once and stored only as a hash.
func runInvite(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var (
		note   string
		review bool
	)
	fs := newFlags(env, "invite")
	fs.StringVar(&note, "note", "", "mint: the operator's own words about who this code is for")
	fs.BoolVar(&review, "review", false, "mint: a Beta App Review invite (the account it creates is a review account)")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 1 || (positional[0] != "mint" && positional[0] != "list") || fs.NArg() > 0 {
		return refusal{fmt.Errorf("usage: hasalad invite mint [--note TEXT] [--review] | hasalad invite list")}
	}
	if positional[0] == "list" && (note != "" || review) {
		return refusal{fmt.Errorf("invite list takes no --note or --review")}
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

	if positional[0] == "list" {
		rows, err := auth.ListInvites(ctx, pool)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			fmt.Fprintln(env.stdout, "no invite codes have been minted")
			return nil
		}
		active := 0
		for _, r := range rows {
			state := r.State
			switch {
			case r.State == "active":
				active++
			case r.RedeemedAt != nil && r.RedeemedBy == nil:
				state = "redeemed " + r.RedeemedAt.UTC().Format(time.RFC3339) + " by a since-deleted account"
			case r.RedeemedAt != nil:
				state = "redeemed " + r.RedeemedAt.UTC().Format(time.RFC3339) + " by " + r.RedeemedBy.String()
			}
			kind := "printed"
			if r.Review {
				kind = "review"
			} else if r.Addressed {
				kind = "addressed"
			}
			fmt.Fprintf(env.stdout, "%s  %s  minted %s  %s  %s\n", r.ID, kind, r.CreatedAt.UTC().Format(time.RFC3339), state, r.Note)
		}
		fmt.Fprintf(env.stdout, "%d invite(s), %d active\n", len(rows), active)
		return nil
	}
	code, err := auth.MintInvite(ctx, pool, auth.MintOptions{Note: note, Review: review, TTL: cfg.Auth.InviteTTL,
		Now: time.Now().UTC()})
	if err != nil {
		return err
	}
	fmt.Fprintln(env.stdout, code)
	fmt.Fprintln(env.stderr, "this code is single use, gates ACCOUNT CREATION only, and is not "+
		"recoverable: it is stored as a hash. Hand it over out of band.")
	return nil
}
