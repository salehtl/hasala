// Command hasalad is Hasala's server (spec 02): `hasalad <mode> [arguments]`.
//
// Modes (spec 02 §18.3; the rest of that table arrives with its workstream):
//
//	serve                                   the API (runtime role)
//	migrate [--status | --pending] [--to N] apply the embedded migrations (schema owner)
//	verify structural|usage [--user U] [--repair] [--json]
//	purge-user <uuid> --confirm <uuid> [--dry-run]
//	invite mint [--note T] [--ttl D] [--review | --email A] | list | revoke <id>
//	waitlist                                counts by state and bank
//	email test <address>                    queue one test email
//	console                                 the operator console (spec 07 §8; not built yet)
//	version                                 hasalad <version> <go version>
//
// Exit codes: 0 ok; 2 refused (a startup check, a wrong role or DSN, bad
// arguments); 1 any other failure.
//
// Every mode except migrate and version connects as the runtime role and runs
// spec 02 §5.6's startup refusals first (internal/pg.CheckServing): no mode
// runs as a superuser or as the schema owner, behind the embedded migrations,
// or against a database whose sealed-frame guarantee was weakened.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"runtime/debug"
	"sort"
	"strings"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/pg"
)

// version is set at link time (-X main.version=...; the Nix build passes the
// flake's short revision, 05 §4.2). Empty falls back to the VCS revision in
// the build info.
var version string

// modeHandlers is the single dispatch table. checkModeHandlers asserts on every
// start that its key set is exactly config.Modes(), so a mode cannot be
// advertised without a handler or handled without being advertised.
var modeHandlers = map[string]func(env *runEnv, args []string) error{
	"serve":      runServe,
	"migrate":    runMigrate,
	"verify":     runVerify,
	"purge-user": runPurgeUser,
	"invite":     runInvite,
	"waitlist":   runWaitlist,
	"email":      runEmail,
	"console":    runConsole,
	"version":    runVersion,
}

// runEnv is what every mode receives: its output streams, its environment and
// how to load configuration. A struct rather than globals so a test can run a
// mode with its own environment and capture what it printed.
type runEnv struct {
	stdout, stderr io.Writer
	environ        []string
	configPath     string
}

func (e *runEnv) lookup(name string) (string, bool) {
	for i := len(e.environ) - 1; i >= 0; i-- {
		if k, v, ok := strings.Cut(e.environ[i], "="); ok && k == name {
			return v, true
		}
	}
	return "", false
}

// load reads the configuration and checks it for one mode.
func (e *runEnv) load(mode string, apply func(*config.Config)) (config.Config, error) {
	cfg, err := config.LoadEnv(e.configPath, e.lookup, e.environ)
	if err != nil {
		return config.Config{}, refusal{err}
	}
	cfg.Mode = mode
	if apply != nil {
		apply(&cfg)
	}
	if err := cfg.ValidateFor(mode); err != nil {
		return config.Config{}, refusal{err}
	}
	return cfg, nil
}

// refusal marks an error that exits 2.
type refusal struct{ error }

func (r refusal) Unwrap() error { return r.error }

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var r refusal
	if errors.As(err, &r) || pg.IsRefusal(err) || errors.Is(err, flag.ErrHelp) {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	return 1
}

func checkModeHandlers() {
	want := map[string]bool{}
	for _, m := range config.Modes() {
		want[m] = true
		if _, ok := modeHandlers[m]; !ok {
			panic(fmt.Sprintf("cmd/hasalad: config.Modes() advertises mode %q but modeHandlers has no case for it", m))
		}
	}
	for m := range modeHandlers {
		if !want[m] {
			panic(fmt.Sprintf("cmd/hasalad: modeHandlers has a case for mode %q but config.Modes() does not advertise it", m))
		}
	}
}

func main() {
	checkModeHandlers()
	// Spec 02 §20: structured JSON lines on stdout (journald). The standard
	// log package is routed through the same handler.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	env := &runEnv{stdout: os.Stdout, stderr: os.Stderr, environ: os.Environ()}
	err := run(env, os.Args[1:])
	if err != nil && !errors.Is(err, flag.ErrHelp) {
		if pg.IsRefusal(err) {
			slog.Error("refused", "err", err.Error())
		} else {
			log.Printf("hasalad: %v", err)
		}
	}
	os.Exit(exitCode(err))
}

// run dispatches argv: the mode comes first, then its own arguments. A global
// --config before the mode is accepted; HASALA_CONFIG is the alternative.
func run(env *runEnv, argv []string) error {
	if len(argv) > 1 && (argv[0] == "--config" || argv[0] == "-config") {
		env.configPath, argv = argv[1], argv[2:]
	}
	if len(argv) == 0 || strings.HasPrefix(argv[0], "-") {
		if len(argv) > 0 && (argv[0] == "-h" || argv[0] == "--help" || argv[0] == "-help") {
			usage(env.stdout)
			return flag.ErrHelp
		}
		usage(env.stderr)
		return refusal{errors.New("the mode comes first: hasalad <mode> [arguments]")}
	}
	handler, ok := modeHandlers[argv[0]]
	if !ok {
		usage(env.stderr)
		return refusal{fmt.Errorf("unknown mode %q", argv[0])}
	}
	return handler(env, argv[1:])
}

func usage(w io.Writer) {
	modes := config.Modes()
	sort.Strings(modes)
	fmt.Fprintf(w, "usage: hasalad [--config PATH] <mode> [arguments]\nmodes: %s\n"+
		"every mode answers --help\n", strings.Join(modes, ", "))
}

// newFlags is a FlagSet for one mode that prints to the run's stderr.
func newFlags(env *runEnv, name string) *flag.FlagSet {
	fs := flag.NewFlagSet("hasalad "+name, flag.ContinueOnError)
	fs.SetOutput(env.stderr)
	fs.StringVar(&env.configPath, "config", env.configPath, "path to a TOML config file (or HASALA_CONFIG)")
	return fs
}

// parseFlags parses a mode's flags, mapping a usage error to a refusal and
// --help to flag.ErrHelp (exit 0).
func parseFlags(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return err
		}
		return refusal{err}
	}
	return nil
}

// splitPositional separates leading positional words from flags, so both
// `purge-user <uuid> --confirm <uuid>` and `verify structural --user U` parse
// with the standard flag package (which stops at the first non-flag).
func splitPositional(args []string) (positional, flags []string) {
	for i, a := range args {
		if strings.HasPrefix(a, "-") {
			return args[:i], args[i:]
		}
	}
	return args, nil
}

func runVersion(env *runEnv, args []string) error {
	fs := newFlags(env, "version")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	v, goVersion := version, "unknown"
	if bi, ok := debug.ReadBuildInfo(); ok {
		goVersion = bi.GoVersion
		if v == "" {
			for _, s := range bi.Settings {
				if s.Key == "vcs.revision" {
					v = s.Value
				}
			}
		}
	}
	if v == "" {
		v = "unknown"
	}
	fmt.Fprintf(env.stdout, "hasalad %s %s\n", v, goVersion)
	return nil
}
