package main

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

func runMailbox(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var (
		dropLinks bool
		keepKeyID string
	)
	fs := newFlags(env, "mailbox")
	fs.BoolVar(&dropLinks, "drop-links", false, "drop every mailbox link made under another route key")
	fs.StringVar(&keepKeyID, "keep-key-id", "", "the current route key's id, as the startup refusal prints it")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 1 || positional[0] != "rekey" || fs.NArg() > 0 || !dropLinks {
		return refusal{errors.New("usage: hasalad mailbox rekey --drop-links --keep-key-id <16 hex>")}
	}
	keep, err := hex.DecodeString(keepKeyID)
	if err != nil || len(keep) != 8 || keepKeyID != strings.ToLower(keepKeyID) {
		return refusal{fmt.Errorf("mailbox rekey: --keep-key-id %q is not a route key id (16 lowercase hex)", keepKeyID)}
	}
	cfg, err := env.load("mailbox", nil)
	if err != nil {
		return err
	}
	ctx := context.Background()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	var dropped int64
	err = withTx(ctx, pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM mailbox_links WHERE route_key_id <> $1`, keep)
		if err != nil {
			return err
		}
		dropped = tag.RowsAffected()
		return audit(ctx, tx, adminActor(env), "cli.mailbox_rekey", "system", keepKeyID, map[string]any{"dropped": dropped})
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(env.stdout, "mailbox rekey: dropped %d link(s) made under another route key\n", dropped)
	return nil
}
