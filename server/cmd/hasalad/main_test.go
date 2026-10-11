package main

import (
	"bytes"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

// hasalad runs one invocation in-process with exactly the given environment
// and returns its exit code and output.
func hasalad(t *testing.T, environ []string, argv ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	err := run(&runEnv{stdout: &out, stderr: &errb, environ: environ}, argv)
	return exitCode(err), out.String(), errb.String() + errString(err)
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestEveryAdvertisedModeHasAHandlerAndNoOther(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatal(r)
		}
	}()
	checkModeHandlers()
}

func TestTheModeComesFirst(t *testing.T) {
	for _, argv := range [][]string{nil, {"--verbose"}, {"ledgerd"}, {"smtp"}, {"admin"}, {"dev-auth"}} {
		if code, _, _ := hasalad(t, nil, argv...); code != 2 {
			t.Fatalf("hasalad %v exited %d, want 2", argv, code)
		}
	}
}

func TestHelpExitsZero(t *testing.T) {
	code, out, _ := hasalad(t, nil, "--help")
	if code != 0 || !strings.Contains(out, "usage: hasalad") {
		t.Fatalf("--help exited %d with %q", code, out)
	}
	if code, _, _ := hasalad(t, nil, "serve", "--help"); code != 0 {
		t.Fatalf("serve --help exited %d", code)
	}
}

func TestVersionNeedsNoConfiguration(t *testing.T) {
	code, out, _ := hasalad(t, nil, "version")
	if code != 0 || !regexp.MustCompile(`^hasalad \S+ go\S+\n$`).MatchString(out) {
		t.Fatalf("version exited %d with %q", code, out)
	}
}

// Argument mistakes are refused before anything is opened: none of these has
// a DSN, so reaching the database would be a different error.
func TestArgumentMistakesAreRefusedBeforeTheDatabase(t *testing.T) {
	id := uuid.NewString()
	for _, argv := range [][]string{
		{"purge-user"},
		{"purge-user", id},
		{"purge-user", id, "--confirm", uuid.NewString()},
		{"purge-user", "not-a-uuid", "--confirm", "not-a-uuid"},
		{"purge-user", uuid.Nil.String(), "--confirm", uuid.Nil.String()},
		{"verify"},
		{"verify", "everything"},
		{"verify", "structural", "--repair"},
		{"verify", "usage", "--user", "nope"},
		{"invite"},
		{"invite", "revoke"},
		{"invite", "list", "--note", "x"},
		{"migrate", "--status", "--pending"},
		{"migrate", "--to", "-1"},
		{"migrate", "extra"},
		{"serve", "--no-such-flag"},
	} {
		code, _, msg := hasalad(t, nil, argv...)
		if code != 2 {
			t.Fatalf("hasalad %v exited %d (%s), want 2", argv, code, msg)
		}
		if strings.Contains(msg, "postgres") {
			t.Fatalf("hasalad %v reached the database before refusing its arguments: %s", argv, msg)
		}
	}
}

func TestEveryDatabaseModeNeedsItsDSN(t *testing.T) {
	for _, argv := range [][]string{
		{"serve"}, {"verify", "structural"}, {"invite", "list"},
		{"purge-user", uuid.Nil.String()[:35] + "1", "--confirm", uuid.Nil.String()[:35] + "1"},
	} {
		if code, _, msg := hasalad(t, nil, argv...); code != 2 || !strings.Contains(msg, "HASALA_PG_DSN") {
			t.Fatalf("hasalad %v without a DSN exited %d (%s), want 2 naming HASALA_PG_DSN", argv, code, msg)
		}
	}
	// migrate never falls back to the runtime DSN (spec 02 §5.5).
	code, _, msg := hasalad(t, []string{"HASALA_PG_DSN=postgres://x@127.0.0.1/x"}, "migrate")
	if code != 2 || !strings.Contains(msg, "HASALA_MIGRATE_DSN") {
		t.Fatalf("migrate with only the runtime DSN exited %d (%s), want 2", code, msg)
	}
}

// Fence F7-4, serve's half: a unit wired with any console or App Store
// Connect variable is refused before configuration is even read.
func TestServeRefusesTheConsolesEnvironment(t *testing.T) {
	for _, kv := range []string{"HASALA_CONSOLE_LISTEN=127.0.0.1:9", "HASALA_ASC_KEY_ID=x", "HASALA_TESTFLIGHT_MODE=1"} {
		code, _, msg := hasalad(t, []string{kv}, "serve")
		if code != 2 || !strings.Contains(msg, "operator console") {
			t.Fatalf("serve with %s exited %d (%s), want a 2 naming the console", kv, code, msg)
		}
	}
}

// Fence F7-4, the console's half, and the stub's own refusal: the console is
// not built in this tree, and the mode says so with exit 2 rather than
// serving anything.
func TestConsoleRefuses(t *testing.T) {
	code, _, msg := hasalad(t, []string{"HASALA_AUTH_KEY_FILE=/x"}, "console")
	if code != 2 || !strings.Contains(msg, "secret of serve") {
		t.Fatalf("console with serve's secret exited %d (%s)", code, msg)
	}
	if code, _, _ := hasalad(t, nil, "console"); code != 2 {
		t.Fatalf("console exited %d, want 2", code)
	}
}

