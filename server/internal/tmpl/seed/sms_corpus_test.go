package seed

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	"github.com/salehtl/hasala/server/internal/tmpl"
)

const (
	smsCorpusDir    = "conformance/templates/sms"
	smsOtherFile    = "dib-other.json"
	smsExportEnv    = "HASALA_SMS_EXPORT"
	writeCorpusEnv  = "HASALA_WRITE_CONFORMANCE"
	smsFamilyOther  = "other"
	smsCorpusSender = "DIB-SMS"
	smsCorpusSource = "the operator's DIB bank texts (" + smsCorpusSender + ")"
)

var smsFamilies = []string{
	"purchase", "debit", "credit", "salary", "refund", "reversal", "own-transfer", "card-payment", smsFamilyOther,
}

func smsTemplateID(family string) string { return "dib.sms." + family + ".v1" }

func smsCorpusFileName(family string) string {
	if family == smsFamilyOther {
		return smsOtherFile
	}
	return "corpus-" + smsTemplateID(family) + ".json"
}

type smsCorpusFile struct {
	Note              string          `json:"note"`
	Spec              string          `json:"spec,omitempty"`
	SchemaVersion     int             `json:"schema_version"`
	Template          string          `json:"template,omitempty"`
	Kind              string          `json:"kind"`
	Family            string          `json:"family"`
	NormalizerVersion int             `json:"normalizer_version"`
	Definition        json.RawMessage `json:"definition,omitempty"`
	Cases             []smsCorpusCase `json:"cases"`
}

type smsCorpusCase struct {
	Name                 string              `json:"name"`
	Source               string              `json:"source"`
	Sender               string              `json:"sender"`
	ReceivedAt           string              `json:"received_at"`
	TextBase64           string              `json:"text_base64"`
	SubjectBase64        string              `json:"subject_base64"`
	NormalizedBodyBase64 string              `json:"normalized_body_base64"`
	ReadBy               string              `json:"read_by"`
	Gated                []string            `json:"gated"`
	Expect               tmpl.TemplateExpect `json:"expect"`
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

var smsPaymentWords = []string{
	"purchase", "debit", "credit", "refund", "revers", "transfer", "withdraw", "payment", "paid", "spent",
	"cashback", "salary", "deposit",
	"شراء", "مشتريات", "مبلغ", "خصم", "ايداع", "إيداع", "تحويل", "سحب", "سداد", "دفعة", "إرجاع", "راتب", "استرداد",
}

var smsCurrencyWords = []string{"درهم", "دولار", "يورو"}

const smsOneTimeCodeKind = "one-time code"

var smsUntemplatedKinds = []struct {
	kind    string
	markers []string
}{
	{"failed scheduled transfer", []string{"could not be processed"}},
	{"card application approval", []string{"Application has been approved"}},
	{"cashback notice", []string{"استرداد نقدي"}},
}

var smsCodeWords = [][]string{{"OTP"}, {"code"}, {"passcode"}, {"رمز"}, {"كلمة", "المرور"}, {"كلمة", "السر"}}

var smsCodeLinks = []string{"is", "your", "هو", "هي"}

func isOneTimeCode(s string) bool {
	if len(s) < 4 || len(s) > 8 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func smsCodeWordAt(tokens []string, i int, word []string) bool {
	if i+len(word) > len(tokens) {
		return false
	}
	for k, w := range word {
		if !strings.EqualFold(tokens[i+k], w) {
			return false
		}
	}
	return true
}

func isSMSCodeLink(s string) bool {
	return slices.ContainsFunc(smsCodeLinks, func(l string) bool { return strings.EqualFold(s, l) })
}

func smsCodeBeside(tokens []string, from, step int) bool {
	for k, links := from, 0; k >= 0 && k < len(tokens); k += step {
		if isOneTimeCode(tokens[k]) {
			return true
		}
		if !isSMSCodeLink(tokens[k]) || links == 2 {
			return false
		}
		links++
	}
	return false
}

func hasOneTimeCodeMarker(text string) bool {
	var tokens []string
	for _, raw := range strings.Fields(text) {
		tokens = append(tokens, strings.Trim(raw, "().,:;!؛،\"'"))
	}
	for i := range tokens {
		for _, w := range smsCodeWords {
			if smsCodeWordAt(tokens, i, w) && (smsCodeBeside(tokens, i+len(w), 1) || smsCodeBeside(tokens, i-1, -1)) {
				return true
			}
		}
	}
	return false
}

func isWholeNumber(s string) bool {
	digits := 0
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c >= '0' && c <= '9':
			digits++
		case c == ',' && digits > 0:
		default:
			return false
		}
	}
	return digits > 0
}

