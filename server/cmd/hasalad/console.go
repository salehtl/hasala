package main

import (
	"errors"

	"github.com/salehtl/hasala/server/internal/config"
)

// runConsole is the operator console's mode (spec 07 §8): a separate process
// on its own loopback port and OS user, never mounted by serve. WS-19 builds
// internal/console; until then this checks the console's own environment
// rules (fence F7-4 and spec 07 §8.1) and refuses to start, exit 2.
func runConsole(env *runEnv, args []string) error {
	fs := newFlags(env, "console")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if err := config.CheckConsoleEnvironment(env.environ); err != nil {
		return refusal{err}
	}
	if _, err := env.load("console", nil); err != nil {
		return err
	}
	return refusal{errors.New("console: the operator console is not built yet (spec 07 §8, WS-19)")}
}
