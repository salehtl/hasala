package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/accounts"
)

// runAccount is `hasalad account review <uuid> on|off --confirm <uuid>`
// (spec 02 §14.2, §18.3): the operator turns an account's review flag on or
// off. The account id is typed twice, as for purge-user. A review invite
// (`invite mint --review`) already sets the flag at signup; this is for an
// account made another way, and for turning it off after Beta App Review.
// It writes an admin_audit row (actor cli:<operator>).
func runAccount(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var confirm string
	fs := newFlags(env, "account")
	fs.StringVar(&confirm, "confirm", "", "the same account id again")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	usage := refusal{errors.New("usage: hasalad account review <uuid> on|off --confirm <uuid>")}
	if len(positional) != 3 || positional[0] != "review" || fs.NArg() > 0 {
		return usage
	}
	target, err := uuid.Parse(positional[1])
	if err != nil || target == uuid.Nil || target.String() != positional[1] {
		return refusal{fmt.Errorf("account review: %q is not an account id (36 lowercase characters)", positional[1])}
	}
	var on bool
	switch positional[2] {
	case "on":
		on = true
	case "off":
	default:
		return usage
	}
	if confirm != positional[1] {
		return refusal{errors.New("account review: --confirm must repeat the account id exactly")}
	}
	cfg, err := env.load("account", nil)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	var was bool
	err = withTx(ctx, pool, func(tx pgx.Tx) error {
		if was, err = accounts.SetReview(ctx, tx, target, on); err != nil {
			return err
		}
		return audit(ctx, tx, adminActor(env), "cli.account_review", "account", target.String(), map[string]any{"on": on})
	})
	if errors.Is(err, accounts.ErrNoSuchAccount) {
		return refusal{fmt.Errorf("account review: no account %s", target)}
	}
	if err != nil {
		return err
	}
	state := map[bool]string{true: "on", false: "off"}
	fmt.Fprintf(env.stdout, "account %s: review %s (was %s)\n", target, state[on], state[was])
	return nil
}