func isCurrencyWord(s string) bool {
	if isCurrencyToken(strings.TrimRight(s, ".,:;")) {
		return true
	}
	for _, w := range smsCurrencyWords {
		if strings.HasPrefix(s, w) {
			return true
		}
	}
	return false
}

func hasMoneyToken(text string) bool {
	fields := strings.Fields(text)
	for i, raw := range fields {
		f := strings.Trim(raw, "().,:;!؛،")
		if _, ok := parseMoneyToken(f); ok {
			return true
		}
		if len(f) > 3 && isCurrencyToken(f[:3]) {
			if _, ok := parseMoneyToken(f[3:]); ok || isWholeNumber(f[3:]) {
				return true
			}
		}
		if !isWholeNumber(f) {
			continue
		}
		if (i > 0 && isCurrencyWord(fields[i-1])) || (i+1 < len(fields) && isCurrencyWord(fields[i+1])) {
			return true
		}
	}
	return false
}

func paymentShaped(text string) bool {
	lower := strings.ToLower(text)
	for _, w := range smsPaymentWords {
		if strings.Contains(lower, w) {
			return hasMoneyToken(text)
		}
	}
	return false
}

func untemplatedKind(text string) string {
	if hasOneTimeCodeMarker(text) {
		return smsOneTimeCodeKind
	}
	for _, k := range smsUntemplatedKinds {
		for _, m := range k.markers {
			if strings.Contains(text, m) {
				return k.kind
			}
		}
	}
	return ""
}

type smsTemplates struct {
	defs     []tmpl.Definition
	compiled []*tmpl.Compiled
}

func loadSMSTemplates(t *testing.T) smsTemplates {
	t.Helper()
	var s smsTemplates
	var texts []tmpl.Definition
	for _, d := range Seed() {
		if d.IsSMS() {
			texts = append(texts, d)
		}
	}
	slices.SortFunc(texts, func(a, b tmpl.Definition) int { return strings.Compare(a.ID, b.ID) })
	for _, d := range texts {
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
	for _, fam := range smsFamilies[:len(smsFamilies)-1] {
		if s.byID(smsTemplateID(fam)) == nil {
			t.Fatalf("no sms seed %s for the %s family", smsTemplateID(fam), fam)
		}
	}
	return s
}

func (s smsTemplates) byID(id string) *tmpl.Compiled {
	for i, d := range s.defs {
		if d.ID == id {
			return s.compiled[i]
		}
	}
	return nil
}

func (s smsTemplates) mayFile(readBy, sender string) bool {
	for _, d := range s.defs {
		if d.ID == readBy {
			return tmpl.MatchesSMSSender(d, sender)
		}
	}
	return false
}

func (s smsTemplates) run(normalized string) (readBy string, gated []string, expect tmpl.TemplateExpect, matched []string) {
	gated = []string{}
	expect = tmpl.ExpectOf(tmpl.Extraction{}, tmpl.ErrNoMatch)
	for i, c := range s.compiled {
		e, err := c.Execute("", normalized)
		switch {
		case err == nil:
			matched = append(matched, s.defs[i].ID)
			if readBy == "" {
				readBy, expect = s.defs[i].ID, tmpl.ExpectOf(e, nil)
			}
		case errors.Is(err, tmpl.ErrMissingField):
			gated = append(gated, s.defs[i].ID)
		}
	}
	return readBy, gated, expect, matched
}

func (s smsTemplates) fileExpect(family, normalized string, runExpect tmpl.TemplateExpect) tmpl.TemplateExpect {
	if family == smsFamilyOther {
		return runExpect
	}
	e, err := s.byID(smsTemplateID(family)).Execute("", normalized)
	return tmpl.ExpectOf(e, err)
}

func compactJSON(t *testing.T, b []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	if err := json.Compact(&out, b); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func readSMSCorpus(t *testing.T) []smsCorpusFile {
	t.Helper()
	return readSMSCorpusFiles(t, true)
}

func readSMSCorpusFiles(t *testing.T, currentDefinitions bool) []smsCorpusFile {
	t.Helper()
	dir := privatefixtures.Path(t, smsCorpusDir)
	raw := Raw()
	var out []smsCorpusFile
	want := map[string]bool{}
	for _, fam := range smsFamilies {
		name := smsCorpusFileName(fam)
		want[name] = true
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s %s/%s: %v", privatefixtures.Marker, smsCorpusDir, name, err)
		}
		var f smsCorpusFile
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatalf("%s %s: %v", privatefixtures.Marker, name, err)
		}
		if f.Family != fam || f.Kind != "corpus" || len(f.Cases) == 0 {
			t.Fatalf("%s: family %q, kind %q, %d cases", name, f.Family, f.Kind, len(f.Cases))
		}
		if fam == smsFamilyOther {
			if f.Template != "" || len(f.Definition) != 0 {
				t.Fatalf("%s names template %q: the texts no template reads belong to none", name, f.Template)
			}
		} else {
			id := smsTemplateID(fam)
			if f.Template != id {
				t.Fatalf("%s names template %q, want %s", name, f.Template, id)
			}
			if currentDefinitions && !bytes.Equal(compactJSON(t, f.Definition), compactJSON(t, raw[id])) {
				t.Fatalf("%s holds a definition that is not the seed %s.json; regenerate with %s=1 go test ./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus",
					name, id, writeCorpusEnv)
			}
		}
		out = append(out, f)
	}
	names, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		if !want[filepath.Base(n)] {
			t.Fatalf("%s holds %s, which no family names", smsCorpusDir, filepath.Base(n))
		}
	}
	return out
}

