package tmpl

// corpus_test.go writes conformance/templates/*.json — the shared half of the
// dual-executor contract for the EXECUTOR, as conformance/dialect/patterns.json
// is for the dialect.
//
// The dialect fixture proves the two validators agree about which patterns are
// legal, and the two engines agree about what those patterns match. Neither
// claim says anything about the executor built on top: first-entry-wins,
// override, on_match, the typed conversions, the three date layouts, the
// empty-group diagnostic and the required-field gate are all decisions ABOVE
// the regex engine, and every one of them is a place two hand-written
// implementations can differ while every regex in the template behaves
// identically.
//
// So this file runs the published seed templates over the operator's real v1
// mail — the same 7,002-message corpus the normalizer conformance is cut from —
// and records what Go's executor produced, field by field. The TypeScript side
// (client/src/tmpl/conformance.test.ts) re-runs the same inputs and demands the
// same answer. Neither side recomputes the other's expectation.
//
// # Why the inputs are already normalized
//
// A case carries norm.Result.Subject and norm.Result.Text, not raw RFC822. The
// normalizer has its own conformance set (conformance/normalizer/) which pins
// Go and TypeScript to byte-identical output over the same corpus; feeding raw
// mail in here would make every template disagreement indistinguishable from a
// normalizer disagreement. Two layers, two fixtures, two failures that name
// themselves.
//
// # Why one file per template rather than one per case
//
// The brief sketched one JSON file per case, each carrying its own copy of the
// definition. At the 500-case cap that is 1,500 files and about a megabyte of
// duplicated definition, in a directory nobody can read. One file per template
// carries the definition once and keeps `ls` meaningful; the TypeScript runner
// still declares one `test()` per case, so a failure still names the single
// message that broke.

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/privatefixtures"
)

// The fixture types, the seed template list and the writer's helpers live in
// fixtures.go, exported for the oracle module's corpus writer
// (server/oracle/gates/tmpl, spec 02 §4.3).
type (
	templateFixture = TemplateFixture
	templateCase    = TemplateCase
	templateExpect  = TemplateExpect
)

var (
	seedTemplateFiles     = SeedTemplateFiles
	expectOf              = ExpectOf
	encodeTemplateFixture = EncodeTemplateFixture
)

const (
	// templateConformanceDir holds the SYNTHETIC fixtures (synthetic-*.json),
	// which are committed here.
	templateConformanceDir = "../../../conformance/templates"
	// corpusTemplateDir is CorpusTemplateDir (fixtures.go).
	corpusTemplateDir = CorpusTemplateDir
)

// TestTemplateFixturesAreWhatThisBuildProduces is the guard against the
// committed set going stale, and it needs NO corpus: every case carries its own
// inputs, so the whole file can be re-executed from what is in the repository.
//
// Without it, a change to a conversion rule would leave the TypeScript executor
// checking itself against a snapshot of a Go executor that no longer exists —
// and it would keep passing, because both sides read the same stale file.
func TestTemplateFixturesAreWhatThisBuildProduces(t *testing.T) {
	files := readTemplateFixtures(t)
	// Every seed template must have a corpus file: a synthetic-only set would
	// prove the executor agrees with itself on inputs someone imagined.
	haveCorpus := map[string]bool{}
	for _, f := range files {
		if f.Kind == "corpus" {
			haveCorpus[f.Template] = true
		}
	}
	for _, name := range seedTemplateFiles {
		id := strings.TrimSuffix(name, ".json")
		if !haveCorpus[id] {
			t.Errorf("no corpus fixture for %s", id)
		}
	}
	total, matched := 0, 0
	for _, f := range files {
		d, err := ParseDefinition(f.Definition)
		if err != nil {
			t.Fatalf("%s: %v", f.Template, err)
		}
		if d.ID != f.Template {
			t.Errorf("%s: definition id is %q", f.Template, d.ID)
		}
		c, err := Compile(d)
		if err != nil {
			t.Fatalf("%s: %v", f.Template, err)
		}
		for _, tc := range f.Cases {
			subject := decodeB64(t, tc.SubjectBase64)
			body := decodeB64(t, tc.NormalizedBodyBase64)
			e, execErr := c.Execute(subject, body)
			got := expectOf(e, execErr)
			if !sameExpect(got, tc.Expect) {
				t.Fatalf("%s is stale: %s\n got %+v\nwant %+v\nregenerate with\n"+
					"  %s=1 go test ./gates/tmpl/ -run TestWriteTemplateFixtures in server/oracle, with the corpus database",
					f.Template, tc.Name, got, tc.Expect, writeFixturesEnv)
			}
			total++
			if tc.Expect.Matched {
				matched++
			}
		}
	}
	// A fixture set that matched nothing would pass every assertion above while
	// proving nothing about extraction.
	if matched < 100 {
		t.Fatalf("only %d of %d cases matched; the fixture set is not exercising extraction", matched, total)
	}
	t.Logf("%d cases across %d templates, %d matched", total, len(files), matched)
}

