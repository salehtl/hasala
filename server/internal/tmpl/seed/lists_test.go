package seed

import (
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"slices"
	"testing"

	"github.com/salehtl/hasala/server/internal/privatefixtures"
	"github.com/salehtl/hasala/server/internal/tmpl"
)

func TestTheMailSeedFilesAreTheMailSeeds(t *testing.T) {
	var want []string
	for _, d := range Seed() {
		if !d.IsSMS() {
			want = append(want, d.ID+".json")
		}
	}
	slices.Sort(want)
	got := slices.Sorted(slices.Values(tmpl.MailSeedTemplateFiles))
	if !slices.Equal(got, want) {
		t.Fatalf("tmpl.MailSeedTemplateFiles names %v, but the mail seeds in IDs are %v", got, want)
	}
	onDisk, err := filepath.Glob(filepath.Join("..", "testdata", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, p := range onDisk {
		names = append(names, filepath.Base(p))
	}
	slices.Sort(names)
	if !slices.Equal(names, want) {
		t.Fatalf("internal/tmpl/testdata holds %v, but the mail seeds in IDs are %v", names, want)
	}
	defs, _, err := tmpl.LoadMailSeedTemplates(filepath.Join("..", "testdata"))
	if err != nil {
		t.Fatal(err)
	}
	for i, d := range defs {
		if d.IsSMS() || d.ID+".json" != tmpl.MailSeedTemplateFiles[i] {
			t.Errorf("%s holds %s (sms %v)", tmpl.MailSeedTemplateFiles[i], d.ID, d.IsSMS())
		}
	}
}

func TestEverySeedTemplateHasACorpusFixture(t *testing.T) {
	for _, d := range Seed() {
		dir := tmpl.CorpusTemplateDir
		if d.IsSMS() {
			dir = smsCorpusDir
		}
		rel := path.Join(dir, "corpus-"+d.ID+".json")
		b, err := os.ReadFile(privatefixtures.Path(t, rel))
		if err != nil {
			t.Fatal(err)
		}
		var f tmpl.TemplateFixture
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		if f.Kind != "corpus" || f.Template != d.ID || len(f.Cases) == 0 {
			t.Errorf("%s: kind %q, template %q, %d cases; want a corpus fixture of %s", rel, f.Kind, f.Template, len(f.Cases), d.ID)
		}
		fd, err := tmpl.ParseDefinition(f.Definition)
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		if fd.ID != d.ID || fd.IsSMS() != d.IsSMS() {
			t.Errorf("%s holds the definition of %s (sms %v)", rel, fd.ID, fd.IsSMS())
		}
	}
}
