package seed

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	"github.com/salehtl/hasala/server/internal/tmpl"
)

const (
	smsCorpusDir    = "conformance/sms"
	smsExportEnv    = "HASALA_SMS_EXPORT"
	writeCorpusEnv  = "HASALA_WRITE_CONFORMANCE"
	smsFamilyOther  = "other"
	smsCorpusSender = "DIB-SMS"
)

var smsFamilies = []string{
	"purchase", "debit", "credit", "salary", "refund", "reversal", "own-transfer", "card-payment", smsFamilyOther,
}

type smsCorpusFile struct {
	Note              string          `json:"note"`
	SchemaVersion     int             `json:"schema_version"`
	Kind              string          `json:"kind"`
	Family            string          `json:"family"`
	NormalizerVersion int             `json:"normalizer_version"`
	Cases             []smsCorpusCase `json:"cases"`
}

type smsCorpusCase struct {
	Name             string              `json:"name"`
	Sender           string              `json:"sender"`
	ReceivedAt       string              `json:"received_at"`
	TextBase64       string              `json:"text_base64"`
	NormalizedBase64 string              `json:"normalized_base64"`
	Template         string              `json:"template"`
	Gated            []string            `json:"gated"`
	Expect           tmpl.TemplateExpect `json:"expect"`
}

type smsReading struct {
	family      string
	amountMinor int64
	currency    string
	direction   string
}

var smsFamilyDirection = map[string]string{
	"purchase": "debit", "debit": "debit", "own-transfer": "debit",
	"credit": "credit", "salary": "credit", "refund": "credit", "reversal": "credit", "card-payment": "credit",
}

func independentFamily(text string) string {
	has := strings.HasPrefix
	switch {
	case has(text, "مشتريات بمبلغ "):
		return "purchase"
	case has(text, "تحويل بين حساباتك "):
		return "own-transfer"
	case has(text, "تم سداد مبلغ "):
		return "card-payment"
	case has(text, "تم إرجاع مبلغ "):
		return "refund"
	case has(text, "A transaction to the value of ") && strings.Contains(text, " has been reversed."):
		return "reversal"
	case has(text, "إيداع راتب "), has(text, "ايداع راتب "), has(text, "تم ايداع راتب "), has(text, "تم إيداع راتب "):
		return "salary"
	case has(text, "ايداع "), has(text, "إيداع "):
		return "credit"
	case has(text, "خصم "), has(text, "تم خصم "):
		return "debit"
	}
	return smsFamilyOther
}

func parseMoneyToken(s string) (int64, bool) {
	whole, frac, ok := strings.Cut(s, ".")
	if !ok || len(frac) != 2 || whole == "" || whole[0] < '0' || whole[0] > '9' {
		return 0, false
	}
	var n int64
	for k, part := range []string{whole, frac} {
		for i := 0; i < len(part); i++ {
			c := part[i]
			switch {
			case c == ',' && k == 0:
				continue
			case c < '0' || c > '9':
				return 0, false
			}
			if n > (1<<62)/10 {
				return 0, false
			}
			n = n*10 + int64(c-'0')
		}
	}
	return n, true
}

func isCurrencyToken(s string) bool {
	if len(s) != 3 {
		return false
	}
	for i := 0; i < 3; i++ {
		if s[i] < 'A' || s[i] > 'Z' {
			return false
		}
	}
	return true
}

func independentReading(text string) smsReading {
	r := smsReading{family: independentFamily(text)}
	if r.family == smsFamilyOther {
		return r
	}
	r.direction = smsFamilyDirection[r.family]
	fields := strings.Fields(text)
	for i, f := range fields {
		if n, ok := parseMoneyToken(f); ok {
			r.amountMinor = n
			r.currency = "AED"
			if i > 0 && isCurrencyToken(fields[i-1]) {
				r.currency = fields[i-1]
			}
			break
		}
	}
	return r
}

type smsTemplates struct {
	defs     []tmpl.Definition
	compiled []*tmpl.Compiled
}

