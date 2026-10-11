package norm

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/privatefixtures"
)

// conformanceDir holds the committed SYNTHETIC fixtures both executors run
// against (edge-cases.json and the artifacts twin_test.go writes).
const conformanceDir = "../../../conformance/normalizer"

// realCasesDir is RealCasesDir (fixtures.go).
const realCasesDir = RealCasesDir

// writeFixturesEnv gates the writers. A test that rewrites its own reference on
// every run pins nothing, so writing is opt-in and the output is committed.
const writeFixturesEnv = "HASALA_WRITE_CONFORMANCE"

// conformanceCase and corpusFixtures live in fixtures.go, exported for the
// oracle module's fixture writer (server/oracle/gates/norm).
type conformanceCase = ConformanceCase

var corpusFixtures = CorpusFixtures

// resultHasField reports whether Result declares a field with this name. It
// backs the assertion that nothing in Result can be mistaken for a verified
// identity.
func resultHasField(name string) bool {
	_, ok := reflect.TypeOf(Result{}).FieldByName(name)
	return ok
}

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

func loadCases(t *testing.T) []conformanceCase {
	t.Helper()
	dir := privatefixtures.Path(t, realCasesDir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	// The case files must be exactly the ones the private manifest lists. The
	// suite enumerates the directory, so a checkout missing one case would
	// otherwise pass on whatever is left; the size floor below is not enough.
	var manifest struct {
		Cases []struct {
			File string `json:"file"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(privatefixtures.ReadFile(t, realCasesDir+"/manifest.json"), &manifest); err != nil {
		t.Fatalf("parse %s/manifest.json: %v", realCasesDir, err)
	}
	listed := map[string]bool{}
	for _, c := range manifest.Cases {
		listed[c.File] = true
	}
	present := map[string]bool{}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") && e.Name() != "manifest.json" && e.Name() != "edge-cases.json" {
			present[e.Name()] = true
		}
	}
	var missing, unlisted []string
	for f := range listed {
		if !present[f] {
			missing = append(missing, f)
		}
	}
	for f := range present {
		if !listed[f] {
			unlisted = append(unlisted, f)
		}
	}
	sort.Strings(missing)
	sort.Strings(unlisted)
	if len(listed) == 0 || len(missing) > 0 || len(unlisted) > 0 {
		t.Fatalf("%s: the case files and manifest.json disagree (manifest lists %d; missing %v; not in the manifest %v)",
			privatefixtures.Marker, len(listed), missing, unlisted)
	}
	var cases []conformanceCase
	for _, e := range entries {
		// edge-cases.json is the synthetic family (see twin_test.go): a different
		// schema, a single document rather than one file per case, and already
		// executed against Go by TestTwinArtifactsAreFresh, which regenerates
		// every expectation from Normalize and compares the whole file.
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") ||
			e.Name() == "manifest.json" || e.Name() == "edge-cases.json" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		var c conformanceCase
		if err := json.Unmarshal(b, &c); err != nil {
			t.Fatalf("parse %s: %v", e.Name(), err)
		}
		if c.Name == "" {
			t.Fatalf("%s has no name", e.Name())
		}
		cases = append(cases, c)
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].Name < cases[j].Name })
	return cases
}

func TestNormalizerConformance(t *testing.T) {
	cases := loadCases(t)
	if len(cases) < 30 {
		t.Fatalf("only %d conformance fixtures; the suite is meant to carry at least 30 "+
			"(regenerate with %s=1 go test ./gates/norm/ -run TestWriteNormalizerFixtures in server/oracle, with the corpus database)",
			len(cases), writeFixturesEnv)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			raw := mustB64(t, c.RawBase64)
			recv, err := time.Parse(time.RFC3339, c.ReceivedAt)
			if err != nil {
				t.Fatalf("received_at: %v", err)
			}
			got, err := Normalize(c.NormalizerVersion, raw, recv)
			if err != nil {
				t.Fatalf("Normalize: %v", err)
			}
			if want := string(mustB64(t, c.ExpectTextBase64)); got.Text != want {
				gotWin, wantWin := firstDiff(got.Text, want)
				t.Fatalf("Text mismatch around the first differing byte\n got %q\nwant %q", gotWin, wantWin)
			}
			if got.PartUsed != c.ExpectPart {
				t.Fatalf("PartUsed = %q, want %q", got.PartUsed, c.ExpectPart)
			}
			if got.Charset != c.ExpectCharset {
				t.Fatalf("Charset = %q, want %q", got.Charset, c.ExpectCharset)
			}
			if want := string(mustB64(t, c.ExpectSubjectBase64)); got.Subject != want {
				t.Fatalf("Subject = %q, want %q", got.Subject, want)
			}
			if want := string(mustB64(t, c.ExpectFromBase64)); got.From != want {
				t.Fatalf("From = %q, want %q", got.From, want)
			}
			if got.Forwarded != c.ExpectForwarded {
				t.Fatalf("Forwarded = %v, want %v", got.Forwarded, c.ExpectForwarded)
			}
			if got.DateSource != c.ExpectDateSource {
				t.Fatalf("DateSource = %q, want %q", got.DateSource, c.ExpectDateSource)
			}
			wantDate, err := time.Parse(time.RFC3339, c.ExpectEmailDate)
			if err != nil {
				t.Fatalf("expect_email_date: %v", err)
			}
			if !got.EmailDate.Equal(wantDate) {
				t.Fatalf("EmailDate = %v, want %v", got.EmailDate, wantDate)
			}
		})
	}
}

// TestConformanceCoversTheNamedShapes fails when a fixture the contract depends
// on has been dropped. Coverage that quietly shrinks is the failure mode a
// conformance suite exists to prevent.
func TestConformanceCoversTheNamedShapes(t *testing.T) {
	cases := loadCases(t)
	byName := map[string]conformanceCase{}
	parts := map[string]int{}
	var forwarded, fromHeaderDate, windows1256 int
	for _, c := range cases {
		byName[c.Name] = c
		parts[c.ExpectPart]++
		if c.ExpectForwarded {
			forwarded++
		}
		if c.ExpectDateSource == DateSourceForwardHeader {
			fromHeaderDate++
		}
		if c.ExpectCharset == "windows-1256" {
			windows1256++
		}
	}
	for _, required := range []string{
		"apple-forward-enbd-alert",
		"gmail-forward-1",
		"broken-mime-raw-fallback",
		"mislabelled-utf8-actually-windows-1256",
		"base64-continuation-indent",
		"quoted-forward-recovers-no-headers",
		"apple-forward-feff-line",
	} {
		if _, ok := byName[required]; !ok {
			t.Errorf("fixture %q is missing; it pins a named clause of the contract", required)
		}
	}
	for _, p := range []string{PartHTML, PartPlain, PartRaw} {
		if parts[p] == 0 {
			t.Errorf("no fixture exercises PartUsed=%q", p)
		}
	}
	if forwarded == 0 {
		t.Error("no forwarded fixture")
	}
	if fromHeaderDate == 0 {
		t.Error("no fixture whose EmailDate comes from a forward header")
	}
	if windows1256 == 0 {
		t.Error("no windows-1256 fixture; the charset conversion is unpinned")
	}

	// Whitespace inside a base64 payload must be skipped, not decoded and not
	// fatal, so indenting it changes nothing about the output. Asserting the two
	// texts are equal is what makes that a contract rather than a coincidence.
	plain, ok1 := byName["dib-arabic-01"]
	indented, ok2 := byName["base64-continuation-indent"]
	if ok1 && ok2 && plain.ExpectTextBase64 != indented.ExpectTextBase64 {
		t.Error("base64-continuation-indent must normalize byte-identically to dib-arabic-01; " +
			"embedded whitespace in a base64 payload is skipped, per RFC 2045")
	}

	// The raw fallback must still recover the headers. A message that failed
	// MIME parsing is exactly the message whose Subject the review queue needs.
	if raw, ok := byName["broken-mime-raw-fallback"]; ok {
		if raw.ExpectSubjectBase64 == "" || string(mustB64(t, raw.ExpectSubjectBase64)) == "" {
			t.Error("broken-mime-raw-fallback recovered no Subject; the ENBD alert template reads last4 from there")
		}
	}
}

func mustB64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("base64: %v", err)
	}
	return b
}

// firstDiff trims two strings to a window around their first difference so a
// failure on a 4 KB Arabic body is readable.
func firstDiff(got, want string) (string, string) {
	i := 0
	for i < len(got) && i < len(want) && got[i] == want[i] {
		i++
	}
	lo := i - 40
	if lo < 0 {
		lo = 0
	}
	clip := func(s string) string {
		hi := i + 40
		if hi > len(s) {
			hi = len(s)
		}
		if lo > len(s) {
			return ""
		}
		return s[lo:hi]
	}
	return clip(got), clip(want)
}

// ---------------------------------------------------------------------------
// The writer
// ---------------------------------------------------------------------------

// TestDerivedFixturesReproduceFromTheirSources re-runs every derive function
// over the committed raw bytes of its source case and requires the committed
// DERIVED case byte for byte. The writer needs the corpus database, which no
// checkout has; this pins the derivations themselves without it, so a change to
// a derive function (or to its public inputs) cannot silently disagree with the
// fixtures it once produced.
func TestDerivedFixturesReproduceFromTheirSources(t *testing.T) {
	byName := map[string]conformanceCase{}
	for _, c := range loadCases(t) {
		byName[c.Name] = c
	}
	idSource := map[int64]string{}
	for _, f := range corpusFixtures {
		if f.Derive == nil {
			if _, dup := idSource[f.ID]; !dup {
				idSource[f.ID] = f.Name
			}
		}
	}
	// gmail-forward-1 derives from id 6973, which is also apple-forward-enbd-alert
	// (verbatim); mislabelled-utf8 from 2695 (dib-windows1256-01); the other two
	// from 9 (dib-arabic-01).
	for _, f := range corpusFixtures {
		if f.Derive == nil {
			continue
		}
		t.Run(f.Name, func(t *testing.T) {
			srcName, ok := idSource[f.ID]
			if !ok {
				t.Fatalf("no verbatim case carries corpus id %d", f.ID)
			}
			src, ok := byName[srcName]
			if !ok {
				t.Fatalf("source case %s is missing", srcName)
			}
			want, ok := byName[f.Name]
			if !ok {
				t.Fatalf("derived case %s is missing", f.Name)
			}
			got := base64.StdEncoding.EncodeToString(f.Derive(mustB64(t, src.RawBase64)))
			if got != want.RawBase64 {
				g, w := firstDiff(string(mustB64(t, got)), string(mustB64(t, want.RawBase64)))
				t.Fatalf("derive(%s) no longer reproduces the committed %s\n got %q\nwant %q", srcName, f.Name, g, w)
			}
		})
	}
}
