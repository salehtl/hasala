package tmpl_test

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	. "github.com/salehtl/hasala/server/internal/tmpl"
)

var derivedCorpusSources = map[string]string{
	"dib.transfer.v1":       "dib.account.v1",
	"dib.money-transfer.v1": "dib.account.v1",
	"dib.card-refund.v1":    "dib.account.v1",
	"dib.card-reversal.v1":  "dib.account.v1",
}

func TestWriteDerivedTemplateFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Fatalf("%s is unset: corpus fixtures are real mail and are written only into a checkout of %s, "+
			"never into this repository", privatefixtures.EnvVar, privatefixtures.Repo)
	}
	defs, raws, err := LoadSeedTemplates(seedDir)
	if err != nil {
		t.Fatal(err)
	}
	outDir := filepath.Join(root, filepath.FromSlash(CorpusTemplateDir))
	written := 0
	for i, d := range defs {
		src, ok := derivedCorpusSources[d.ID]
		if !ok || !templateFilter(d.ID) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(outDir, "corpus-"+src+".json"))
		if err != nil {
			t.Fatal(err)
		}
		var from TemplateFixture
		if err := json.Unmarshal(b, &from); err != nil {
			t.Fatal(err)
		}
		var srcDef Definition
		if srcDef, err = ParseDefinition(from.Definition); err != nil {
			t.Fatal(err)
		}
		if strings.Join(srcDef.Match.SenderDomain, ",") != strings.Join(d.Match.SenderDomain, ",") {
			t.Fatalf("%s gates on %v, %s on %v: the sample of one is not the sample of the other",
				d.ID, d.Match.SenderDomain, src, srcDef.Match.SenderDomain)
		}
		if from.Kind != "corpus" || from.NormalizerVersion != norm.CurrentVersion || len(from.Cases) == 0 {
			t.Fatalf("corpus-%s.json is not a corpus fixture of this normalizer", src)
		}
		f := TemplateFixture{
			Note: "Written by server/oracle/gates/tmpl TestWriteDerivedTemplateFixtures from the inputs of corpus-" + src +
				".json, which TestWriteTemplateFixtures sampled by even stride from every v1 corpus message sent from " +
				strings.Join(d.Match.SenderDomain, ", ") + ": the same messages that writer samples for this template, " +
				"whose sender domains are the same. Regenerate with HASALA_WRITE_CONFORMANCE=1 HASALA_PRIVATE_FIXTURES=... " +
				"go test ./gates/tmpl/ -run TestWriteDerivedTemplateFixtures (in server/oracle), or with the corpus " +
				"database through TestWriteTemplateFixtures; do not hand-edit. `expect` is LITERAL Go executor output. " +
				"Subject and body are the NORMALIZED forms (norm.Result.Subject and norm.Result.Text), base64.",
			Spec:              "server/internal/tmpl/v2-template-format.md",
			SchemaVersion:     1,
			Template:          d.ID,
			Kind:              "corpus",
			NormalizerVersion: norm.CurrentVersion,
			Definition:        raws[i],
			Cases:             []TemplateCase{},
		}
		matched := 0
		for _, c := range from.Cases {
			subject, err := base64.StdEncoding.DecodeString(c.SubjectBase64)
			if err != nil {
				t.Fatal(err)
			}
			body, err := base64.StdEncoding.DecodeString(c.NormalizedBodyBase64)
			if err != nil {
				t.Fatal(err)
			}
			e, execErr := Execute(d, string(subject), string(body))
			if e.Matched {
				matched++
			}
			f.Cases = append(f.Cases, TemplateCase{
				Name:                 d.ID + strings.TrimPrefix(c.Name, src),
				Source:               c.Source + ", the inputs of corpus-" + src + ".json",
				SubjectBase64:        c.SubjectBase64,
				NormalizedBodyBase64: c.NormalizedBodyBase64,
				Expect:               ExpectOf(e, execErr),
			})
		}
		out, err := EncodeTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(outDir, "corpus-"+d.ID+".json"), out, 0o644); err != nil {
			t.Fatal(err)
		}
		written++
		t.Logf("%s: %d cases from corpus-%s.json, %d matched, %d bytes", d.ID, len(f.Cases), src, matched, len(out))
	}
	if written == 0 {
		t.Fatalf("no seed template is derived from another's corpus fixture")
	}
}