func loadSMSTemplates(t *testing.T) smsTemplates {
	t.Helper()
	var s smsTemplates
	for _, d := range Seed() {
		if !d.IsSMS() {
			continue
		}
		c, err := tmpl.Compile(d)
		if err != nil {
			t.Fatal(err)
		}
		s.defs = append(s.defs, d)
		s.compiled = append(s.compiled, c)
	}
	if len(s.defs) != len(smsFamilies)-1 {
		t.Fatalf("%d sms seeds, want one per family %v", len(s.defs), smsFamilies[:len(smsFamilies)-1])
	}
	return s
}

func (s smsTemplates) run(sender, normalized string) (template string, gated []string, expect tmpl.TemplateExpect, matched []string) {
	gated = []string{}
	expect = tmpl.ExpectOf(tmpl.Extraction{}, tmpl.ErrNoMatch)
	for i, c := range s.compiled {
		if !tmpl.MatchesSMSSender(s.defs[i], sender) {
			continue
		}
		e, err := c.Execute("", normalized)
		switch {
		case err == nil:
			matched = append(matched, s.defs[i].ID)
			if template == "" {
				template, expect = s.defs[i].ID, tmpl.ExpectOf(e, nil)
			}
		case errors.Is(err, tmpl.ErrMissingField):
			gated = append(gated, s.defs[i].ID)
		}
	}
	return template, gated, expect, matched
}

func readSMSCorpus(t *testing.T) []smsCorpusFile {
	t.Helper()
	dir := privatefixtures.Path(t, smsCorpusDir)
	var out []smsCorpusFile
	for _, fam := range smsFamilies {
		b, err := os.ReadFile(filepath.Join(dir, "dib-"+fam+".json"))
		if err != nil {
			t.Fatalf("%s %s/dib-%s.json: %v", privatefixtures.Marker, smsCorpusDir, fam, err)
		}
		var f smsCorpusFile
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatalf("%s dib-%s.json: %v", privatefixtures.Marker, fam, err)
		}
		if f.Family != fam || f.Kind != "corpus" || len(f.Cases) == 0 {
			t.Fatalf("dib-%s.json: family %q, kind %q, %d cases", fam, f.Family, f.Kind, len(f.Cases))
		}
		out = append(out, f)
	}
	names, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil || len(names) != len(smsFamilies) {
		t.Fatalf("%s holds %d files, want exactly one per family (%v)", smsCorpusDir, len(names), err)
	}
	return out
}

func decodeCase(t *testing.T, c smsCorpusCase) (text, normalized string) {
	t.Helper()
	tb, err := base64.StdEncoding.DecodeString(c.TextBase64)
	if err != nil {
		t.Fatalf("%s: %v", c.Name, err)
	}
	nb, err := base64.StdEncoding.DecodeString(c.NormalizedBase64)
	if err != nil {
		t.Fatalf("%s: %v", c.Name, err)
	}
	return string(tb), string(nb)
}

func TestDIBSMSCorpusIsWhatThisBuildProduces(t *testing.T) {
	files := readSMSCorpus(t)
	s := loadSMSTemplates(t)
	for _, f := range files {
		for _, c := range f.Cases {
			text, normalized := decodeCase(t, c)
			got, err := norm.NormalizeText(f.NormalizerVersion, text)
			if err != nil {
				t.Fatalf("%s: %v", c.Name, err)
			}
			if got != normalized {
				t.Fatalf("%s: the normalized text is stale; regenerate with %s=1 go test ./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus",
					c.Name, writeCorpusEnv)
			}
			template, gated, expect, _ := s.run(c.Sender, normalized)
			if template != c.Template || strings.Join(gated, ",") != strings.Join(c.Gated, ",") ||
				!sameSMSExpect(expect, c.Expect) {
				t.Fatalf("%s is stale: template %q gated %v, recorded %q gated %v; regenerate with %s=1 go test ./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus",
					c.Name, template, gated, c.Template, c.Gated, writeCorpusEnv)
			}
		}
	}
}

