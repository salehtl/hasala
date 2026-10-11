package main

import (
	"context"
	"fmt"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
)

// runInvite is `hasalad invite mint [--note TEXT]` and `hasalad invite list`.
// It is ledgerd's single-use code (spec 07 §2.5 replaces it with the invite
// state machine, addressed invites and `--review`, WS-19). The code is printed
// once and stored only as a hash.
func runInvite(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var note string
	fs := newFlags(env, "invite")
	fs.StringVar(&note, "note", "", "mint: the operator's own words about who this code is for")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 1 || (positional[0] != "mint" && positional[0] != "list") || fs.NArg() > 0 {
		return refusal{fmt.Errorf("usage: hasalad invite mint [--note TEXT] | hasalad invite list")}
	}
	if positional[0] == "list" && note != "" {
		return refusal{fmt.Errorf("invite list takes no --note")}
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
		outstanding := 0
		for _, r := range rows {
			state := "OUTSTANDING"
			switch {
			case r.RedeemedAt == nil:
				outstanding++
			case r.RedeemedBy == nil:
				state = "redeemed " + r.RedeemedAt.UTC().Format(time.RFC3339) + " by a since-deleted account"
			default:
				state = "redeemed " + r.RedeemedAt.UTC().Format(time.RFC3339) + " by " + r.RedeemedBy.String()
			}
			fmt.Fprintf(env.stdout, "%s  minted %s  %s  %s\n", r.Hash, r.CreatedAt.UTC().Format(time.RFC3339), state, r.Note)
		}
		fmt.Fprintf(env.stdout, "%d code(s), %d still outstanding\n", len(rows), outstanding)
		return nil
	}
	code, err := auth.MintInvite(ctx, pool, note, time.Now().UTC())
	if err != nil {
		return err
	}
	fmt.Fprintln(env.stdout, code)
	fmt.Fprintln(env.stderr, "this code is single use, gates ACCOUNT CREATION only, and is not "+
		"recoverable: it is stored as a hash. Hand it over out of band.")
	return nil
}
