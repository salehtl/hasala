package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/accounts"
	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/purgeledger"
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
	if len(positional) > 0 && positional[0] == "unfreeze" && fs.NArg() == 0 {
		return runAccountUnfreeze(env, positional[1:], confirm)
	}
	usage := refusal{errors.New("usage: hasalad account review <uuid> on|off --confirm <uuid>" +
		" | hasalad account unfreeze <uuid> --confirm <uuid>")}
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

func runAccountUnfreeze(env *runEnv, positional []string, confirm string) error {
	if len(positional) != 1 {
		return refusal{errors.New("usage: hasalad account unfreeze <uuid> --confirm <uuid>")}
	}
	target, err := uuid.Parse(positional[0])
	if err != nil || target == uuid.Nil || target.String() != positional[0] {
		return refusal{fmt.Errorf("account unfreeze: %q is not an account id (36 lowercase characters)", positional[0])}
	}
	if confirm != positional[0] {
		return refusal{errors.New("account unfreeze: --confirm must repeat the account id exactly")}
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
	now := time.Now()
	mailer := &auth.Mailer{Queue: mailq.New(pool, nil, nil)}
	var (
		frozen bool
		by     string
	)
	err = withTx(ctx, pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT frozen_at IS NOT NULL, coalesce(frozen_by, '') FROM users WHERE id = $1 FOR UPDATE`,
			target).Scan(&frozen, &by); err != nil {
			return err
		}
		if !frozen {
			return nil
		}
		unfrozen, err := auth.OperatorUnfreeze(ctx, tx, target, auth.ScopeAny, now, mailer)
		if err != nil {
			return err
		}
		if !unfrozen {
			return errors.New("account unfreeze: the account is still frozen")
		}
		return audit(ctx, tx, adminActor(env), "cli.account_unfreeze", "account", target.String(), map[string]any{"frozen_by": by})
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return refusal{fmt.Errorf("account unfreeze: no account %s", target)}
	}
	if err != nil {
		return err
	}
	if !frozen {
		fmt.Fprintf(env.stdout, "account %s: was not frozen; nothing changed\n", target)
		return nil
	}
	fmt.Fprintf(env.stdout, "account %s: unfrozen (was frozen by the %s); every session is signed out\n", target, by)
	p := cfg.Server.PurgeLedgerPath
	if p == "" {
		fmt.Fprintln(env.stderr, "account unfreeze: warning: HASALA_PURGE_LEDGER_PATH is not set, "+
			"so restoring a backup would bring this freeze back")
		return nil
	}
	if err := purgeledger.AppendEntries(p, auth.UnfreezeEntry(target, now)); err != nil {
		return fmt.Errorf("account unfreeze: the account is unfrozen, but the restore ledger did not record it: %w", err)
	}
	return nil
}