func TestDIBSMSCorpusAgreesWithAnIndependentReading(t *testing.T) {
	files := readSMSCorpus(t)
	s := loadSMSTemplates(t)
	read := map[string]int{}
	var wrongAmount, wrongCurrency, wrongDirection, unread, misread, nonPaymentMatched, doubleMatched, gatedOut int
	total := 0
	for _, f := range files {
		for _, c := range f.Cases {
			total++
			_, normalized := decodeCase(t, c)
			want := independentReading(normalized)
			if want.family != f.Family {
				t.Errorf("%s sits in dib-%s.json but reads as %s", c.Name, f.Family, want.family)
			}
			template, gated, expect, matched := s.run(c.Sender, normalized)
			gatedOut += len(gated)
			if len(matched) > 1 {
				doubleMatched++
			}
			if want.family == smsFamilyOther {
				if len(matched) > 0 {
					nonPaymentMatched++
					t.Errorf("%s: a non-payment text matched %v", c.Name, matched)
				}
				continue
			}
			if template == "" {
				unread++
				t.Errorf("%s: no template read a %s text", c.Name, want.family)
				continue
			}
			if template != "dib.sms."+want.family+".v1" {
				misread++
				t.Errorf("%s: %s read a %s text", c.Name, template, want.family)
			}
			if expect.AmountMinor != fmt.Sprint(want.amountMinor) {
				wrongAmount++
				t.Errorf("%s: wrong amount", c.Name)
			}
			if expect.Currency != want.currency {
				wrongCurrency++
				t.Errorf("%s: wrong currency", c.Name)
			}
			if expect.Direction != want.direction {
				wrongDirection++
				t.Errorf("%s: wrong direction", c.Name)
			}
			read[want.family]++
		}
	}
	if doubleMatched > 0 || gatedOut > 0 {
		t.Errorf("%d texts matched two templates and %d template runs passed a gate but missed a field", doubleMatched, gatedOut)
	}
	payments := 0
	for _, fam := range smsFamilies[:len(smsFamilies)-1] {
		if read[fam] == 0 {
			t.Errorf("no %s text in the corpus was read; the family is untested", fam)
		}
		payments += read[fam]
	}
	if total < 4000 || payments < 4000 {
		t.Fatalf("only %d texts, %d payments: the corpus is not the export it claims to be", total, payments)
	}
	t.Logf("%s %d texts: %d payments read (purchase %d, debit %d, credit %d, salary %d, refund %d, reversal %d, own-transfer %d, card-payment %d), %d other",
		privatefixtures.Marker, total, payments, read["purchase"], read["debit"], read["credit"], read["salary"], read["refund"],
		read["reversal"], read["own-transfer"], read["card-payment"], total-payments)
	t.Logf("wrong amounts %d, wrong currencies %d, wrong directions %d, unread payments %d, misread %d, non-payments matched %d",
		wrongAmount, wrongCurrency, wrongDirection, unread, misread, nonPaymentMatched)
}

func TestTheIndependentReadingReadsEachShape(t *testing.T) {
	for _, tc := range []struct {
		text   string
		family string
		amount int64
		ccy    string
	}{
		{"مشتريات بمبلغ USD 7.89 في 05-06-2026 10:11 من SAMPLE رصيدك الحالي 2,345.67", "purchase", 789, "USD"},
		{"خصم 1,234.56 في 05-06-2026 SAMPLE رصيدك 1.00", "debit", 123456, "AED"},
		{"إيداع راتب 05-06-2026 - مبلغ 12,345.67 رصيدك 2,345.67", "salary", 1234567, "AED"},
		{"تم إرجاع مبلغ 12.34 درهم على بطاقة", "refund", 1234, "AED"},
		{"123456 هو OTP للمشتريات من SAMPLE بمبلغ 12.34 AED", smsFamilyOther, 0, ""},
		{"احصل على خصم 20%", smsFamilyOther, 0, ""},
	} {
		r := independentReading(tc.text)
		if r.family != tc.family || r.amountMinor != tc.amount || r.currency != tc.ccy {
			t.Errorf("%q: got %+v", tc.text, r)
		}
	}
	for _, s := range []string{"1.0", "1", ".50", "1.005", "a1.00", "1.0a", "-1.00", "1,.1,"} {
		if _, ok := parseMoneyToken(s); ok {
			t.Errorf("%q is not a money token", s)
		}
	}
}