// The whole operator lifecycle against a fresh database: migrate as the
// owner, then the runtime modes as the runtime role, and the refusals that
// keep the two roles apart (spec 02 §5.5, §5.6).
func TestMigrateThenOperateAsTheRuntimeRole(t *testing.T) {
	migrateDSN, runtimeDSN := pgtest.NewEmpty(t)
	asOwner := []string{"HASALA_MIGRATE_DSN=" + migrateDSN}
	asRuntime := []string{"HASALA_PG_DSN=" + runtimeDSN}

	// Before migrating, nothing runs: the runtime modes are behind the
	// embedded migrations (O-refusals). --pending answers 0 for a database
	// with no goose_db_version — a fresh database has nothing to back up.
	if code, _, msg := hasalad(t, asRuntime, "verify", "structural"); code != 2 {
		t.Fatalf("verify on an unmigrated database exited %d (%s), want 2", code, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "migrate", "--pending"); code != 0 || out != "0\n" {
		t.Fatalf("migrate --pending exited %d with %q (%s), want 0 and 0", code, out, msg)
	}
	// migrate refuses the runtime role even when it is handed in the
	// migrate variable (M1).
	if code, _, msg := hasalad(t, []string{"HASALA_MIGRATE_DSN=" + runtimeDSN}, "migrate"); code != 2 {
		t.Fatalf("migrate as the runtime role exited %d (%s), want 2", code, msg)
	}

	if code, _, msg := hasalad(t, asOwner, "migrate"); code != 0 {
		t.Fatalf("migrate exited %d: %s", code, msg)
	}
	code, out, msg := hasalad(t, asOwner, "migrate", "--status")
	if code != 0 || !strings.Contains(out, "pending 0") {
		t.Fatalf("migrate --status exited %d with %q (%s)", code, out, msg)
	}
	// Idempotent.
	if code, _, msg := hasalad(t, asOwner, "migrate"); code != 0 {
		t.Fatalf("a second migrate exited %d: %s", code, msg)
	}

	// The runtime modes refuse to run as the schema owner (O2).
	for _, argv := range [][]string{{"verify", "structural"}, {"invite", "list"}} {
		if code, _, msg := hasalad(t, []string{"HASALA_PG_DSN=" + migrateDSN}, argv...); code != 2 {
			t.Fatalf("%v as the schema owner exited %d (%s), want 2", argv, code, msg)
		}
	}

	code, out, msg = hasalad(t, asRuntime, "invite", "mint", "--note", "lifecycle")
	if code != 0 || strings.TrimSpace(out) == "" {
		t.Fatalf("invite mint exited %d with %q (%s)", code, out, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "invite", "list"); code != 0 || !strings.Contains(out, "1 invite(s), 1 active") {
		t.Fatalf("invite list exited %d with %q (%s)", code, out, msg)
	}
	if code, _, msg := hasalad(t, asRuntime, "verify", "structural"); code != 0 {
		t.Fatalf("verify structural on a clean database exited %d: %s", code, msg)
	}
	if code, _, msg := hasalad(t, asRuntime, "verify", "usage"); code != 0 {
		t.Fatalf("verify usage on a clean database exited %d: %s", code, msg)
	}
	id := uuid.NewString()
	if code, out, msg := hasalad(t, asRuntime, "purge-user", id, "--confirm", id, "--dry-run"); code != 0 || !strings.Contains(out, "Nothing was deleted") {
		t.Fatalf("purge-user --dry-run exited %d with %q (%s)", code, out, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "purge-user", id, "--confirm", id); code != 0 || !strings.Contains(out, "no such account") {
		t.Fatalf("purge-user of an unknown account exited %d with %q (%s)", code, out, msg)
	}

	// serve refuses to serve as the schema owner (spec 02 §5.6, O2) before it
	// opens a listener.
	serveEnv := []string{
		"HASALA_PG_DSN=" + migrateDSN, "HASALA_RP_ID=example.test",
		"HASALA_RP_ORIGINS=https://example.test", "HASALA_HEADROOM_PATH=" + t.TempDir(),
		"HASALA_HTTP_LISTEN=127.0.0.1:0",
	}
	if code, _, msg := hasalad(t, serveEnv, "serve"); code != 2 {
		t.Fatalf("serve as the schema owner exited %d (%s), want 2", code, msg)
	}
}

// clientip.go keys the per-IP limits by Cf-Connecting-Ip behind Cloudflare, so
// serve no longer warns that it does not.
func TestServeNoLongerWarnsAboutTheCloudflareProxy(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	var cfg config.Config
	cfg.Server.TrustedProxy = config.ProxyCloudflare
	logGroups(cfg)
	if strings.Contains(buf.String(), "not honoured") || strings.Contains(buf.String(), "ONE global limit") {
		t.Fatalf("trusted_proxy = cloudflare still warns: %s", buf.String())
	}
}
