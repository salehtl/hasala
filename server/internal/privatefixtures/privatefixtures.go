// Package privatefixtures locates the real bank mail that the public Hasala
// repository does not carry.
//
// The conformance and origin suites were written against the operator's own
// mail: 37 normalizer cases, 1,126 template cases (545 distinct alert bodies)
// and 7 raw, DKIM/ARC-signed messages. That mail names real people, accounts
// and transactions, so it lives in a separate private repository,
// salehtl/hasala-fixtures, laid out with the same repo-relative paths it had
// here (conformance/normalizer/*.json, conformance/templates/corpus-*.json,
// server/internal/origin/testdata/*.eml and so on).
//
// A test that needs one of those files asks for it by its repo-relative path:
//
//   - HASALA_PRIVATE_FIXTURES unset: the test SKIPS, and the reason names the
//     variable, the file and the private repository. The skip reason always
//     starts with [Marker], which is how scripts/check.sh counts these skips.
//   - set, and the file is there: the test runs and logs one [Marker] line, so
//     the gate can count how many real-corpus tests actually ran.
//   - set, and the file is NOT there: the test FAILS. Pointing the variable at
//     a checkout is a claim that the real corpus is present; a missing file is
//     a broken checkout, and quietly skipping would let it pass as green.
//
// The synthetic suites (conformance/normalizer/edge-cases.json,
// conformance/templates/synthetic-*.json, and everything built in code) never
// go through this package and always run.
package privatefixtures

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// EnvVar names the checkout of salehtl/hasala-fixtures.
const EnvVar = "HASALA_PRIVATE_FIXTURES"

// Marker prefixes every skip reason and every "ran" log line this package
// writes. scripts/check.sh (through scripts/gotest-summary.ts) counts on it.
const Marker = "[real-corpus]"

// Repo is where the private fixtures live.
const Repo = "salehtl/hasala-fixtures"

// Root returns the configured checkout, or "" when EnvVar is unset. It never
// skips or fails, which is what the fixture WRITERS need: they decide for
// themselves what an absent checkout means.
func Root() string {
	return strings.TrimSpace(os.Getenv(EnvVar))
}

// Path returns the absolute path of rel (repo-relative, slash-separated, for
// example "conformance/normalizer/dib-arabic-01.json") inside the private
// checkout. It skips t when EnvVar is unset and fails t when EnvVar is set but
// rel is not in the checkout.
func Path(t testing.TB, rel string) string {
	t.Helper()
	root := Root()
	if root == "" {
		t.Skipf("%s %s is unset: %s is real bank mail, kept in the private %s repository; "+
			"set %s to a checkout of it to run this test", Marker, EnvVar, rel, Repo, EnvVar)
	}
	if !filepath.IsAbs(root) {
		// go test runs every package from its own directory, so a relative
		// checkout path would name a different place in each package.
		t.Fatalf("%s %s=%q must be an absolute path", Marker, EnvVar, root)
	}
	p := filepath.Join(root, filepath.FromSlash(rel))
	if _, err := os.Stat(p); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("%s %s=%s, but %s is not in that checkout: it is not a complete %s checkout, "+
				"or the fixture was renamed on one side only", Marker, EnvVar, root, rel, Repo)
		}
		t.Fatalf("%s stat %s: %v", Marker, p, err)
	}
	t.Logf("%s ran against %s from %s", Marker, rel, EnvVar)
	return p
}

// ReadFile reads rel from the private checkout, with Path's skip and fail
// rules.
func ReadFile(t testing.TB, rel string) []byte {
	t.Helper()
	b, err := os.ReadFile(Path(t, rel))
	if err != nil {
		t.Fatalf("%s read %s: %v", Marker, rel, err)
	}
	return b
}
