package tmpl_test

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	. "github.com/salehtl/hasala/server/internal/tmpl"
)

const EMLTemplateDir = "conformance/templates/eml"

func emlTemplateIDs(root string) (map[string]bool, error) {
	out := map[string]bool{}
	if root == "" {
		return out, nil
	}
	entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(EMLTemplateDir)))
	if os.IsNotExist(err) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() {
			out[e.Name()] = true
		}
	}
	return out, nil
}

func emlFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".eml") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

func TestWriteEMLTemplateFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Fatalf("%s is unset: corpus fixtures are real mail and are written only into a checkout of %s, "+
			"never into this repository", privatefixtures.EnvVar, privatefixtures.Repo)
	}
	ids, err := emlTemplateIDs(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) == 0 {
		t.Fatalf("%s holds no template directories", filepath.Join(root, EMLTemplateDir))
	}
	defs, raws, err := LoadMailSeedTemplates(seedDir)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	outDir := filepath.Join(root, filepath.FromSlash(CorpusTemplateDir))
	for i, d := range defs {
		if !ids[d.ID] || !templateFilter(d.ID) {
			continue
		}
		seen[d.ID] = true
		dir := filepath.Join(root, filepath.FromSlash(EMLTemplateDir), d.ID)
		names, err := emlFiles(dir)
		if err != nil {
			t.Fatal(err)
		}
		f := TemplateFixture{
			Note: "Written by server/oracle/gates/tmpl TestWriteEMLTemplateFixtures from the raw messages in " +
				EMLTemplateDir + "/" + d.ID + "/. Regenerate with HASALA_WRITE_CONFORMANCE=1 " +
				"HASALA_PRIVATE_FIXTURES=... go test ./gates/tmpl/ -run TestWriteEMLTemplateFixtures (in server/oracle); " +
				"do not hand-edit. `expect` is LITERAL Go executor output. Subject and body are the NORMALIZED forms " +
				"(norm.Result.Subject and norm.Result.Text), base64.",
			Spec:              "server/internal/tmpl/v2-template-format.md",
			SchemaVersion:     1,
			Template:          d.ID,
			Kind:              "corpus",
			NormalizerVersion: norm.CurrentVersion,
			Definition:        raws[i],
			Cases:             []TemplateCase{},
		}
		skipped := 0
		for _, name := range names {
			raw, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				t.Fatal(err)
			}
			r, err := norm.Normalize(norm.CurrentVersion, raw, time.Unix(0, 0).UTC())
			if err != nil {
				skipped++
				continue
			}
			e, execErr := Execute(d, r.Subject, r.Text)
			f.Cases = append(f.Cases, TemplateCase{
				Name:                 d.ID + "/" + strings.TrimSuffix(name, ".eml"),
				Source:               fmt.Sprintf("%s/%s/%s, normalized with norm v%d", EMLTemplateDir, d.ID, name, norm.CurrentVersion),
				SubjectBase64:        base64.StdEncoding.EncodeToString([]byte(r.Subject)),
				NormalizedBodyBase64: base64.StdEncoding.EncodeToString([]byte(r.Text)),
				Expect:               ExpectOf(e, execErr),
			})
		}
		if len(f.Cases) == 0 {
			t.Fatalf("%s: no message in %s reaches the template", d.ID, dir)
		}
		b, err := EncodeTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(outDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(outDir, "corpus-"+d.ID+".json"), b, 0o644); err != nil {
			t.Fatal(err)
		}
		matched := 0
		for _, c := range f.Cases {
			if c.Expect.Matched {
				matched++
			}
		}
		t.Logf("%s: %d messages, %d written (%d matched, %d unreadable by the normalizer), %d bytes",
			d.ID, len(names), len(f.Cases), matched, skipped, len(b))
	}
	for id := range ids {
		if !seen[id] && templateFilter(id) {
			t.Errorf("%s/%s names no seed template", EMLTemplateDir, id)
		}
	}
}
