package tmpl_test

// The corpus-reading half of internal/tmpl's conformance suite, moved to the
// oracle module with the corpus reader (spec 02 §4.3): the corpus fixture
// writer. The fixture types are internal/tmpl's exported TemplateFixture and
// friends (fixtures.go).

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	. "github.com/salehtl/hasala/server/internal/tmpl"
	"github.com/salehtl/hasala/server/oracle/corpus"
)

// writeFixturesEnv gates the writer: a test that rewrites its own reference
// on every run pins nothing.
const writeFixturesEnv = "HASALA_WRITE_CONFORMANCE"

// seedDir is internal/tmpl/testdata, where the seed templates live.
const seedDir = "../../../internal/tmpl/testdata"

// templateFixtureCap bounds the cases written per template. The cap exists
// so the committed set stays reviewable, NOT because it is the whole check:
// crossexec_test.go exports every message the corpus holds, and Task 21's
// gate is the full corpus. Sampling is by even stride over the corpus in id
// order, which is chronological, so the three years are represented in
// proportion rather than the fixture being three months of whatever sorted
// first.
const templateFixtureCap = 500

// templateFilterEnv narrows a regeneration to the named templates (comma
// separated ids, e.g. "enbd.transfer.v1,enbd.alert.v1").
//
// It exists because the four corpus files are cut from DIFFERENT snapshots and
// a regeneration resamples: the two DIB files hold 500 sampled cases each out
// of ~6,900 eligible messages, so re-running them against a corpus that has
// grown by a day of ingest moves the even stride and rewrites ~10,500 lines of
// fixture — a diff nobody reads, carrying a bulk re-import of the operator's
// real mail, for a change that touched neither DIB template. The two ENBD files
// are ~60 cases each and rewrite cleanly.
//
// It narrows the WRITER only. [TestTemplateFixturesAreWhatThisBuildProduces]
// re-executes every committed file on every run regardless, so a file left
// unregenerated is still checked — it is not excused, only not resampled.
const templateFilterEnv = "HASALA_TEMPLATE_FIXTURE_ONLY"

// templateFilter reports whether a template id is in scope for a regeneration.
func templateFilter(id string) bool {
	only := os.Getenv(templateFilterEnv)
	if only == "" {
		return true
	}
	for _, want := range strings.Split(only, ",") {
		if strings.TrimSpace(want) == id {
			return true
		}
	}
	return false
}

// senderDomain pulls the domain out of a v1 ingest_log from_addr.
//
// This is NOT the trusted-lane check: v1 stored the From header, which is
// content. It is only used here to decide which template a corpus message is
// worth running, and running the wrong template merely produces a no-match
// case. The real gate is MatchesSenderDomain over the DKIM/ARC-verified domain,
// and TestMatchesSenderDomainIsASuffixMatchOnLabelBoundaries covers it.
func senderDomain(fromAddr string) string {
	at := strings.LastIndex(fromAddr, "@")
	if at < 0 {
		return ""
	}
	d := strings.TrimSpace(fromAddr[at+1:])
	d = strings.TrimSuffix(strings.Trim(d, "<>"), ".")
	return ASCIILower(d)
}

// sampleEvenly picks at most limit values from ids by an even stride, always
// keeping the first and last so the fixture spans the whole corpus rather than
// its middle.
func sampleEvenly(ids []int64, limit int) []int64 {
	if len(ids) <= limit || limit <= 0 {
		return ids
	}
	out := make([]int64, 0, limit)
	// Fixed-point stride so the picks are spread across the whole range and the
	// result is exactly cap long regardless of len(ids).
	for i := 0; i < limit; i++ {
		j := int(int64(i) * int64(len(ids)-1) / int64(limit-1))
		out = append(out, ids[j])
	}
	return out
}

