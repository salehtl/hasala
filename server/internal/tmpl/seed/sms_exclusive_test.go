package seed

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/salehtl/hasala/server/internal/tmpl"
)

const publicSMSFixtureDir = "../../../../conformance/templates/sms"

func TestTheTextTemplatesAreTriedInIDOrder(t *testing.T) {
	s := loadSMSTemplates(t)
	ids := make([]string, len(s.defs))
	for i, d := range s.defs {
		ids[i] = d.ID
		if s.compiled[i].Definition().ID != d.ID {
			t.Fatalf("compiled template %d is %s, definition %s", i, s.compiled[i].Definition().ID, d.ID)
		}
	}
	if !slices.IsSorted(ids) {
		t.Fatalf("the text templates are tried in the order %v; Swift tries the bundle's manifest order, which is ID order", ids)
	}
}

func TestNoSyntheticTextIsReadByTwoTextTemplates(t *testing.T) {
	s := loadSMSTemplates(t)
	names, err := filepath.Glob(filepath.Join(publicSMSFixtureDir, "synthetic-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(names) < len(s.defs) {
		t.Fatalf("%d synthetic text files in %s, want one per text template at least", len(names), publicSMSFixtureDir)
	}
	cases, own := 0, map[string]int{}
	for _, n := range names {
		b, err := os.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		var f tmpl.TemplateFixture
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatalf("%s: %v", n, err)
		}
		for _, c := range f.Cases {
			body, err := base64.StdEncoding.DecodeString(c.NormalizedBodyBase64)
			if err != nil {
				t.Fatalf("%s %s: %v", f.Template, c.Name, err)
			}
			cases++
			readBy, _, _, matched := s.run(string(body))
			if len(matched) > 1 {
				t.Errorf("%s %s is read by %v: which template reads it would depend on the order they are tried in", f.Template, c.Name, matched)
			}
			if s.byID(f.Template) != nil && c.Expect.Matched {
				own[f.Template]++
				if readBy != f.Template {
					t.Errorf("%s %s: its own template reads it, but the first hit is %q", f.Template, c.Name, readBy)
				}
			}
		}
	}
	for _, d := range s.defs {
		if own[d.ID] == 0 {
			t.Errorf("no synthetic case is read by %s", d.ID)
		}
	}
	t.Logf("%d synthetic text cases, read by their own template: %v", cases, own)
}

func TestTheOverlapCheckSeesATextReadTwice(t *testing.T) {
	s := loadSMSTemplates(t)
	purchase := s.byID(smsTemplateID("purchase")).Definition()
	twin := purchase
	twin.ID = "dib.sms.purchase-twin.v1"
	c, err := tmpl.Compile(twin)
	if err != nil {
		t.Fatal(err)
	}
	s.defs = append(slices.Clone(s.defs), twin)
	s.compiled = append(slices.Clone(s.compiled), c)
	body := "مشتريات بمبلغ 123.45 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
	readBy, _, _, matched := s.run(body)
	if readBy != purchase.ID || !slices.Equal(matched, []string{purchase.ID, twin.ID}) {
		t.Fatalf("read by %q, matched %v; want both purchase templates", readBy, matched)
	}
}