func decodeCase(t *testing.T, c smsCorpusCase) (text, normalized string) {
	t.Helper()
	tb, err := base64.StdEncoding.DecodeString(c.TextBase64)
	if err != nil {
		t.Fatalf("%s: %v", c.Name, err)
	}
	nb, err := base64.StdEncoding.DecodeString(c.NormalizedBodyBase64)
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
			if got != normalized || c.SubjectBase64 != "" {
				t.Fatalf("%s: the normalized text is stale; regenerate with %s=1 go test ./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus",
					c.Name, writeCorpusEnv)
			}
			readBy, gated, runExpect, _ := s.run(normalized)
			expect := s.fileExpect(f.Family, normalized, runExpect)
			if readBy != c.ReadBy || strings.Join(gated, ",") != strings.Join(c.Gated, ",") ||
				!sameSMSExpect(expect, c.Expect) {
				t.Fatalf("%s is stale: read by %q gated %v, recorded %q gated %v; regenerate with %s=1 go test ./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus",
					c.Name, readBy, gated, c.ReadBy, c.Gated, writeCorpusEnv)
			}
		}
	}
}

func TestDIBSMSCorpusAgreesWithAnIndependentReading(t *testing.T) {
	files := readSMSCorpus(t)
	s := loadSMSTemplates(t)
	read := map[string]int{}
	kinds := map[string]int{}
	var wrongAmount, wrongCurrency, wrongDirection, unread, misread, nonPaymentMatched, doubleMatched, gatedOut, unknownShape, unfiled int
	total := 0
	for _, f := range files {
		for _, c := range f.Cases {
			total++
			_, normalized := decodeCase(t, c)
			want := independentReading(normalized)
			if want.family != f.Family {
				t.Errorf("%s sits in %s but reads as %s", c.Name, smsCorpusFileName(f.Family), want.family)
			}
			readBy, gated, expect, matched := s.run(normalized)
			gatedOut += len(gated)
			if len(matched) > 1 {
				doubleMatched++
			}
			if want.family == smsFamilyOther {
				if len(matched) > 0 {
					nonPaymentMatched++
					t.Errorf("%s: a non-payment text matched %v", c.Name, matched)
				}
				if paymentShaped(normalized) {
					kind := untemplatedKind(normalized)
					kinds[kind]++
					if kind == "" {
						unknownShape++
						t.Errorf("%s: a text with a payment word and an amount that no template reads and no known untemplated kind names; "+
							"a payment wording the templates do not know, or a new kind for smsUntemplatedKinds", c.Name)
					}
				}
				continue
			}
			if readBy == "" {
				unread++
				t.Errorf("%s: no template read a %s text", c.Name, want.family)
				continue
			}
			if readBy != smsTemplateID(want.family) {
				misread++
				t.Errorf("%s: %s read a %s text", c.Name, readBy, want.family)
			}
			if !s.mayFile(readBy, c.Sender) {
				unfiled++
				t.Errorf("%s: %s read it, but its sender is not in the template's sms_sender, so the hit could not file", c.Name, readBy)
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
	t.Logf("wrong amounts %d, wrong currencies %d, wrong directions %d, unread payments %d, misread %d, non-payments matched %d, hits from a sender the template does not name %d",
		wrongAmount, wrongCurrency, wrongDirection, unread, misread, nonPaymentMatched, unfiled)
	t.Logf("other texts with a payment shape: one-time code %d, failed scheduled transfer %d, card application approval %d, cashback notice %d, unknown %d",
		kinds[smsOneTimeCodeKind], kinds["failed scheduled transfer"], kinds["card application approval"], kinds["cashback notice"], unknownShape)
}

const (
	smsBalanceWindow     = 8
	smsMinCorroborated   = 5
	smsMaxSettleItems    = 6
	smsVerdictAgrees     = "agrees"
	smsVerdictContradict = "contradicts"
)

var smsBalanceMarkers = []string{"رصيدك", "رصيد حساب الخصم هو", "الحد الائتماني المتاح"}

var smsUncorroboratedWordings = map[string]string{
	"تم خصم": "the undated account debit: one text in the export, and it carries no balance",
	"خصم صراف آلي دولي بمبلغ": "the international ATM withdrawal: one text in the export, and its balance follows no balance before it",
}

func smsWording(text string) string {
	var words []string
	for _, f := range strings.Fields(text) {
		if strings.ContainsAny(f, "0123456789") {
			break
		}
		if isCurrencyToken(f) {
			continue
		}
		words = append(words, f)
	}
	return strings.Join(words, " ")
}

func firstSignedMoney(s string) (int64, bool) {
	start := strings.IndexAny(s, "0123456789")
	if start < 0 {
		return 0, false
	}
	end := start
	for end < len(s) && (s[end] >= '0' && s[end] <= '9' || s[end] == ',' || s[end] == '.') {
		end++
	}
	n, ok := parseMoneyToken(strings.TrimRight(s[start:end], ".,"))
	if ok && start > 0 && s[start-1] == '-' {
		n = -n
	}
	return n, ok
}

func balanceAfter(text string) (int64, bool) {
	for _, m := range smsBalanceMarkers {
		if i := strings.LastIndex(text, m); i >= 0 {
			return firstSignedMoney(text[i+len(m):])
		}
	}
	return 0, false
}

func smsCardKey(text string) string {
	for _, raw := range strings.Fields(text) {
		f := strings.Trim(raw, "().,:;")
		if len(f) < 4 {
			continue
		}
		digits, mask := f[len(f)-4:], f[:len(f)-4]
		if strings.Trim(digits, "0123456789") == "" && strings.Trim(mask, "Xx*") == "" {
			return digits
		}
	}
	return ""
}

type smsBalanceRow struct {
	name      string
	text      string
	direction string
}

type smsMovement struct {
	name      string
	direction string
	amount    int64
	inAED     bool
}

func smsBalanceVerdicts(rows []smsBalanceRow) map[string]string {
	verdicts := map[string]string{}
	judge := func(m smsMovement, credit bool) {
		if (m.direction == "credit") == credit {
			verdicts[m.name] = smsVerdictAgrees
		} else {
			verdicts[m.name] = smsVerdictContradict
		}
	}
	settle := func(delta int64, items []smsMovement) bool {
		if len(items) > smsMaxSettleItems {
			return false
		}
		for _, m := range items {
			if !m.inAED || m.amount == 0 {
				return false
			}
		}
		solutions, found := 0, 0
		for signs := 0; signs < 1<<len(items); signs++ {
			var sum int64
			for k, m := range items {
				if signs&(1<<k) != 0 {
					sum += m.amount
				} else {
					sum -= m.amount
				}
			}
			if sum == delta {
				solutions++
				found = signs
			}
		}
		if solutions != 1 {
			return false
		}
		for k, m := range items {
			judge(m, found&(1<<k) != 0)
		}
		return true
	}
	var recent []int64
	last := map[string]int64{}
	pending := map[string][]smsMovement{}
	for _, r := range rows {
		want := independentReading(r.text)
		m := smsMovement{name: r.name, direction: r.direction, amount: want.amountMinor, inAED: want.currency == "AED"}
		key := smsCardKey(r.text)
		bal, ok := balanceAfter(r.text)
		if !ok {
			pending[key] = append(pending[key], m)
			continue
		}
		settled := false
		if ps := pending[key]; len(ps) > 0 {
			delete(pending, key)
			if prev, seen := last[key]; seen {
				settled = settle(bal-prev, append([]smsMovement{m}, ps...))
			}
		}
		if !settled && m.inAED && m.amount != 0 {
			debit := slices.Contains(recent, bal+m.amount)
			credit := slices.Contains(recent, bal-m.amount)
			if debit != credit {
				judge(m, credit)
			}
		}
		last[key] = bal
		recent = append(recent, bal)
		if len(recent) > smsBalanceWindow {
			recent = recent[1:]
		}
	}
	return verdicts
}

func TestDIBSMSCorpusDirectionsAgreeWithTheBalances(t *testing.T) {
	files := readSMSCorpus(t)
	s := loadSMSTemplates(t)
	type dated struct {
		at  string
		row smsBalanceRow
		fam string
	}
	var all []dated
	for _, f := range files {
		if f.Family == smsFamilyOther {
			continue
		}
		for _, c := range f.Cases {
			_, normalized := decodeCase(t, c)
			_, _, e, _ := s.run(normalized)
			all = append(all, dated{c.ReceivedAt, smsBalanceRow{c.Name, normalized, e.Direction}, f.Family})
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].at < all[j].at })
	rows := make([]smsBalanceRow, len(all))
	for i, d := range all {
		rows[i] = d.row
	}
	verdicts := smsBalanceVerdicts(rows)
	agrees := map[string]int{}
	judged := map[string]int{}
	byWording := map[string]int{}
	seen := map[string]bool{}
	contradictions := 0
	for _, d := range all {
		w := smsWording(d.row.text)
		seen[w] = true
		switch verdicts[d.row.name] {
		case smsVerdictAgrees:
			agrees[d.fam]++
			byWording[w]++
			judged[d.fam]++
		case smsVerdictContradict:
			contradictions++
			judged[d.fam]++
			t.Errorf("%s: the template reads a %s, but the balance moved the other way by the amount", d.row.name, d.row.direction)
		}
	}
	for _, fam := range smsFamilies[:len(smsFamilies)-1] {
		if agrees[fam] < smsMinCorroborated {
			t.Errorf("only %d %s texts have their direction confirmed by a balance; want at least %d", agrees[fam], fam, smsMinCorroborated)
		}
	}
	for w := range seen {
		_, listed := smsUncorroboratedWordings[w]
		switch {
		case byWording[w] == 0 && !listed:
			t.Errorf("no text worded %q has its direction confirmed by a balance", w)
		case byWording[w] > 0 && listed:
			t.Errorf("texts worded %q now have their direction confirmed by a balance; remove the wording from smsUncorroboratedWordings", w)
		}
	}
	for w := range smsUncorroboratedWordings {
		if !seen[w] {
			t.Errorf("no payment text is worded %q; remove it from smsUncorroboratedWordings", w)
		}
	}
	t.Logf("%s directions confirmed by the balance or available limit (agree/judged): purchase %d/%d, debit %d/%d, credit %d/%d, salary %d/%d, refund %d/%d, reversal %d/%d, own-transfer %d/%d, card-payment %d/%d; %d contradictions",
		privatefixtures.Marker, agrees["purchase"], judged["purchase"], agrees["debit"], judged["debit"], agrees["credit"], judged["credit"],
		agrees["salary"], judged["salary"], agrees["refund"], judged["refund"], agrees["reversal"], judged["reversal"],
		agrees["own-transfer"], judged["own-transfer"], agrees["card-payment"], judged["card-payment"], contradictions)
}

func TestTheBalanceReaderReadsEachShape(t *testing.T) {
	for _, tc := range []struct {
		text    string
		balance int64
		ok      bool
		card    string
		wording string
	}{
		{"خصم 1,234.56 في 05-06-2026 SAMPLE رصيدك 1,000.00", 100000, true, "", "خصم"},
		{"ايداع بمبلغ 10.00 في 05-06-2026 SAMPLE رصيدك الحالى2,345.67", 234567, true, "", "ايداع بمبلغ"},
		{"مشتريات بمبلغ USD 7.89 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE. الحد الائتماني المتاح -123.45", -12345, true, "1234", "مشتريات بمبلغ"},
		{"تحويل بين حساباتك بمبلغ AED 4,321.09 من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 05-06-2026 SAMPLE رصيد حساب الخصم هو AED 1,000.00 وحساب الايداع هو AED 5,000.00", 100000, true, "", "تحويل بين حساباتك بمبلغ"},
		{"تم إرجاع مبلغ 12.34 درهم على بطاقة SAMPLE والمنتهية بالرقم 1234.", 0, false, "1234", "تم إرجاع مبلغ"},
		{"A transaction to the value of AED 12.34 made at SAMPLE on your DIB card ending with XX1234 has been reversed.", 0, false, "1234", "A transaction to the value of"},
		{"خصم 1.00 في 05-06-2026 SAMPLE رصيدك", 0, false, "", "خصم"},
		{"خصم 1.00 في 05-06-2026 SAMPLE رصيدك 1.5", 0, false, "", "خصم"},
	} {
		b, ok := balanceAfter(tc.text)
		if ok != tc.ok || b != tc.balance {
			t.Errorf("%q: balance %d %v, want %d %v", tc.text, b, ok, tc.balance, tc.ok)
		}
		if got := smsCardKey(tc.text); got != tc.card {
			t.Errorf("%q: card %q, want %q", tc.text, got, tc.card)
		}
		if got := smsWording(tc.text); got != tc.wording {
			t.Errorf("%q: wording %q, want %q", tc.text, got, tc.wording)
		}
	}
}

func TestTheBalancesCatchAWrongDirection(t *testing.T) {
	rows := []smsBalanceRow{
		{"a", "ايداع 1,000.00 في 05-06-2026 SAMPLE رصيدك 1,000.00", "credit"},
		{"b", "خصم 100.00 في 05-06-2026 SAMPLE رصيدك 900.00", "debit"},
		{"c", "خصم 40.00 في 05-06-2026 SAMPLE رصيدك 940.00", "debit"},
		{"d", "ايداع 25.00 في 05-06-2026 SAMPLE رصيدك 915.00", "credit"},
		{"e", "خصم 7.00 في 05-06-2026 SAMPLE رصيدك 12,345.67", "debit"},
		{"p1", "مشتريات بمبلغ 20.00 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE. الحد الائتماني المتاح 500.00", "debit"},
		{"r", "تم إرجاع مبلغ 12.34 درهم على بطاقة SAMPLE والمنتهية بالرقم 1234.", "credit"},
		{"p2", "مشتريات بمبلغ 30.00 من بطاقة XX1234 في 05-06-2026 10:12 من SAMPLE. الحد الائتماني المتاح 482.34", "debit"},
		{"r2", "تم إرجاع مبلغ 1.11 درهم على بطاقة SAMPLE والمنتهية بالرقم 1234.", "debit"},
		{"p3", "مشتريات بمبلغ 2.00 من بطاقة XX1234 في 05-06-2026 10:13 من SAMPLE. الحد الائتماني المتاح 481.45", "debit"},
		{"f", "مشتريات بمبلغ USD 3.00 من بطاقة XX1234 في 05-06-2026 10:14 من SAMPLE. الحد الائتماني المتاح 478.45", "debit"},
	}
	got := smsBalanceVerdicts(rows)
	want := map[string]string{
		"b": smsVerdictAgrees, "c": smsVerdictContradict, "d": smsVerdictContradict,
		"p2": smsVerdictAgrees, "r": smsVerdictAgrees, "p3": smsVerdictAgrees, "r2": smsVerdictContradict,
	}
	for name, v := range want {
		if got[name] != v {
			t.Errorf("%s: verdict %q, want %q", name, got[name], v)
		}
	}
	for _, name := range []string{"a", "e", "p1", "f"} {
		if v, ok := got[name]; ok {
			t.Errorf("%s: verdict %q, want none: nothing before it confirms or refutes it", name, v)
		}
	}
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

func TestThePaymentShapeFindsAnUnknownPaymentWording(t *testing.T) {
	for _, tc := range []struct {
		text   string
		shaped bool
		kind   string
	}{
		{"Your DIB card was debited for AED 12.34 at SAMPLE SHOP", true, ""},
		{"سحب نقدي بمبلغ 500 درهم من صراف SAMPLE", true, ""},
		{"Transfer of AED1,000 to SAMPLE PERSON is complete", true, ""},
		{"تم تحويل 1,234.56 إلى حساب SAMPLE", true, ""},
		{"123456 هو OTP للمشتريات من SAMPLE SHOP بمبلغ 12.34 AED على بطاقتك 1234", true, smsOneTimeCodeKind},
		{"123456 كلمة المرور الخاصة بك لعملية شراء بمبلغ 12.34 درهم", true, smsOneTimeCodeKind},
		{"Your OTP is 482913 for a purchase of AED 12.34 at SAMPLE SHOP", true, smsOneTimeCodeKind},
		{"482913 is your code for a payment of AED 12.34 to SAMPLE", true, smsOneTimeCodeKind},
		{"رمز 4829 لعملية شراء بمبلغ 12.34 درهم", true, smsOneTimeCodeKind},
		{"Your DIB card was debited for AED 12.34 at SAMPLE SHOP. Never share your OTP with anyone.", true, ""},
		{"Purchase of AED 12.34 at SAMPLE SHOP. Do not share this OTP or code with anyone.", true, ""},
		{"Purchase of AED 12.34 at FOOTPATH SHOP on card XX1234", true, ""},
		{"مشتريات بقيمة 12.34 درهم من SAMPLE. لا تشارك كلمة المرور مع أي شخص", true, ""},
		{"تم خصم 12.34 درهم لدى SAMPLE. لا تشارك كلمة السر أو الرمز مع أحد", true, ""},
		{"Purchase of AED 12.34 at SAMPLE SHOP. An OTP is valid for 5 minutes only", true, ""},
		{"Purchase of AED 12.34 at SAMPLE SHOP, ref 123456789 OTP", true, ""},
		{"A transfer of AED 1,000 could not be processed", true, "failed scheduled transfer"},
		{"A transfer ref# REF123 could not be processed", true, "failed scheduled transfer"},
		{"Your Credit Card Application has been approved for AED 10,000.00.", true, "card application approval"},
		{"تهانينا على الحصول على استرداد نقدي قدره 50 درهما", true, "cashback notice"},
		{"احصل على خصم 20% على SAMPLE", false, ""},
		{"Your balance is AED 1,234.56", false, ""},
		{"تم إيقاف بطاقتك من SAMPLE", false, ""},
	} {
		if got := paymentShaped(tc.text); got != tc.shaped {
			t.Errorf("%q: payment shape %v, want %v", tc.text, got, tc.shaped)
		}
		if got := untemplatedKind(tc.text); tc.shaped && got != tc.kind {
			t.Errorf("%q: kind %q, want %q", tc.text, got, tc.kind)
		}
	}
}

func TestATemplateReadsATextWhateverTheSender(t *testing.T) {
	s := loadSMSTemplates(t)
	text := "مشتريات بمبلغ 12.34 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
	readBy, _, e, matched := s.run(text)
	if readBy != smsTemplateID("purchase") || len(matched) != 1 || e.AmountMinor != "1234" {
		t.Fatalf("read by %q (%v), amount %s", readBy, matched, e.AmountMinor)
	}
	for _, tc := range []struct {
		sender string
		files  bool
	}{
		{smsCorpusSender, true},
		{"dib-sms", true},
		{"+971500000000", false},
		{"971500000000", false},
		{"DIB", false},
		{"", false},
	} {
		if got := s.mayFile(readBy, tc.sender); got != tc.files {
			t.Errorf("sender %q: may file %v, want %v; the template reads the text either way", tc.sender, got, tc.files)
		}
	}
}

func TestAnAccountMaskIsNeverALastFour(t *testing.T) {
	s := loadSMSTemplates(t)
	for _, text := range []string{
		"تحويل بين حساباتك بمبلغ AED 4,321.09 من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 05-06-2026 MB Fund Transfer",
		"تحويل بين حساباتك بمبلغ 4,321.09 من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 05-06-2026 MB Fund Transfer",
		"تم خصم 4,321.09 من حسابك 1234**567 بتاريخ 05-06 SAMPLE DEBIT",
		"خصم 1,234.56 في 05-06-2026 MB FUND TRANSFER DEBIT رصيدك 3,333.33",
		"ايداع 987.65 في 05-06-2026 INWARD UAE FUNDS TRANSFER رصيدك 2,121.21",
	} {
		readBy, _, e, _ := s.run(text)
		if readBy == "" {
			t.Errorf("%q: no template read it", text)
			continue
		}
		if e.Last4 != "" {
			t.Errorf("%q: %s read last4 %q from an account number; a last four is a card's", text, readBy, e.Last4)
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

func smsInputs(t *testing.T) []smsExportRow {
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
	for _, f := range readSMSCorpusFiles(t, false) {
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
	rows := smsInputs(t)
	s := loadSMSTemplates(t)
	raw := Raw()
	regenerate := "Written by server/internal/tmpl/seed TestWriteDIBSMSCorpus (" + writeCorpusEnv + "=1, " +
		privatefixtures.EnvVar + ", and " + smsExportEnv + " for a new export); received_at is the export's UAE wall clock in UTC. " +
		"`read_by` and `gated` are what every DIB text template did with the normalized text, whatever the sender: `match.sms_sender` decides only whether a hit may file."
	files := map[string]*smsCorpusFile{}
	for _, fam := range smsFamilies {
		f := &smsCorpusFile{
			SchemaVersion:     1,
			Kind:              "corpus",
			Family:            fam,
			NormalizerVersion: norm.CurrentVersion,
		}
		if fam == smsFamilyOther {
			f.Note = "PRIVATE: " + smsCorpusSource + " that the independent reading in TestDIBSMSCorpusAgreesWithAnIndependentReading " +
				"gives no payment family. " + regenerate + " `expect` is the first template's literal Go output, the zero no_match one when none reads it."
		} else {
			id := smsTemplateID(fam)
			f.Note = "PRIVATE: " + smsCorpusSource + " that the independent reading gives the " + fam + " family, as a template " +
				"conformance file for " + id + ". " + regenerate + " `expect` is " + id + "'s literal Go output, which the template " +
				"runners (Go readTemplateFixtures, Swift TemplateFixtures) re-run; the Swift executor must reproduce all of it."
			f.Spec = "server/internal/tmpl/v2-template-format.md"
			f.Template = id
			f.Definition = compactJSON(t, raw[id])
		}
		files[fam] = f
	}
	for _, r := range rows {
		normalized, err := norm.NormalizeText(norm.CurrentVersion, r.Text)
		if err != nil {
			t.Fatal(err)
		}
		f := files[independentReading(normalized).family]
		readBy, gated, runExpect, _ := s.run(normalized)
		prefix := smsTemplateID(f.Family)
		if f.Family == smsFamilyOther {
			prefix = "dib.sms.other"
		}
		f.Cases = append(f.Cases, smsCorpusCase{
			Name:                 fmt.Sprintf("%s/%04d", prefix, len(f.Cases)+1),
			Source:               smsCorpusSource,
			Sender:               r.Sender,
			ReceivedAt:           r.Ts,
			TextBase64:           base64.StdEncoding.EncodeToString([]byte(r.Text)),
			SubjectBase64:        "",
			NormalizedBodyBase64: base64.StdEncoding.EncodeToString([]byte(normalized)),
			ReadBy:               readBy,
			Gated:                gated,
			Expect:               s.fileExpect(f.Family, normalized, runExpect),
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
		if err := os.WriteFile(filepath.Join(dir, smsCorpusFileName(fam)), b.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("%s: %d cases", smsCorpusFileName(fam), len(files[fam].Cases))
	}
}
