package seed

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
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
	privatefixtures.Path(t, smsCorpusDir)
	for _, gap := range corpusFixtureGaps(privatefixtures.Root(), Seed()) {
		t.Error(gap)
	}
}

func corpusFixtureGaps(root string, defs []tmpl.Definition) []string {
	var gaps []string
	for _, d := range defs {
		dir := tmpl.CorpusTemplateDir
		if d.IsSMS() {
			dir = smsCorpusDir
		}
		rel := path.Join(dir, "corpus-"+d.ID+".json")
		b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			gaps = append(gaps, fmt.Sprintf("no corpus fixture for %s: %v", d.ID, err))
			continue
		}
		var f tmpl.TemplateFixture
		if err := json.Unmarshal(b, &f); err != nil {
			gaps = append(gaps, fmt.Sprintf("%s: %v", rel, err))
			continue
		}
		if f.Kind != "corpus" || f.Template != d.ID || len(f.Cases) == 0 {
			gaps = append(gaps, fmt.Sprintf("%s: kind %q, template %q, %d cases; want a corpus fixture of %s", rel, f.Kind, f.Template, len(f.Cases), d.ID))
			continue
		}
		fd, err := tmpl.ParseDefinition(f.Definition)
		if err != nil {
			gaps = append(gaps, fmt.Sprintf("%s: %v", rel, err))
			continue
		}
		if fd.ID != d.ID || fd.IsSMS() != d.IsSMS() {
			gaps = append(gaps, fmt.Sprintf("%s holds the definition of %s (sms %v)", rel, fd.ID, fd.IsSMS()))
		}
	}
	return gaps
}

func standInCorpusRoot(t *testing.T, skip string) string {
	t.Helper()
	root := t.TempDir()
	raw := Raw()
	for _, d := range Seed() {
		if d.ID == skip {
			continue
		}
		dir := tmpl.CorpusTemplateDir
		if d.IsSMS() {
			dir = smsCorpusDir
		}
		f := tmpl.TemplateFixture{Kind: "corpus", Template: d.ID, Definition: compactJSON(t, raw[d.ID]), Cases: []tmpl.TemplateCase{{Name: d.ID + "/0001"}}}
		b, err := json.Marshal(f)
		if err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(root, filepath.FromSlash(path.Join(dir, "corpus-"+d.ID+".json")))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestTheCorpusPerSeedCheckFailsWithoutATextSeedsCorpus(t *testing.T) {
	if gaps := corpusFixtureGaps(standInCorpusRoot(t, ""), Seed()); len(gaps) != 0 {
		t.Fatalf("test setup: a stand-in for every seed still leaves gaps: %v", gaps)
	}
	debit := smsTemplateID("debit")
	gaps := corpusFixtureGaps(standInCorpusRoot(t, debit), Seed())
	if len(gaps) != 1 || !strings.Contains(gaps[0], "no corpus fixture for "+debit) {
		t.Fatalf("a text seed with no templates/sms/corpus-%s.json must fail the check: %v", debit, gaps)
	}
	root := standInCorpusRoot(t, "")
	from := filepath.Join(root, filepath.FromSlash(smsCorpusDir), "corpus-"+debit+".json")
	if err := os.Rename(from, filepath.Join(root, filepath.FromSlash(tmpl.CorpusTemplateDir), "corpus-"+debit+".json")); err != nil {
		t.Fatal(err)
	}
	gaps = corpusFixtureGaps(root, Seed())
	if len(gaps) != 1 || !strings.Contains(gaps[0], "no corpus fixture for "+debit) {
		t.Fatalf("a text seed's corpus in the mail directory must fail the check: %v", gaps)
	}
}

func TestTheCorpusPerSeedCheckFailsOnThePrivateFixturesLessOneTextCorpus(t *testing.T) {
	private := privatefixtures.Path(t, smsCorpusDir)
	root := t.TempDir()
	debit := smsTemplateID("debit")
	linked := 0
	for _, dir := range []string{tmpl.CorpusTemplateDir, smsCorpusDir} {
		src := filepath.Join(privatefixtures.Root(), filepath.FromSlash(dir))
		names, err := filepath.Glob(filepath.Join(src, "corpus-*.json"))
		if err != nil {
			t.Fatal(err)
		}
		dst := filepath.Join(root, filepath.FromSlash(dir))
		if err := os.MkdirAll(dst, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, n := range names {
			if src == private && filepath.Base(n) == "corpus-"+debit+".json" {
				continue
			}
			if err := os.Symlink(n, filepath.Join(dst, filepath.Base(n))); err != nil {
				t.Fatal(err)
			}
			linked++
		}
	}
	if linked != len(Seed())-1 {
		t.Fatalf("test setup: linked %d private corpus files, want %d", linked, len(Seed())-1)
	}
	gaps := corpusFixtureGaps(root, Seed())
	if len(gaps) != 1 || !strings.Contains(gaps[0], "no corpus fixture for "+debit) {
		t.Fatalf("%s the private fixtures less templates/sms/corpus-%s.json must fail the check: %d gaps", privatefixtures.Marker, debit, len(gaps))
	}
}

func TestTheTextSeedsCarryTheirTransferRoles(t *testing.T) {
	want := map[string]string{
		"dib.sms.own-transfer.v1": tmpl.TransferRoleNotice,
		"dib.sms.debit.v1":        tmpl.TransferRoleAlert,
	}
	seen := 0
	for _, d := range Seed() {
		if d.TransferRole != want[d.ID] {
			t.Errorf("%s has transfer_role %q, want %q", d.ID, d.TransferRole, want[d.ID])
		}
		if _, ok := want[d.ID]; ok {
			seen++
		}
	}
	if seen != len(want) {
		t.Fatalf("%d of the %d roled text seeds are in Seed()", seen, len(want))
	}
}