// TestTemplateFixturesCoverEveryFieldAndEveryFailureMode is the check that the
// committed set is worth running. A conformance corpus that happens to contain
// only successful card purchases would agree perfectly and say nothing about
// the date fallback, the empty-group diagnostic or the required-field gate.
func TestTemplateFixturesCoverEveryFieldAndEveryFailureMode(t *testing.T) {
	files := readTemplateFixtures(t)
	var (
		amounts, dates, merchants, last4s, credits, debits, transfers int
		emptyGroups, noMatch, missingField                            int
	)
	for _, f := range files {
		for _, c := range f.Cases {
			x := c.Expect
			if x.Currency != "" {
				amounts++
			}
			if x.PostedAt != "" {
				dates++
			}
			if x.Merchant != "" {
				merchants++
			}
			if x.Last4 != "" {
				last4s++
			}
			switch x.Direction {
			case "credit":
				credits++
			case "debit":
				debits++
			}
			if x.IsTransfer {
				transfers++
			}
			if len(x.EmptyGroups) > 0 {
				emptyGroups++
			}
			switch x.Error {
			case "no_match":
				noMatch++
			case "missing_field":
				missingField++
			}
		}
	}
	for _, c := range []struct {
		name string
		n    int
	}{
		{"amounts", amounts}, {"body dates", dates}, {"merchants", merchants},
		{"last4s", last4s}, {"credits", credits}, {"debits", debits},
		{"is_transfer", transfers}, {"empty capture groups", emptyGroups},
		{"gated-out (no_match)", noMatch}, {"required-field failures", missingField},
	} {
		if c.n == 0 {
			t.Errorf("no committed case exercises %s; the two executors cannot be compared on it", c.name)
		}
	}
	t.Logf("amounts=%d dates=%d merchants=%d last4=%d credit=%d debit=%d transfer=%d empty_groups=%d no_match=%d missing_field=%d",
		amounts, dates, merchants, last4s, credits, debits, transfers, emptyGroups, noMatch, missingField)
}

// readTemplateFixtures returns the whole committed set: the real-mail
// corpus-*.json files from the private checkout and the synthetic-*.json files
// from this repository, in file-name order. It skips the calling test when
// HASALA_PRIVATE_FIXTURES is unset, because every assertion made over this set
// (a corpus file per seed template, >= 100 matched cases, every field and
// failure mode covered) is a claim about the real mail; the synthetic files on
// their own are pinned by TestSyntheticFixturesAreWhatThisBuildProduces.
func readTemplateFixtures(t *testing.T) []templateFixture {
	t.Helper()
	corpusNames, err := filepath.Glob(filepath.Join(privatefixtures.Path(t, corpusTemplateDir), "corpus-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	syntheticNames, err := filepath.Glob(filepath.Join(templateConformanceDir, "synthetic-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if public, _ := filepath.Glob(filepath.Join(templateConformanceDir, "corpus-*.json")); len(public) > 0 {
		t.Fatalf("%v: corpus fixtures are real mail and belong in %s, not in this repository", public, privatefixtures.Repo)
	}
	names := append(corpusNames, syntheticNames...)
	sort.Slice(names, func(i, j int) bool { return filepath.Base(names[i]) < filepath.Base(names[j]) })
	out := make([]templateFixture, 0, len(names))
	for _, n := range names {
		b, err := os.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		var f templateFixture
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatalf("%s: %v", n, err)
		}
		if len(f.Cases) == 0 {
			t.Fatalf("%s has no cases", n)
		}
		out = append(out, f)
	}
	return out
}

func decodeB64(t *testing.T, s string) string {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func sameExpect(a, b templateExpect) bool {
	if a.Matched != b.Matched || a.Error != b.Error || a.AmountMinor != b.AmountMinor ||
		a.Currency != b.Currency || a.Direction != b.Direction || a.PostedAt != b.PostedAt ||
		a.Merchant != b.Merchant || a.Last4 != b.Last4 || a.IsTransfer != b.IsTransfer ||
		len(a.EmptyGroups) != len(b.EmptyGroups) {
		return false
	}
	for i := range a.EmptyGroups {
		if a.EmptyGroups[i] != b.EmptyGroups[i] {
			return false
		}
	}
	return true
}