// TestWriteTemplateFixtures regenerates conformance/templates/corpus-*.json
// from a scratch .backup copy of the v1 corpus. The files are real mail, so
// they are written into the PRIVATE fixtures checkout and committed there.
//
//	HASALA_WRITE_CONFORMANCE=1 HASALA_CORPUS_DB=/scratch/corpus.db \
//	HASALA_PRIVATE_FIXTURES=/path/to/hasala-fixtures \
//	  go test ./gates/tmpl/ -run TestWriteTemplateFixtures -timeout 20m -v   # in server/oracle
//
// Add HASALA_TEMPLATE_FIXTURE_ONLY=<id>[,<id>] to rewrite only the named
// templates' files; see [templateFilterEnv] for why that is worth having.
func TestWriteTemplateFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; see server/oracle/corpus for how to make the .backup copy")
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Fatalf("%s is unset: corpus fixtures are real mail and are written only into a checkout of %s, "+
			"never into this repository", privatefixtures.EnvVar, privatefixtures.Repo)
	}
	outDir := filepath.Join(root, filepath.FromSlash(CorpusTemplateDir))
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	defs, raws, err := LoadSeedTemplates(seedDir)
	if err != nil {
		t.Fatal(err)
	}

	// Pass 1: which corpus ids each template is worth running, decided on the
	// sender domain alone so nothing is decompressed twice.
	eligible := make([][]int64, len(defs))
	if err := db.Each(func(m corpus.Message) error {
		dom := senderDomain(m.FromAddr)
		for i, d := range defs {
			if MatchesSenderDomain(d, dom) {
				eligible[i] = append(eligible[i], m.ID)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	wanted := map[int64]bool{}
	picked := make([][]int64, len(defs))
	for i := range defs {
		if !templateFilter(defs[i].ID) {
			continue
		}
		picked[i] = sampleEvenly(eligible[i], templateFixtureCap)
		for _, id := range picked[i] {
			wanted[id] = true
		}
	}

	// Pass 2: normalize the sampled messages once each, whatever templates want
	// them.
	type msg struct {
		subject string
		body    string
		normErr error
	}
	byID := map[int64]msg{}
	if err := db.Each(func(m corpus.Message) error {
		if !wanted[m.ID] {
			return nil
		}
		r, err := norm.Normalize(norm.CurrentVersion, m.RawBody, m.ReceivedAt)
		byID[m.ID] = msg{subject: r.Subject, body: r.Text, normErr: err}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for i, d := range defs {
		if !templateFilter(d.ID) {
			t.Logf("%s: skipped, %s does not name it", d.ID, templateFilterEnv)
			continue
		}
		f := TemplateFixture{
			Note: "Written by server/oracle/gates/tmpl TestWriteTemplateFixtures over the operator's v1 mail corpus. " +
				"Regenerate with HASALA_WRITE_CONFORMANCE=1 HASALA_CORPUS_DB=... go test ./gates/tmpl/ " +
				"-run TestWriteTemplateFixtures (in server/oracle); do not hand-edit. `expect` is LITERAL Go executor output, never " +
				"recomputed by the reader: a conformance harness that derives its own expectation cannot see a " +
				"defect in the thing it is checking. Subject and body are the NORMALIZED forms (norm.Result.Subject " +
				"and norm.Result.Text), base64 because they carry CR, U+FEFF, bidi controls and Arabic.",
			Spec:              "server/internal/tmpl/v2-template-format.md",
			SchemaVersion:     1,
			Template:          d.ID,
			Kind:              "corpus",
			NormalizerVersion: norm.CurrentVersion,
			Definition:        raws[i],
			Cases:             []TemplateCase{},
		}
		skipped := 0
		for _, id := range picked[i] {
			m := byID[id]
			if m.normErr != nil {
				// A message the normalizer refuses never reaches a template, so
				// it is not a template conformance case.
				skipped++
				continue
			}
			e, execErr := Execute(d, m.subject, m.body)
			f.Cases = append(f.Cases, TemplateCase{
				Name:                 fmt.Sprintf("%s/%06d", d.ID, id),
				Source:               fmt.Sprintf("v1 corpus ingest_log id %d, normalized with norm v%d", id, norm.CurrentVersion),
				SubjectBase64:        base64.StdEncoding.EncodeToString([]byte(m.subject)),
				NormalizedBodyBase64: base64.StdEncoding.EncodeToString([]byte(m.body)),
				Expect:               ExpectOf(e, execErr),
			})
		}
		out := filepath.Join(outDir, "corpus-"+d.ID+".json")
		b, err := EncodeTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(out, b, 0o644); err != nil {
			t.Fatal(err)
		}
		matched := 0
		for _, c := range f.Cases {
			if c.Expect.Matched {
				matched++
			}
		}
		t.Logf("%s: %d eligible, %d sampled, %d written (%d matched, %d unreadable by the normalizer), %d bytes",
			d.ID, len(eligible[i]), len(picked[i]), len(f.Cases), matched, skipped, len(b))
	}
}