func sameSMSExpect(a, b tmpl.TemplateExpect) bool {
	ab, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return bytes.Equal(ab, bb)
}

type smsExportRow struct {
	Ts     string `json:"ts"`
	Sender string `json:"sender"`
	Text   string `json:"text"`
}

func smsInputs(t *testing.T, dir string) []smsExportRow {
	t.Helper()
	if p := os.Getenv(smsExportEnv); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		var rows []smsExportRow
		if err := json.Unmarshal(b, &rows); err != nil {
			t.Fatal(err)
		}
		uae := time.FixedZone("UAE", 4*3600)
		for i := range rows {
			at, err := time.ParseInLocation("Jan 2, 2006 3:04:05 PM", rows[i].Ts, uae)
			if err != nil {
				t.Fatalf("row %d: %v", i, err)
			}
			rows[i].Ts = at.UTC().Format(time.RFC3339)
		}
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].Ts < rows[j].Ts })
		return rows
	}
	var rows []smsExportRow
	for _, f := range readSMSCorpus(t) {
		for _, c := range f.Cases {
			text, _ := decodeCase(t, c)
			rows = append(rows, smsExportRow{Ts: c.ReceivedAt, Sender: c.Sender, Text: text})
		}
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Ts < rows[j].Ts })
	return rows
}

func TestWriteDIBSMSCorpus(t *testing.T) {
	if os.Getenv(writeCorpusEnv) == "" {
		t.Skipf("%s is unset; the private sms corpus is regenerated deliberately", writeCorpusEnv)
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Skipf("%s %s is unset: the sms corpus is real bank texts and lives in %s", privatefixtures.Marker,
			privatefixtures.EnvVar, privatefixtures.Repo)
	}
	dir := filepath.Join(root, filepath.FromSlash(smsCorpusDir))
	rows := smsInputs(t, dir)
	s := loadSMSTemplates(t)
	files := map[string]*smsCorpusFile{}
	for _, fam := range smsFamilies {
		files[fam] = &smsCorpusFile{
			Note: "PRIVATE: the operator's own DIB bank texts (" + smsCorpusSender + "), one file per family as " +
				"server/internal/tmpl/seed TestDIBSMSCorpusAgreesWithAnIndependentReading classifies them. Written by " +
				"TestWriteDIBSMSCorpus (" + writeCorpusEnv + "=1, " + privatefixtures.EnvVar + ", and " + smsExportEnv +
				" for a new export); received_at is the export's UAE wall clock in UTC. `template`, `gated` and `expect` are " +
				"the Go executor's literal output over the normalized text; the Swift executor must reproduce them.",
			SchemaVersion:     1,
			Kind:              "corpus",
			Family:            fam,
			NormalizerVersion: norm.CurrentVersion,
		}
	}
	for _, r := range rows {
		normalized, err := norm.NormalizeText(norm.CurrentVersion, r.Text)
		if err != nil {
			t.Fatal(err)
		}
		f := files[independentReading(normalized).family]
		template, gated, expect, _ := s.run(r.Sender, normalized)
		f.Cases = append(f.Cases, smsCorpusCase{
			Name:             fmt.Sprintf("dib-%s-%04d", f.Family, len(f.Cases)+1),
			Sender:           r.Sender,
			ReceivedAt:       r.Ts,
			TextBase64:       base64.StdEncoding.EncodeToString([]byte(r.Text)),
			NormalizedBase64: base64.StdEncoding.EncodeToString([]byte(normalized)),
			Template:         template,
			Gated:            gated,
			Expect:           expect,
		})
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, fam := range smsFamilies {
		var b bytes.Buffer
		e := json.NewEncoder(&b)
		e.SetEscapeHTML(false)
		e.SetIndent("", "  ")
		if err := e.Encode(files[fam]); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "dib-"+fam+".json"), b.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("dib-%s.json: %d cases", fam, len(files[fam].Cases))
	}
}
