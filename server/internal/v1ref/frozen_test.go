package v1ref

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// manifestName and testName are the two files the manifest cannot cover: the
// manifest cannot hash itself, and this test's own bytes are the checker rather
// than the checked.
const (
	manifestName = "frozen.sha256"
	testName     = "frozen_test.go"
)

// writeEnv, set to exactly "1", regenerates the manifest instead of asserting
// against it. Use it ONLY when a change in here is a deliberate contract change
// (see README.md), and re-run the corpus and import gates in the same breath:
//
//	LEDGER_WRITE_V1REF_MANIFEST=1 go test ./internal/v1ref/ -run TestV1RefIsFrozen
//
// A write run ALWAYS FAILS, on purpose. If it could go green, this variable
// leaking into an environment — a shell that exported it, a CI job, a stale
// `env` line — would turn the freeze into a check that cannot fail: every
// mutation would be silently absorbed into a rewritten manifest and reported
// as a pass. So the write path records the new bytes and then fails, and the
// only way to a green run is to unset the variable and verify.
//
// The value must be exactly "1", so an accidental empty-ish spelling
// (`FOO=0`, `FOO=false`) does not arm it either.
const writeEnv = "LEDGER_WRITE_V1REF_MANIFEST"

// TestV1RefIsFrozen is the enforcement behind internal/v1ref/README.md's promise.
//
// The five packages under this directory are the reference implementations two
// gates measure against: the corpus-equivalence gate compares v2's parsing to
// v1ref/parse over the operator's corpus, and the import-conformance suite pairs
// v1ref/importer with client/src/importer. A reference that anyone can quietly
// edit is not a reference — the gates would keep passing while the thing they
// compare against moved. So the bytes are recorded, and any drift fails here.
func TestV1RefIsFrozen(t *testing.T) {
	dir := v1refDir(t)
	actual, err := hashTree(dir)
	if err != nil {
		t.Fatalf("hashing %s: %v", dir, err)
	}

	if os.Getenv(writeEnv) == "1" {
		if err := os.WriteFile(filepath.Join(dir, manifestName), []byte(renderManifest(actual)), 0o644); err != nil {
			t.Fatalf("writing manifest: %v", err)
		}
		// Deliberately fatal: a re-record run must never be a green run. See
		// writeEnv's comment — a variable that leaks into an environment would
		// otherwise absorb every mutation silently.
		t.Fatalf("%s=1: rewrote %s over %d files, and FAILED on purpose.\n\n"+
			"This is a CONTRACT CHANGE. Say so in the commit message, re-run the\n"+
			"corpus and import gates, then unset %s and run this test again — a\n"+
			"green run is the only thing that verifies the new manifest, and a\n"+
			"re-record run can never be one.",
			writeEnv, manifestName, len(actual), writeEnv)
	}

	raw, err := os.ReadFile(filepath.Join(dir, manifestName))
	if err != nil {
		t.Fatalf("reading %s: %v", manifestName, err)
	}
	expected, err := parseManifest(string(raw))
	if err != nil {
		t.Fatalf("parsing %s: %v", manifestName, err)
	}

	var changed, added, removed []string
	for path, sum := range actual {
		want, ok := expected[path]
		switch {
		case !ok:
			added = append(added, path)
		case want != sum:
			changed = append(changed, path)
		}
	}
	for path := range expected {
		if _, ok := actual[path]; !ok {
			removed = append(removed, path)
		}
	}
	sort.Strings(changed)
	sort.Strings(added)
	sort.Strings(removed)

	if len(changed) == 0 && len(added) == 0 && len(removed) == 0 {
		return
	}

	var b strings.Builder
	b.WriteString("internal/v1ref is FROZEN, and it changed.\n\n")
	b.WriteString("These are copies of ledger 1.0's packages, taken at the repo split (tag\n")
	b.WriteString("ledger-v2-final). They are not product code: they are the reference the\n")
	b.WriteString("corpus-equivalence gate and the import-conformance suite measure this repo\n")
	b.WriteString("against. Editing one moves the yardstick, and every gate that uses it keeps\n")
	b.WriteString("passing while meaning something different. A \"bug\" in here is the reference\n")
	b.WriteString("behaviour — do not fix it.\n\n")
	for _, p := range changed {
		fmt.Fprintf(&b, "  modified: %s\n", p)
	}
	for _, p := range added {
		fmt.Fprintf(&b, "  added:    %s\n", p)
	}
	for _, p := range removed {
		fmt.Fprintf(&b, "  removed:  %s\n", p)
	}
	b.WriteString("\nIf this was an accident, revert it. If the change is deliberate, it is a\n")
	b.WriteString("CONTRACT CHANGE: record it in the commit message, re-record the manifest\n")
	fmt.Fprintf(&b, "with `%s=1 go test ./internal/v1ref/ -run TestV1RefIsFrozen`, and re-run\n", writeEnv)
	b.WriteString("the corpus and import gates before you trust anything they say. That\n")
	b.WriteString("re-record run fails too, by design — unset the variable and run this test\n")
	b.WriteString("again, because a green run is the only thing that verifies the new bytes.\n")
	t.Fatal(b.String())
}

// v1refDir resolves this directory from the test's own source path, so the test
// does not depend on the working directory `go test` happens to use.
func v1refDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed; cannot locate internal/v1ref")
	}
	return filepath.Dir(file)
}

// hashTree returns slash-separated paths relative to dir mapped to their SHA-256,
// covering every file beneath dir except the manifest and this test.
func hashTree(dir string) (map[string]string, error) {
	out := make(map[string]string)
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel == manifestName || rel == testName {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(b)
		out[rel] = hex.EncodeToString(sum[:])
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no files found under %s — a manifest over nothing is a check that cannot fail", dir)
	}
	return out, nil
}

// renderManifest writes `<sha256>  <path>` lines, sorted by path — the sha256sum
// format, so `sha256sum -c frozen.sha256` also works from this directory.
func renderManifest(sums map[string]string) string {
	paths := make([]string, 0, len(sums))
	for p := range sums {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	var b strings.Builder
	for _, p := range paths {
		fmt.Fprintf(&b, "%s  %s\n", sums[p], p)
	}
	return b.String()
}

func parseManifest(raw string) (map[string]string, error) {
	out := make(map[string]string)
	for i, line := range strings.Split(raw, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		sum, path, ok := strings.Cut(line, "  ")
		if !ok {
			return nil, fmt.Errorf("line %d is not `<sha256>  <path>`: %q", i+1, line)
		}
		out[path] = sum
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("manifest is empty — a manifest over nothing is a check that cannot fail")
	}
	return out, nil
}
