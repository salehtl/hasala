package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/signal"
	"syscall"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/verify"
)

// runVerify is `hasalad verify structural [--user U] [--json]` and `hasalad
// verify usage [--user U] [--repair] [--json]` (spec 02 §18.3). Findings exit
// 1; a clean run exits 0.
func runVerify(env *runEnv, args []string) error {
	positional, rest := splitPositional(args)
	var a config.VerifyArgs
	fs := newFlags(env, "verify")
	fs.StringVar(&a.User, "user", "", "verify one account, as a UUID")
	fs.BoolVar(&a.Repair, "repair", false, "usage: rewrite each drifting account_usage row to its recomputed total")
	fs.BoolVar(&a.JSON, "json", false, "emit JSON instead of the operator's text report")
	if err := parseFlags(fs, rest); err != nil {
		return err
	}
	if len(positional) != 1 || (positional[0] != "structural" && positional[0] != "usage") || fs.NArg() > 0 {
		return refusal{errors.New("usage: hasalad verify structural|usage [--user <uuid>] [--repair] [--json]")}
	}
	a.Check = positional[0]
	if a.Repair && a.Check != "usage" {
		return refusal{errors.New("verify: --repair applies to `verify usage` only")}
	}
	var users []uuid.UUID
	if a.User != "" {
		u, err := uuid.Parse(a.User)
		if err != nil {
			return refusal{fmt.Errorf("verify: --user %q is not a uuid", a.User)}
		}
		users = []uuid.UUID{u}
	}
	cfg, err := env.load("verify", func(c *config.Config) { c.Verify = a })
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	pool, err := openRuntime(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	var (
		findings []verify.Finding
		repairs  []verify.Correction
	)
	switch a.Check {
	case "structural":
		findings, err = verify.StructuralFor(ctx, pool, users)
	case "usage":
		if a.Repair {
			if repairs, err = verify.RepairUsageLedger(ctx, pool, users); err != nil {
				return fmt.Errorf("verify: repair: %w", err)
			}
		}
		findings, err = verify.UsageLedgerFor(ctx, pool, users)
	}
	if err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	if a.JSON {
		enc := json.NewEncoder(env.stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(map[string]any{"check": a.Check, "findings": findings, "repairs": repairs,
			"ok": len(findings) == 0}); err != nil {
			return err
		}
	} else {
		if len(repairs) > 0 {
			fmt.Fprintf(env.stdout, "usage ledger: REPAIRED %d row(s)\n", len(repairs))
			for _, x := range repairs {
				fmt.Fprintf(env.stdout, "  user %s  %-18s %d -> %d\n", x.UserID, x.Resource, x.From, x.To)
			}
		}
		if len(findings) == 0 {
			fmt.Fprintf(env.stdout, "verify %s: no findings\n", a.Check)
		} else {
			fmt.Fprintf(env.stdout, "verify %s: %d finding(s)\n", a.Check, len(findings))
			for _, x := range findings {
				fmt.Fprintf(env.stdout, "  %-24s user %s: %s\n", x.ID, x.UserID, x.Detail)
			}
		}
	}
	if len(findings) > 0 {
		return fmt.Errorf("verify %s: %d finding(s)", a.Check, len(findings))
	}
	return nil
}
