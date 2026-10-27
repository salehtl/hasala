package tmpl

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	smsRunnerProbe   = "synthetic-dib-sms-purchase.json"
	smsRunnerProbeID = "dib.sms.purchase.v1"
)

func readProbeFixture(t *testing.T) templateFixture {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(templateConformanceDir, smsFixtureSubdir, smsRunnerProbe))
	if err != nil {
		t.Fatal(err)
	}
	var f templateFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if f.Template != smsRunnerProbeID || len(f.Cases) == 0 || !f.Cases[0].Expect.Matched {
		t.Fatalf("test setup: %s holds %s with %d cases", smsRunnerProbe, f.Template, len(f.Cases))
	}
	return f
}

func writeFixtureAt(t *testing.T, root, sub, name string, f templateFixture) {
	t.Helper()
	b, err := encodeTemplateFixture(f)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, sub), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, sub, name), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestTheTemplateRunnerReadsTheTextDirectories(t *testing.T) {
	public, private := t.TempDir(), t.TempDir()
	f := readProbeFixture(t)
	writeFixtureAt(t, public, smsFixtureSubdir, smsRunnerProbe, f)
	f.Kind = "corpus"
	writeFixtureAt(t, private, smsFixtureSubdir, "corpus-"+smsRunnerProbeID+".json", f)
	files, err := collectTemplateFixtures(public, private)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0].Template != smsRunnerProbeID || files[1].Template != smsRunnerProbeID {
		t.Fatalf("the runner read %d files from templates/sms, want the synthetic and the private one", len(files))
	}
	for _, f := range files {
		n, m, err := replayTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		if n != len(f.Cases) || m == 0 {
			t.Fatalf("%s %s: %d of %d cases replayed, %d matched", f.Kind, f.Template, n, len(f.Cases), m)
		}
	}
}

func TestTheTemplateRunnerFailsOnATextCaseEditedByHand(t *testing.T) {
	for _, tc := range []struct {
		field string
		edit  func(*templateExpect)
	}{
		{"matched", func(x *templateExpect) { x.Matched = false }},
		{"error", func(x *templateExpect) { x.Error = "no_match" }},
		{"amount_minor", func(x *templateExpect) { x.AmountMinor += "0" }},
		{"currency", func(x *templateExpect) { x.Currency = "USD" }},
		{"direction", func(x *templateExpect) { x.Direction = "credit" }},
		{"posted_at", func(x *templateExpect) { x.PostedAt = "" }},
		{"merchant", func(x *templateExpect) { x.Merchant += "X" }},
		{"last4", func(x *templateExpect) { x.Last4 = "9999" }},
		{"is_transfer", func(x *templateExpect) { x.IsTransfer = !x.IsTransfer }},
		{"empty_groups", func(x *templateExpect) { x.EmptyGroups = append(x.EmptyGroups, FieldMerchant) }},
	} {
		for _, private := range []bool{false, true} {
			kind := "synthetic"
			if private {
				kind = "corpus"
			}
			t.Run(kind+"/"+tc.field, func(t *testing.T) {
				public, privateDir := t.TempDir(), ""
				f := readProbeFixture(t)
				tc.edit(&f.Cases[0].Expect)
				if private {
					privateDir = t.TempDir()
					f.Kind = "corpus"
					writeFixtureAt(t, privateDir, smsFixtureSubdir, "corpus-"+smsRunnerProbeID+".json", f)
				} else {
					writeFixtureAt(t, public, smsFixtureSubdir, smsRunnerProbe, f)
				}
				files, err := collectTemplateFixtures(public, privateDir)
				if err != nil {
					t.Fatal(err)
				}
				if len(files) != 1 {
					t.Fatalf("the runner read %d files, want 1", len(files))
				}
				if _, _, err := replayTemplateFixture(files[0]); !errors.Is(err, errStaleFixture) {
					t.Fatalf("a hand-edited %s in templates/sms must make the runner fail, got %v", tc.field, err)
				}
			})
		}
	}
}

func TestTheTemplateRunnerRefusesATextFixtureOutsideTheTextDirectory(t *testing.T) {
	public := t.TempDir()
	writeFixtureAt(t, public, "", smsRunnerProbe, readProbeFixture(t))
	if _, err := collectTemplateFixtures(public, ""); err == nil || !strings.Contains(err.Error(), "belong in") {
		t.Fatalf("a text template's cases at the top of templates/ must be refused: %v", err)
	}
	public = t.TempDir()
	f := readProbeFixture(t)
	f.Kind = "corpus"
	writeFixtureAt(t, public, smsFixtureSubdir, "corpus-"+smsRunnerProbeID+".json", f)
	if _, err := collectTemplateFixtures(public, ""); err == nil || !strings.Contains(err.Error(), "real bank mail or texts") {
		t.Fatalf("a corpus file in this repository's templates/sms must be refused: %v", err)
	}
}

func TestTheSyntheticPinFailsOnATextCaseEditedByHand(t *testing.T) {
	root := t.TempDir()
	for _, sub := range []string{"", smsFixtureSubdir} {
		names, err := filepath.Glob(filepath.Join(templateConformanceDir, sub, "synthetic-*.json"))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(root, sub), 0o755); err != nil {
			t.Fatal(err)
		}
		for _, n := range names {
			b, err := os.ReadFile(n)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, sub, filepath.Base(n)), b, 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if drift := syntheticFixtureDrift(t, root); len(drift) != 0 {
		t.Fatalf("test setup: the copied tree drifts: %v", drift)
	}
	f := readProbeFixture(t)
	f.Cases[0].Expect.Merchant += "X"
	writeFixtureAt(t, root, smsFixtureSubdir, smsRunnerProbe, f)
	drift := syntheticFixtureDrift(t, root)
	if len(drift) != 1 || !strings.Contains(drift[0], smsFixtureSubdir+"/"+smsRunnerProbe+" is stale") {
		t.Fatalf("a hand-edited expectation in templates/sms must be reported stale: %v", drift)
	}
	writeFixtureAt(t, root, smsFixtureSubdir, smsRunnerProbe, readProbeFixture(t))
	writeFixtureAt(t, root, smsFixtureSubdir, "synthetic-stray.json", readProbeFixture(t))
	drift = syntheticFixtureDrift(t, root)
	if len(drift) != 1 || !strings.Contains(drift[0], smsFixtureSubdir+"/synthetic-stray.json is not written") {
		t.Fatalf("a synthetic file in templates/sms that no group writes must be reported: %v", drift)
	}
}
