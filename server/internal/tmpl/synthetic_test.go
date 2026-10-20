package tmpl

// synthetic_test.go writes the hand-built half of conformance/templates/.
//
// The corpus half (corpus_test.go) is 1,062 cases of the operator's real bank
// mail, and it is the only evidence that the two executors agree about mail
// that actually arrives. It is also blind in three ways that matter, and each
// one was MEASURED on the corpus rather than assumed:
//
//  1. The corpus holds 64 ENBD messages and only TWO are the alert format
//     `enbd.alert.v1` was ported from — the other 62 are "Local Bank Transfer"
//     / "Telegraphic Transfer" advices with a `Debit Amount:` block, and both
//     alerts are debits, so the alert template's credit path has zero corpus
//     coverage. Neither ENBD template's foreign-currency path has any either:
//     no corpus amount block writes a currency other than AED.
//  2. Zero corpus cases produce an empty capture group, so the EmptyGroups
//     diagnostic — the thing the whole diagnostics ledger is built on — is
//     never compared.
//  3. Real mail is well-formed. The conversion rules are mostly about
//     malformed input: an amount with three decimals, a date with a two-digit
//     year, a capture surrounded by U+00A0.
//
// That last class is where two hand-written implementations differ, and the
// difference is silent. `String.prototype.trim()` removes U+00A0 and U+FEFF
// and Go's trim set does not; `toUpperCase()` maps U+00DF to "SS" and Go's
// does not; `Number("")` is 0 and `parseInt` stops at the first non-digit;
// `Date.parse` is implementation-defined for every shape in this format. Every
// one of those is a case below, and every expectation is what GO produced —
// never what the case's name says it should produce, so a case whose name is
// wrong is harmless and a case whose expectation is recomputed by the reader
// is impossible.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// syntheticGroup is one output file: a definition and the inputs run against it.
type syntheticGroup struct {
	file       string
	template   string
	definition string
	cases      []syntheticCase
}

type syntheticCase struct {
	name    string
	why     string
	subject string
	body    string
}

// The ENBD alert format, which the corpus has none of. The definition is the
// PUBLISHED SEED, read from testdata rather than retyped, so these cases
// exercise the template that actually ships.
func syntheticENBD(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "enbd.alert.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	const subj = "Transaction advice for your account ending with 8642"
	return syntheticGroup{
		file:       "synthetic-enbd-alert.json",
		template:   "enbd.alert.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"withdrawn", "the debit phrasing v1's enbd_alert.go:25 anchors on", subj,
				"AED 12,750.00 has been withdrawn from your account 012XXX34XXX56."},
			{"debited", "the second debit verb in the same alternation", subj,
				"AED 12.34 has been debited from your account 012XXX34XXX56."},
			{"deducted", "the third debit verb: ENBD's wording for bank-initiated debits (transfer " +
				"issuance, fees). v1 gained it after this template was cut from it and the seed did not " +
				"follow, so every such alert fell past the template tier to the heuristic, which reads " +
				"this shape as a CREDIT. Template version 2 closes that", subj,
				"AED 2,340.00 has been deducted from your account 012XXX34XXX56."},
			{"credited", "the credit branch, and on_match setting direction", subj,
				"AED 400.00 has been credited to your account 012XXX34XXX56."},
			{"deposited-into", "the optional (?:in)?to", subj,
				"AED 400.00 has been deposited into your account 012XXX34XXX56."},
			{"case-folded", `flags ["i"]: the whole line upper-cased`, subj,
				"aed 12,750.00 HAS BEEN WITHDRAWN FROM YOUR ACCOUNT 012XXX34XXX56."},
			{"newline-separated", `the [ \t\n\f\r] separators, which is why \s is banned: the class is Go's ` +
				`\s written out, and the two engines do not agree on \s itself`, subj,
				"AED 250.00\nhas been\nwithdrawn\nfrom your account 012XXX34XXX56."},
			{"tab-separated", "the rest of that class. v1 separates with `\\s+`; norm.Normalize collapses a " +
				"tab to U+0020 long before a template runs, so this is unreachable in production and free to " +
				"state exactly — `+` is not available here, because three separators would be three unbounded " +
				"quantifiers in one branch and the dialect refuses that shape", subj,
				"AED 250.00\thas been\twithdrawn\tfrom your account 012XXX34XXX56."},
			{"no-currency-prefix", "the ccy group does not participate; default_currency applies", subj,
				"250.00 has been withdrawn from your account 012XXX34XXX56."},
			{"foreign-currency", "the ccy group wins over default_currency", subj,
				"USD 99.99 has been withdrawn from your account 012XXX34XXX56."},
			{"foreign-currency-no-space", "v1's amountRe separates the code from the number with `\\s*` — ZERO " +
				"or more — so `USD99.99` is USD to v1. Version 2 of this template demanded exactly one U+0020, " +
				"so its ccy group did not participate, RE2 re-matched at the digit and default_currency made it " +
				"AED: a silently wrong amount in a different currency. Version 3 carries a SECOND, " +
				"currency-adjacent pattern ahead of the spaced one — one pattern spelled `[A-Z]{3} ?` would " +
				"double this anchor's backtracking width from 200 to 400 and the widest shipping seed is pinned " +
				"at 200", subj,
				"USD99.99 has been withdrawn from your account 012XXX34XXX56."},
			{"foreign-currency-no-space-credit", "the credit entry carries the same pair", subj,
				"USD400.00 has been credited to your account 012XXX34XXX56."},
			{"subject-last4-two-spaces", "the ONE anchor the normalizer does not feed: last4 reads the " +
				"SUBJECT, which is RFC 2047-decoded and trimmed but never whitespace-collapsed. That is why " +
				"this is the one separator version 3 spells with `+`",
				"Transaction advice for your account ending with  8642",
				"AED 250.00 has been withdrawn from your account 012XXX34XXX56."},
			{"no-subject", "last4 is read from the subject and is not required", "",
				"AED 250.00 has been withdrawn from your account 012XXX34XXX56."},
			{"subject-without-last4", "the last4 pattern does not match; the rest still extracts",
				"Transaction advice", "AED 250.00 has been withdrawn from your account."},
			{"neither-verb", "no amount entry produces a value: the required-field gate fires", subj,
				"AED 250.00 has been reserved on your account 012XXX34XXX56."},
			{"amount-without-decimals", "conversion failure, not a zero amount", subj,
				"AED 250 has been withdrawn from your account 012XXX34XXX56."},
			{"debit-then-credit", "first entry wins: the debit entry runs first", subj,
				"AED 1.00 has been withdrawn from your account.\nAED 2.00 has been credited to your account."},
			{"credit-then-debit", "entry ORDER decides, not position in the body", subj,
				"AED 2.00 has been credited to your account.\nAED 1.00 has been withdrawn from your account."},
			{"amount-longer-than-the-bound",
				"33 digits before the point. The amount run is [0-9,]{0,24} rather than [0-9,]*, because unbounded " +
					"it made this anchor quadratic (333,859 ms on a 1 MB body in Bun); pinned so the two executors " +
					"agree on what the bound does rather than on what it was meant to do", subj,
				"AED 1,234,567,890,123,456,789,012,345.67 has been withdrawn from your account 012XXX34XXX56."},
			{"transfer-advice-from-the-corpus", "the shape all 62 real ENBD messages have; it must not match", "Local Bank Transfer",
				"Transaction Date:\n15/Mar/2026 09:15 PM\nFrom Account:\n012***34***56\nDebit Amount:\nAED 23,456.00\n"},
		},
	}
}

// The ENBD transfer advice — the format 62 of the corpus's 64 ENBD messages
// have, and until now the least-covered template in the repository: no testdata
// mirror, no synthetic group, no row in the dialect fixture, and therefore
// nothing at all comparing its Go and TypeScript executions. The corpus fixture
// added alongside this group covers the shapes real ENBD mail has; these are the
// ones it does not.
//
// The definition is the PUBLISHED SEED, read from testdata rather than retyped.
func syntheticENBDTransfer(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "enbd.transfer.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	// body composes the advice in the order ENBD writes it. Any block may be
	// omitted by passing "".
	body := func(date, amount, beneficiary string) string {
		s := ""
		if date != "" {
			s += "Transaction Date:\n" + date + "\n"
		}
		s += "From Account:\n012***34***56\n"
		if amount != "" {
			s += "Debit Amount:\n" + amount + "\n"
		}
		if beneficiary != "" {
			s += "Beneficiary Name:\n" + beneficiary + "\n"
		}
		return s + "Thank you for banking with Emirates NBD.\n"
	}
	const subj = "Local Bank Transfer"
	return syntheticGroup{
		file:       "synthetic-enbd-transfer.json",
		template:   "enbd.transfer.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"timed-date", "the shape all 62 real messages have, stated once explicitly", subj,
				body("15/Mar/2026 09:15 PM", "AED 23,456.00", "SOME BENEFICIARY")},
			{"date-only", "v1's strings.Fields(s)[0] fallback, expressed as the second layout. No corpus " +
				"message takes it: all 62 carry a time", subj,
				body("15/Mar/2026", "AED 23,456.00", "SOME BENEFICIARY")},
			{"date-with-unparseable-time", "the fallback again, this time because the whole string fails " +
				"layout 1 and the first token still parses", subj,
				body("15/Mar/2026 25:99 XX", "AED 23,456.00", "SOME BENEFICIARY")},
			{"date-lowercase-month", "month NAMES fold case in Go's time.Parse and must in the mirror", subj,
				body("15/mar/2026 09:15 PM", "AED 23,456.00", "SOME BENEFICIARY")},
			{"date-impossible-day", "31 February: the calendar range check, not a rounded date", subj,
				body("31/Feb/2024 09:15 PM", "AED 23,456.00", "SOME BENEFICIARY")},
			{"no-beneficiary", "merchant is not required; the transaction still extracts", subj,
				body("15/Mar/2026 09:15 PM", "AED 23,456.00", "")},
			{"empty-beneficiary-line", "the capture is [^\\n]+, so against an empty line the pattern does not " +
				"match at all: there is no empty group to report, and merchant is not required, so the " +
				"transaction still extracts", subj,
				"Transaction Date:\n15/Mar/2026 09:15 PM\nDebit Amount:\nAED 1.00\nBeneficiary Name:\n\nFooter\n"},
			{"beneficiary-with-cr", `[^\n] keeps \r in BOTH engines, which a bare . does not`, subj,
				body("15/Mar/2026 09:15 PM", "AED 1.00", "SOME\rBENEFICIARY")},
			{"no-date", "date is REQUIRED here (unlike the alert, which dates from the email); this is " +
				"what a bank format change looks like", subj,
				body("", "AED 23,456.00", "SOME BENEFICIARY")},
			{"no-debit-amount", "the amount anchor is what v1 errors on first", subj,
				body("15/Mar/2026 09:15 PM", "", "SOME BENEFICIARY")},
			{"no-currency-prefix", "the ccy group does not participate; default_currency applies", subj,
				body("15/Mar/2026 09:15 PM", "23,456.00", "SOME BENEFICIARY")},
			{"foreign-currency", "the ccy group wins over default_currency", subj,
				body("15/Mar/2026 09:15 PM", "USD 1,200.00", "SOME BENEFICIARY")},
			{"foreign-currency-no-space", "v1's amountRe separates the code from the number with `\\s*` — " +
				"ZERO or more — so this is USD to v1. Version 1 of this template demanded exactly one U+0020, " +
				"its ccy group did not participate, RE2 re-matched at the digit and default_currency made it " +
				"AED: a silently wrong amount in a different currency. Version 2 spells it `[A-Z]{3} ?`", subj,
				body("15/Mar/2026 09:15 PM", "USD1,200.00", "SOME BENEFICIARY")},
			{"currency-lowercase", `flags ["i"]: the class matches and asciiUpper normalizes it`, subj,
				body("15/Mar/2026 09:15 PM", "usd 1,200.00", "SOME BENEFICIARY")},
			{"amount-one-decimal-place", "a conversion failure in both, never a rounded number", subj,
				body("15/Mar/2026 09:15 PM", "AED 23,456.0", "SOME BENEFICIARY")},
			{"amount-longer-than-the-bound", "33 digits before the point. The run is [0-9,]{0,24} for the " +
				"same reason the alert's is, and the two executors must agree on what the bound DOES", subj,
				body("15/Mar/2026 09:15 PM", "AED 1,234,567,890,123,456,789,012,345.67", "SOME BENEFICIARY")},
			{"alert-format-body", "the OTHER ENBD format: it carries no Debit Amount block, so this template " +
				"must extract nothing from it. enbd.alert.v1 and enbd.transfer.v1 share a sender domain and " +
				"are separated by nothing but their anchors, so the corpus gate's `ambiguous` counter rests " +
				"on this", "Emirates NBD Transaction advice for account ending with 8642",
				"AED 12,750.00 has been withdrawn from your account 012XXX34XXX56.\n"},
		},
	}
}

func syntheticADIB(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "adib.alert.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	line := func(amount, acct, merchant string) string {
		return "Purchase Transaction Alert\nDear Customer,\nTransaction of " + amount + " debited from your a/c " +
			acct + " at " + merchant + ". Avl Bal is AED 4,321.09\nYours Sincerely,\nAbu Dhabi Islamic Bank\n"
	}
	const subj = "Purchase Transaction Alert"
	return syntheticGroup{
		file:       "synthetic-adib-alert.json",
		template:   "adib.alert.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"purchase", "the shape of the one ADIB alert seen so far, after normalization collapsed the " +
				"terminal descriptor's padding to one U+0020", subj,
				line("AED 73.40", "*123", "SAMPLE STORE1 DU BAI AE")},
			{"balance-is-not-the-amount", "the amount anchor starts at Transaction of, so the larger " +
				"Avl Bal figure later on the line is never read as the amount", subj,
				line("AED 12.50", "*123", "SAMPLE CAFE DUBAI AE")},
			{"thousands-separator", "the [0-9,]{0,24} run", subj,
				line("AED 12,750.00", "*123", "SAMPLE STORE DUBAI AE")},
			{"merchant-with-dot", "the merchant capture is non-greedy up to the first \". Avl Bal\", so a dot " +
				"inside the merchant name stays in it", subj,
				line("AED 99.00", "*123", "SAMPLE.AE DUBAI AE")},
			{"four-digit-account", "last4 keeps the last four of up to eight digits", subj,
				line("AED 99.00", "*4321", "SAMPLE STORE DUBAI AE")},
			{"account-without-star", "the star is optional", subj,
				line("AED 99.00", "123", "SAMPLE STORE DUBAI AE")},
			{"foreign-currency", "the ccy group wins over default_currency", subj,
				line("USD 25.00", "*123", "SAMPLE STORE NEW YORK US")},
			{"foreign-currency-no-space", "the currency-adjacent pattern runs first, as in enbd.alert.v1", subj,
				line("USD25.00", "*123", "SAMPLE STORE NEW YORK US")},
			{"no-currency-prefix", "the ccy group does not participate; default_currency applies", subj,
				line("73.40", "*123", "SAMPLE STORE DUBAI AE")},
			{"case-folded", `flags ["i"] fold the patterns, but body_contains is an exact literal: an upper-cased ` +
				"alert does not pass the gate and goes to review", subj,
				"TRANSACTION OF AED 73.40 DEBITED FROM YOUR A/C *123 AT SAMPLE STORE DUBAI AE. AVL BAL IS AED 1.00\n"},
			{"newline-separated", "a line break where a space was, as a plain-text wrap leaves it", subj,
				"Transaction of AED 73.40\ndebited from your a/c *123\nat SAMPLE STORE DUBAI AE.\nAvl Bal is AED 1.00\n"},
			{"no-balance-sentence", "merchant is anchored on the Avl Bal sentence and is not required; amount, " +
				"direction and last4 still extract", subj,
				"Transaction of AED 73.40 debited from your a/c *123 at SAMPLE STORE DUBAI AE.\n"},
			{"credit-wording", "no credit alert has been seen, so no credit wording is guessed: this must not " +
				"match and goes to review", "Credit Transaction Alert",
				"Transaction of AED 73.40 credited to your a/c *123. Avl Bal is AED 1.00\n"},
			{"balance-only", "a balance line alone is not a transaction", subj,
				"Avl Bal is AED 4,321.09\n"},
			{"amount-without-decimals", "conversion failure, not a zero amount", subj,
				line("AED 73", "*123", "SAMPLE STORE DUBAI AE")},
			{"amount-longer-than-the-bound", "33 digits before the point; the run is bounded at {0,24}", subj,
				line("AED 1,234,567,890,123,456,789,012,345.67", "*123", "SAMPLE STORE DUBAI AE")},
		},
	}
}

func syntheticADIBAccount(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "adib.account.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	line := func(amount, verb, acct string) string {
		return "Debit Transaction Alert\nDear Customer,\n" + amount + " was " + verb + " your account " + acct +
			". Your available account balance is AED 1,234.56\nYours Sincerely,\nAbu Dhabi Islamic Bank\n"
	}
	const debit, credit = "debited from", "credited to"
	return syntheticGroup{
		file:       "synthetic-adib-account.json",
		template:   "adib.account.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"debit", "the shape of the ADIB debit alert seen so far", "Debit Transaction Alert",
				line("AED 41.25", debit, "*456")},
			{"credit", "the credit branch, and on_match setting direction", "Credit Transaction Alert",
				line("AED 41.25", credit, "*456")},
			{"balance-is-not-the-amount", "the amount must sit right before the verb, so the balance figure " +
				"later on the line is never read as the amount", "Debit Transaction Alert",
				line("AED 9.99", debit, "*456")},
			{"thousands-separator", "the [0-9,]{0,24} run", "Debit Transaction Alert",
				line("AED 12,750.00", debit, "*456")},
			{"foreign-currency", "the ccy group wins over default_currency", "Debit Transaction Alert",
				line("USD 25.00", debit, "*456")},
			{"foreign-currency-no-space", "the currency-adjacent pattern runs first, as in enbd.alert.v1",
				"Credit Transaction Alert", line("USD25.00", credit, "*456")},
			{"no-currency-prefix", "the ccy group does not participate; default_currency applies",
				"Debit Transaction Alert", line("41.25", debit, "*456")},
			{"four-digit-account", "last4 keeps the last four of up to eight digits", "Debit Transaction Alert",
				line("AED 41.25", debit, "*4567")},
			{"account-without-star", "the star is optional", "Credit Transaction Alert",
				line("AED 41.25", credit, "456")},
			{"newline-separated", "a line break where a space was", "Debit Transaction Alert",
				"AED 41.25\nwas debited from your account\n*456. Your available account balance is AED 1.00\n"},
			{"debit-then-credit", "first entry wins: the debit entry runs first", "Debit Transaction Alert",
				"AED 1.00 was debited from your account *456. AED 2.00 was credited to your account *456. " +
					"Your available account balance is AED 1.00\n"},
			{"purchase-alert-body", "the OTHER ADIB format: adib.alert.v1 owns it, and it lacks this " +
				"template's gate literal, so the two cannot both match one message", "Purchase Transaction Alert",
				"Transaction of AED 73.40 debited from your a/c *123 at SAMPLE STORE DUBAI AE. Avl Bal is AED 1.00\n"},
			{"neither-verb", "no amount entry produces a value: the required-field gate fires", "Debit Transaction Alert",
				line("AED 41.25", "reserved on", "*456")},
			{"amount-without-decimals", "conversion failure, not a zero amount", "Debit Transaction Alert",
				line("AED 41", debit, "*456")},
			{"amount-longer-than-the-bound", "33 digits before the point; the run is bounded at {0,24}",
				"Debit Transaction Alert", line("AED 1,234,567,890,123,456,789,012,345.67", debit, "*456")},
		},
	}
}

// dates: the three layouts and every semantic Go's time.Parse decides for us.
// Mirrors TestDateParsingSemanticsTheTypeScriptMirrorMustReproduce, but as a
// fixture the TypeScript executor is checked against rather than a Go-only test.
func syntheticDates() syntheticGroup {
	def := `{
	  "id":"synth.dates","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"body",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"date","type":"date","source":"body",
	     "layouts":["DD-MM-YYYY","DD/Mon/YYYY hh:mm A","DD/Mon/YYYY"],
	     "patterns":["Date: (?P<d>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`
	texts := []syntheticCase{
		{"dd-mm-yyyy", "layout 1, whole string", "", "05-06-2026"},
		{"dd-mon-yyyy-hh-mm-a", "layout 2, whole string", "", "07/Jan/2026 03:14 PM"},
		{"dd-mon-yyyy", "layout 3, whole string", "", "07/Jan/2026"},
		{"month-name-lowercase", "month NAMES fold case in Go", "", "05/jun/2026"},
		{"month-name-uppercase", "and upper too", "", "05/JUN/2026"},
		{"ampm-lowercase", "the AM/PM marker does NOT fold; layout 3 catches it via the first token", "", "07/Jan/2026 03:14 pm"},
		{"pm-noon", "12 PM stays 12", "", "07/Jan/2026 12:00 PM"},
		{"am-midnight", "12 AM is 0", "", "07/Jan/2026 12:00 AM"},
		{"hour-zero-pm", "Go accepts hour 0 in a 12-hour layout; PM adds 12", "", "07/Jan/2026 00:30 PM"},
		{"hour-zero-am", "and AM leaves it", "", "07/Jan/2026 00:30 AM"},
		{"hour-13-pm", "out of range for a 12-hour layout; layout 3 parses the first token", "", "07/Jan/2026 13:14 PM"},
		{"single-digit-fields", "numeric fields need exactly two digits", "", "5-6-2026"},
		{"two-digit-year", "a two-digit year is not a year", "", "05-06-26"},
		{"impossible-day", "calendar ranges are checked; this is not 2 March", "", "31-02-2026"},
		{"leap-day-valid", "2024 is a leap year", "", "29-02-2024"},
		{"leap-day-invalid", "2026 is not", "", "29-02-2026"},
		{"day-zero", "day 0 does not exist", "", "00-06-2026"},
		{"month-thirteen", "month 13 does not exist", "", "05-13-2026"},
		{"trailing-text", "trailing text is an error, which is why the first-token attempt exists", "", "05-06-2026extra"},
		{"first-token-fallback", "v1's strings.Fields(s)[0], expressed as a layout attempt", "", "07/Jan/2026 garbage"},
		{"surrounded-by-spaces", "trimmed with the executor's own cutset before parsing", "", "  07/Jan/2026  "},
		{"surrounded-by-tab-and-cr", "\\t and \\r are in the cutset", "", "\t05-06-2026\r"},
		{"surrounded-by-nbsp", "U+00A0 is NOT in the cutset; JavaScript's trim() would remove it", "", " 05-06-2026 "},
		{"surrounded-by-bom", "U+FEFF is NOT in the cutset; JavaScript's trim() would remove it", "", "\ufeff05-06-2026"},
		{"empty", "no date; the template still matches because date is not required", "", ""},
		{"iso-8601", "a shape neither layout covers, and one Date.parse would happily accept", "", "2026-06-05T00:00:00Z"},
		{"us-order", "06-05-2026 is 6 May under DD-MM-YYYY, not 5 June", "", "06-05-2026"},
		{"tab-separated-first-token", "the fallback splits on U+0020 only, so a tab is not a separator", "", "07/Jan/2026\tgarbage"},
	}
	g := syntheticGroup{file: "synthetic-dates.json", template: "synth.dates", definition: def}
	for _, c := range texts {
		g.cases = append(g.cases, syntheticCase{
			name: c.name, why: c.why, subject: "",
			body: "Amt: 1.00\nDate: " + c.body,
		})
	}
	return g
}

// amounts: rule 5, including the two int64 boundaries and the trim set.
func syntheticAmounts() syntheticGroup {
	def := `{
	  "id":"synth.amounts","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","flags":["i"],
	     "patterns":["Amt: (?P<ccy>[a-z]{3} )?(?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"}
	  ],
	  "required":["amount","direction"]}`
	texts := []syntheticCase{
		{"plain", "the ordinary case", "", "250.00"},
		{"grouped", "commas are removed before the shape check", "", "1,250.75"},
		{"zero", "0.00 is a VALUE; Currency is what says an amount was extracted", "", "0.00"},
		{"many-commas", "comma placement is not validated, only removed", "", "1,2,3.00"},
		{"leading-comma-removed", "a leading comma leaves a valid shape", "", ",250.00"},
		{"no-decimals", "the shape needs exactly two", "", "250"},
		{"one-decimal", "one is not two", "", "250.0"},
		{"three-decimals", "three is not two", "", "250.000"},
		{"negative", "amounts are positive; direction carries the sign", "", "-250.00"},
		{"plus-signed", "a sign of either kind fails the shape", "", "+250.00"},
		{"int64-max", "92233720368547758.07 is exactly 2^63-1 minor units", "", "92233720368547758.07"},
		{"int64-overflow", "one fils more does not fit an int64, and is not an amount", "", "92233720368547758.08"},
		{"huge", "far past any integer a double could hold exactly", "", "999999999999999999999.99"},
		{"spaces-around", "trimmed with the executor's own cutset", "", "  250.00  "},
		{"vertical-tab-around", "U+000B is in the cutset in both languages", "", "\v250.00\v"},
		{"nbsp-around", "U+00A0 is NOT; JavaScript's trim() would remove it and change the answer", "", " 250.00"},
		{"bom-around", "U+FEFF is NOT either", "", "\ufeff250.00"},
		{"currency-uppercase", "the ccy group, upper case", "", "USD 99.99"},
		{"currency-lowercase", `flags ["i"] lets it match; asciiUpper normalizes it`, "", "usd 99.99"},
		{"currency-mixed", "mixed case folds to upper", "", "Usd 99.99"},
		{"arabic-indic-digits", "U+0660-U+0669 are digits to Unicode and not to this executor", "", "٢٥٠.٠٠"},
		{"empty-capture", "the group matched nothing; the entry falls through", "", ""},
	}
	g := syntheticGroup{file: "synthetic-amounts.json", template: "synth.amounts", definition: def}
	for _, c := range texts {
		g.cases = append(g.cases, syntheticCase{name: c.name, why: c.why, body: "Amt: " + c.body})
	}
	return g
}

// currency: rule 5's ccy group and the ASCII-ONLY upper-casing.
//
// The load-bearing case is dotless-i. Go's asciiUpper leaves U+0131 alone and
// the result fails the three-upper-case-letters check, so the amount does not
// convert. JavaScript's toUpperCase maps "ıed" to "IED", which passes — a
// mirror that reached for the built-in would extract an amount in a currency
// that was never written, and nothing would error. The class is [^ \n]{3} and
// the entry carries no flags on purpose: this case is about the CONVERSION, and
// a case-insensitive class would drag Go's and JavaScript's differing fold
// orbits for U+0131 into it as well.
func syntheticCurrency() syntheticGroup {
	def := `{
	  "id":"synth.currency","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Amt: (?P<ccy>[^ \\n]{3} )?(?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"}
	  ],
	  "required":["amount","direction"]}`
	rows := []syntheticCase{
		{"absent", "the group does not participate; default_currency applies", "", "Amt: 5.00"},
		{"upper", "already upper case", "", "Amt: AED 5.00"},
		{"lower", "a-z folds to A-Z", "", "Amt: aed 5.00"},
		{"mixed", "and mixed", "", "Amt: Aed 5.00"},
		{"dotless-i", "U+0131 upper-cases to \"I\" in JavaScript and NOT in Go; Go refuses the amount", "", "Amt: \u0131ed 5.00"},
		{"sharp-s", "U+00DF upper-cases to \"SS\", which is four letters and fails either way", "", "Amt: \u00dfed 5.00"},
		{"micro-sign", "U+00B5 upper-cases to Greek capital Mu in JavaScript, which is not [A-Z]", "", "Amt: \u00b5ed 5.00"},
		{"turkish-dotted-capital", "U+0130 is already upper case and is still not [A-Z]", "", "Amt: \u0130ED 5.00"},
		{"digit-in-code", "a currency code is three LETTERS", "", "Amt: AE1 5.00"},
		{"four-letters", "the group needs exactly three plus a space, so it does not participate", "", "Amt: AEDX 5.00"},
		{"aed-two-decimals", "a two-decimal amount in an exponent-2 currency converts", "", "Amt: AED 12.34"},
		{"kwd-three-decimals", "KWD has exponent 3; the shape refuses the third decimal", "", "Amt: KWD 12.345"},
		{"kwd-two-decimals", "KWD has exponent 3; two printed decimals are not fils, so the amount is refused", "", "Amt: KWD 12.34"},
		{"bhd-lower", "the exponent check runs after asciiUpper", "", "Amt: bhd 1.50"},
		{"omr", "OMR has exponent 3", "", "Amt: OMR 3.00"},
		{"jpy", "JPY has exponent 0; 1,200.00 would otherwise be read as 120000 minor units", "", "Amt: JPY 1,200.00"},
		{"krw", "KRW has exponent 0", "", "Amt: KRW 5000.00"},
	}
	return syntheticGroup{file: "synthetic-currency.json", template: "synth.currency", definition: def, cases: rows}
}

// fallthrough: rule 3, which says a CONVERSION FAILURE moves to the next
// pattern and then to the next entry, and never writes a zero value.
//
// The distinction only becomes visible when something later would have
// succeeded: an executor that treats an empty capture as a merchant and one
// that falls through both leave the field empty when there is nothing else to
// try, so a fixture without a second pattern cannot tell them apart.
func syntheticFallthrough() syntheticGroup {
	def := `{
	  "id":"synth.fallthrough","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Amt: (?P<amt>[^\\n]*)","Total: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"merchant","type":"text","source":"body",
	     "patterns":["To: (?P<v>[^\\n]*)","Payee: (?P<v>[^\\n]+)"]},
	    {"field":"merchant","type":"text","source":"body","patterns":["Vendor: (?P<v>[^\\n]+)"]},
	    {"field":"last4","type":"last4","source":"body",
	     "patterns":["Card: (?P<v>[^\\n]*)","Acct: (?P<v>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`
	rows := []syntheticCase{
		{"nothing-to-fall-back-to", "the first pattern wins outright", "", "Amt: 10.00\nTo: SHOP\nCard: 1234\n"},
		{"merchant-pattern-fallthrough", "an EMPTY capture is a conversion failure, so the second pattern of the SAME entry runs", "",
			"Amt: 10.00\nTo: \nPayee: CARREFOUR\nCard: 1234\n"},
		{"merchant-entry-fallthrough", "both patterns of the first entry fail, so the second ENTRY for the field runs", "",
			"Amt: 10.00\nTo: \nVendor: SHOP\nCard: 1234\n"},
		{"merchant-whitespace-only-fallthrough", "trimmed to empty is still empty", "",
			"Amt: 10.00\nTo:    \nPayee: CARREFOUR\nCard: 1234\n"},
		{"amount-pattern-fallthrough", "a capture that fails the shape check falls through rather than becoming 0", "",
			"Amt: \nTotal: 10.00\nTo: SHOP\nCard: 1234\n"},
		{"amount-bad-shape-fallthrough", "and so does one that is not a number at all", "",
			"Amt: N/A\nTotal: 10.00\nTo: SHOP\nCard: 1234\n"},
		{"last4-pattern-fallthrough", "no digits is a conversion failure, not an empty last4", "",
			"Amt: 10.00\nTo: SHOP\nCard: \nAcct: 9999\n"},
		{"first-entry-still-wins-when-it-succeeds", "the second merchant entry must NOT run", "",
			"Amt: 10.00\nTo: FIRST\nVendor: SECOND\nCard: 1234\n"},
		{"everything-falls-through", "nothing produced, and the empty groups say which", "",
			"Amt: \nTo: \nCard: \n"},
	}
	return syntheticGroup{file: "synthetic-fallthrough.json", template: "synth.fallthrough", definition: def, cases: rows}
}

// last4 and merchant text: rules 3 and 7, plus the capture bound.
func syntheticTextAndLast4() syntheticGroup {
	def := `{
	  "id":"synth.text","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"merchant","type":"text","source":"body","patterns":["To: (?P<v>[^\\n]*)"]},
	    {"field":"last4","type":"last4","source":"body","patterns":["Card: (?P<v>[^\\n]*)"]}
	  ],
	  "required":["amount","direction"]}`
	rows := []struct{ name, why, merchant, card string }{
		{"ordinary", "the happy path", "CARREFOUR DUBAI", "XXXX1234"},
		{"card-all-digits", "the LAST four, not the first", "SHOP", "1234567890"},
		{"card-two-digits", "fewer than four is still a value", "SHOP", "12"},
		{"card-one-digit", "one digit is the minimum", "SHOP", "7"},
		{"card-no-digits", "no digits is a conversion failure, not an empty last4", "SHOP", "ABCD"},
		{"card-separated", "non-digits are dropped wherever they are", "SHOP", "1-2-3-4-5"},
		{"card-arabic-indic", "Arabic-Indic digits are not ASCII digits", "SHOP", "١٢٣٤"},
		{"card-empty", "the group participated and captured nothing", "SHOP", ""},
		{"merchant-empty", "an empty capture is not a merchant; the field stays unset", "", "XXXX1234"},
		{"merchant-spaces-only", "trimmed to empty, so still not a merchant", "   ", "XXXX1234"},
		{"merchant-cr-inside", `[^\n] includes \r in BOTH engines, which a bare . does not`, "CARREFOUR\rDUBAI", "XXXX1234"},
		{"merchant-nbsp-around", "U+00A0 is not trimmed, so it stays in the merchant", " CARREFOUR ", "XXXX1234"},
		{"merchant-arabic", "the corpus is Arabic; rune counting must not be byte counting", "بقالة الاتحاد", "XXXX1234"},
		{"merchant-512-runes", "exactly at MaxCaptureRunes, in 2-byte runes", repeatRune('م', MaxCaptureRunes), "XXXX1234"},
		{"merchant-513-runes", "one rune over: a conversion failure, not a truncated merchant", repeatRune('م', MaxCaptureRunes+1), "XXXX1234"},
		{"merchant-emoji", "astral runes count as ONE, which is why [...s].length is the mirror of RuneCountInString", "🏪 SHOP", "XXXX1234"},
		{"merchant-300-astral-runes", "300 runes and 600 UTF-16 units: a mirror counting s.length would refuse a merchant Go keeps",
			repeatRune('🏪', 300), "XXXX1234"},
		{"merchant-513-astral-runes", "513 runes is over the bound in BOTH counts; the pair above and below is what makes the unit unambiguous",
			repeatRune('🏪', MaxCaptureRunes+1), "XXXX1234"},
	}
	g := syntheticGroup{file: "synthetic-text-last4.json", template: "synth.text", definition: def}
	for _, r := range rows {
		g.cases = append(g.cases, syntheticCase{
			name: r.name, why: r.why,
			body: "Amt: 10.00\nTo: " + r.merchant + "\nCard: " + r.card + "\n",
		})
	}
	return g
}

// empty capture groups: the diagnostic the corpus never exercises.
func syntheticEmptyGroups() syntheticGroup {
	def := `{
	  "id":"synth.groups","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Amt: (?P<ccy>[A-Z]{3} )?(?P<amt>[^\\n]*)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"merchant","type":"text","source":"body","patterns":["To: (?P<v>[^\\n]*)"]},
	    {"field":"last4","type":"last4","source":"body","patterns":["Card: (?P<v>[^\\n]*)"]}
	  ],
	  "required":["amount","direction"]}`
	rows := []syntheticCase{
		{"none-empty", "nothing to report", "", "Amt: AED 10.00\nTo: SHOP\nCard: 1234\n"},
		{"ccy-absent-is-not-empty", "an optional group that did not PARTICIPATE has index -1 and is not an empty group", "",
			"Amt: 10.00\nTo: SHOP\nCard: 1234\n"},
		{"merchant-empty", "one label", "", "Amt: AED 10.00\nTo: \nCard: 1234\n"},
		{"two-empty", "sorted and deduplicated, and qualified by FIELD so last4_v and merchant_v are distinguishable", "",
			"Amt: AED 10.00\nTo: \nCard: \n"},
		{"three-empty", "the amount group too; amt_ and v_ collide without the field qualifier", "",
			"Amt: \nTo: \nCard: \n"},
		{"empty-survives-a-failed-match", "EmptyGroups is meaningful on the error path; that is what diag stores", "",
			"To: \nCard: \n"},
	}
	g := syntheticGroup{file: "synthetic-empty-groups.json", template: "synth.groups", definition: def}
	g.cases = rows
	return g
}

// The DIB cascade: override, on_match, the unconditional const default, and
// the two gates that separate the two DIB layouts. Uses the PUBLISHED seeds.
func syntheticDIB(t *testing.T) []syntheticGroup {
	t.Helper()
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	const card = "إشعار مشتريات\nالمبلغ\nAED 250.00\nبتاريخ 05-06-2026\n" +
		"الدفع الى\nCARREFOUR DUBAI\nرقم البطاقة\nXXXX1234"
	return []syntheticGroup{
		{
			file: "synthetic-dib-card.json", template: "dib.card.v1", definition: read("dib.card.v1.json"),
			cases: []syntheticCase{
				{"purchase", "the shape 364 corpus cases have, stated once explicitly", "", card},
				{"merchant-with-cr", `[^\n] must keep \r in both engines`, "",
					"إشعار مشتريات\nالمبلغ\nAED 250.00\nبتاريخ 05-06-2026\nالدفع الى\nCARREFOUR\rDUBAI\nرقم البطاقة\nXXXX1234"},
				{"empty-merchant-line", "the merchant group participates and captures nothing", "",
					"إشعار مشتريات\nالمبلغ\nAED 250.00\nبتاريخ 05-06-2026\nالدفع الى\n\nرقم البطاقة\nXXXX1234"},
				{"gated-out", "body_contains excludes the account layout", "",
					"إشعار إيداع\nالمبلغ\nAED 1.00\nبتاريخ 05-06-2026"},
				{"no-date", "date is required; this is what a bank format change looks like", "",
					"إشعار مشتريات\nالمبلغ\nAED 250.00\nالدفع الى\nSHOP\nرقم البطاقة\nXXXX1234"},
				{"foreign-currency", "the ccy group carries a non-default currency", "",
					"إشعار مشتريات\nالمبلغ\nUSD 25.00\nبتاريخ 05-06-2026\nالدفع الى\nSHOP\nرقم البطاقة\nXXXX1234"},
				{"amount-longer-than-the-bound", "same bound as ENBD, but here the mandatory Arabic anchor means the " +
					"engine cannot start mid-number, so bounded and unbounded reach the same answer by different routes", "",
					"إشعار مشتريات\nالمبلغ\nAED 1,234,567,890,123,456,789,012,345.67\nبتاريخ 05-06-2026\nالدفع الى\nSHOP\nرقم البطاقة\nXXXX1234"},
			},
		},
		{
			file: "synthetic-dib-account.json", template: "dib.account.v1", definition: read("dib.account.v1.json"),
			cases: []syntheticCase{
				{"deposit-whose-description-says-debit",
					"the override entry: v1 dib.go:79-83 re-derives direction AFTER the four-way cascade", "",
					"إشعار إيداع\nالمبلغ\nAED 1,250.75\nبتاريخ 05-06-2026\nالمعاملة\nSALARY TRNSFER DEBIT\nمن حساب\n0123456789"},
				{"deposit-plain", "without the DEBIT suffix the cascade's credit survives", "",
					"إشعار إيداع\nالمبلغ\nAED 1,250.75\nبتاريخ 05-06-2026\nالمعاملة\nSALARY TRNSFER\nمن حساب\n0123456789"},
				{"withdrawal", "the second cascade entry, two patterns in one entry", "",
					"إشعار سحب\nالمبلغ\nAED 100.00\nبتاريخ 05-06-2026\nالمعاملة\nATM\nمن حساب\n0123456789"},
				{"debit-notice", "the first of that entry's two patterns", "",
					"إشعار خصم\nالمبلغ\nAED 100.00\nبتاريخ 05-06-2026\nالمعاملة\nFEE\nمن حساب\n0123456789"},
				{"from-the-account", "the third cascade entry", "",
					"من الحساب\nالمبلغ\nAED 100.00\nبتاريخ 05-06-2026\nالمعاملة\nX\nمن حساب\n0123456789"},
				{"unconditional-default", "no cascade pattern matches: the pattern-less const entry is the default", "",
					"المبلغ\nAED 100.00\nبتاريخ 05-06-2026\nالمعاملة\nX\nمن حساب\n0123456789"},
				{"transfer-flag", "is_transfer, and its i flag", "",
					"إشعار إيداع\nالمبلغ\nAED 1.00\nبتاريخ 05-06-2026\nالمعاملة\nsalary transfer\nمن حساب\n0123456789"},
				{"transfer-flag-misspelling", "v1 anchors on TRNSFER as well; the bank writes both", "",
					"إشعار إيداع\nالمبلغ\nAED 1.00\nبتاريخ 05-06-2026\nالمعاملة\nTRNSFER IN\nمن حساب\n0123456789"},
				{"gated-out", "body_not_contains excludes the card layout", "", card},
			},
		},
	}
}

const (
	dibOwnAccounts   = "بين حساباتك"
	dibWithinBank    = "الى حسابات آخرى داخل البنك"
	dibOtherUAEBank  = "الى بنك آخر داخل الدولة"
	dibDone          = "تمت بنجاح"
	dibPending       = "قيد الأنتظار"
	dibInProgress    = "قيد التنفيذ"
	dibVATLine       = "(يشمل 5% ضريبة القيمة المضافة)\n"
	dibFromPlacehold = "[From Account FRM]"
	dibCurrentAcct   = "حساب جاري"
)

type dibNotice struct {
	kind, date, vat, amount, from, label, to, bank, status string
}

func (n dibNotice) body() string {
	b := "تحويل الأموال\nعزيزي المتعامل,\nإشعار تحويل الأموال " + n.kind + " بتاريخ " + n.date +
		" بالتفاصيل التالية.\nالمبلغ\n" + n.vat + n.amount + "\nمن حساب\n" + n.from + "\n" + n.label +
		"\nالى\n" + n.to + "\n"
	if n.bank != "" {
		b += "البنك المستفيد\n" + n.bank + "\n"
	}
	return b + "الحالة\n" + n.status + "\nالرقم المرجعي\n[Reference Number]\nمع اطيب التحيات،\nبنك دبي الإسلامي"
}

func dibNoticeOf(kind string) dibNotice {
	n := dibNotice{
		kind: kind, date: "05-06-2026 07:41", vat: dibVATLine, amount: "AED 4321.09",
		from: "001-000-123XXXX01", label: dibFromPlacehold, to: "001-000-123XXXX02", status: dibDone,
	}
	if kind == dibOtherUAEBank {
		n.to, n.bank = "AE000000000000000000001", "sample bank uae"
	}
	return n
}

func dibMoneyTransfer(amount, bank, status string) string {
	b := "Money Transfer\nDear Customer,\nThis is to notify you that a Domestic Fund Transfer transaction has " +
		"been initiated on 07-23-2026 11:12:13 with the following details.\nAmount\n" + amount +
		"\nFrom\nAE0000000000000XXXXX101\n[From Account FRM]\nTo\nAE0000000000000XXXXX002\n"
	if bank != "" {
		b += "Beneficiary Bank\n" + bank + "\n"
	}
	return b + "Status\n" + status + "\nReference Number\n[Reference Number]\nBest Regards,\nDubai Islamic Bank"
}

const dibDebitAlert = "إشعار خصم\nعزيزي المتعامل,\nإشعار\nخصم\nمن الحساب بتاريخ 05-06-2026 بالتفاصيل التالية.\n" +
	"المبلغ\nAED 4,321.09\nمن حساب\n001-000-XXXX123-01\nحساب جاري\nالمعاملة\nMB FUND TRANSFER DEBIT\n" +
	"الحالة\nتمت بنجاح\nالرقم المرجعي\nFT00000000000"

func syntheticDIBTransfer(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "dib.transfer.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	with := func(kind string, f func(*dibNotice)) string {
		n := dibNoticeOf(kind)
		f(&n)
		return n.body()
	}
	keep := func(*dibNotice) {}
	return syntheticGroup{
		file:       "synthetic-dib-transfer.json",
		template:   "dib.transfer.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"own-accounts", "a completed transfer between the customer's own DIB accounts", "DIB Notification",
				with(dibOwnAccounts, keep)},
			{"within-dib", "a completed transfer to another DIB account", "DIB Notification",
				with(dibWithinBank, keep)},
			{"other-uae-bank", "a completed transfer to another UAE bank: the beneficiary bank is the merchant",
				"DIB Notification", with(dibOtherUAEBank, keep)},
			{"current-account-label", "some notices print the account type where the placeholder line is",
				"DIB Notification", with(dibOwnAccounts, func(n *dibNotice) { n.label = dibCurrentAcct })},
			{"thousands-separator", "the [0-9,]{0,24} run", "DIB Notification",
				with(dibOtherUAEBank, func(n *dibNotice) { n.amount = "AED 12,345.67" })},
			{"without-vat-line", "the VAT line between the amount label and the amount is optional",
				"DIB Notification", with(dibWithinBank, func(n *dibNotice) { n.vat = "" })},
			{"foreign-currency", "the ccy group wins over default_currency", "DIB Notification",
				with(dibOtherUAEBank, func(n *dibNotice) { n.amount = "USD 98.76" })},
			{"pending", "a pending notice is not gated in: the transfer is not done, and the completed notice " +
				"for the same transfer follows", "DIB Notification",
				with(dibOtherUAEBank, func(n *dibNotice) { n.status, n.date = dibPending, "2026-06-05 11:12:13" })},
			{"in-progress", "an in-progress notice is not gated in either", "DIB Notification",
				with(dibOtherUAEBank, func(n *dibNotice) { n.status = dibInProgress })},
			{"no-date", "date is required; a new date shape goes to review instead of a wrong day",
				"DIB Notification", with(dibOwnAccounts, func(n *dibNotice) { n.date = "2026-06-05 07:41:00" })},
			{"amount-without-decimals", "conversion failure, not a zero amount", "DIB Notification",
				with(dibOwnAccounts, func(n *dibNotice) { n.amount = "AED 4321" })},
			{"debit-alert-body", "the account debit alert for a transfer: dib.account.v1 owns it", "DIB Notification",
				dibDebitAlert},
			{"english-notice-body", "the English layout: dib.money-transfer.v1 owns it", "DIB Notification",
				dibMoneyTransfer("1,234.56", "Sample Bank PJSC", "Credited to beneficiary")},
		},
	}
}

func syntheticDIBMoneyTransfer(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "dib.money-transfer.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	const done = "Credited to beneficiary"
	return syntheticGroup{
		file:       "synthetic-dib-money-transfer.json",
		template:   "dib.money-transfer.v1",
		definition: string(b),
		cases: []syntheticCase{
			{"domestic-transfer", "the English Money Transfer notice, dated from the email: its body date is " +
				"MM-DD-YYYY, which is not a layout", "DIB Notification",
				dibMoneyTransfer("1,234.56", "Sample Bank PJSC", done)},
			{"no-thousands-separator", "the [0-9,]{0,24} run without a comma", "DIB Notification",
				dibMoneyTransfer("321.09", "Sample Bank PJSC", done)},
			{"foreign-currency", "the ccy group wins over default_currency", "DIB Notification",
				dibMoneyTransfer("USD 98.76", "Sample Bank PJSC", done)},
			{"no-beneficiary-bank", "merchant is not required", "DIB Notification",
				dibMoneyTransfer("1,234.56", "", done)},
			{"other-status", "a status other than credited is not gated in", "DIB Notification",
				dibMoneyTransfer("1,234.56", "Sample Bank PJSC", "Pending")},
			{"arabic-notice-body", "the Arabic layout: dib.transfer.v1 owns it", "DIB Notification",
				dibNoticeOf(dibOtherUAEBank).body()},
			{"amount-without-decimals", "conversion failure, not a zero amount", "DIB Notification",
				dibMoneyTransfer("1,234", "Sample Bank PJSC", done)},
		},
	}
}

func syntheticDIBAccountNotices(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("seed", "dib.account.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	noVAT := dibNoticeOf(dibOwnAccounts)
	noVAT.vat = ""
	return syntheticGroup{
		file: "synthetic-dib-account-notices.json", template: "dib.account.v1", definition: string(b),
		cases: []syntheticCase{
			{"notice-own-accounts", "the published seed does not read a transfer notice: the VAT line blocks " +
				"the amount anchor, so the message goes to review", "DIB Notification",
				dibNoticeOf(dibOwnAccounts).body()},
			{"notice-within-dib", "the same for a transfer to another DIB account", "DIB Notification",
				dibNoticeOf(dibWithinBank).body()},
			{"notice-other-uae-bank", "the same for a transfer to another UAE bank", "DIB Notification",
				dibNoticeOf(dibOtherUAEBank).body()},
			{"notice-english", "the English notice has no Arabic amount label", "DIB Notification",
				dibMoneyTransfer("1,234.56", "Sample Bank PJSC", "Credited to beneficiary")},
			{"notice-without-vat-line", "the hazard: without the VAT line the seed reads a notice, and its " +
				"default direction makes an outgoing transfer a credit", "DIB Notification", noVAT.body()},
			{"debit-alert", "the account debit alert for the same transfer, which the seed files", "DIB Notification",
				dibDebitAlert},
		},
	}
}

func repeatRune(r rune, n int) string {
	out := make([]rune, n)
	for i := range out {
		out[i] = r
	}
	return string(out)
}

func syntheticGroups(t *testing.T) []syntheticGroup {
	t.Helper()
	out := []syntheticGroup{
		syntheticENBD(t),
		syntheticENBDTransfer(t),
		syntheticADIB(t),
		syntheticADIBAccount(t),
		syntheticDates(),
		syntheticAmounts(),
		syntheticTextAndLast4(),
		syntheticEmptyGroups(),
		syntheticCurrency(),
		syntheticFallthrough(),
	}
	out = append(out, syntheticDefaultCurrencyExponent())
	out = append(out, syntheticDIBSeedAmounts(t))
	out = append(out, syntheticDIBTransfer(t), syntheticDIBMoneyTransfer(t), syntheticDIBAccountNotices(t))
	return append(out, syntheticDIB(t)...)
}

func syntheticDefaultCurrencyExponent() syntheticGroup {
	def := `{
	  "id":"synth.kwd","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"KWD","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Amt: (?P<ccy>[A-Z]{3} )?(?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"}
	  ],
	  "required":["amount","direction"]}`
	rows := []syntheticCase{
		{"default-kwd", "default_currency KWD has exponent 3, so the amount is refused", "", "Amt: 12.34"},
		{"ccy-overrides-to-aed", "the ccy group resolves AED, which has exponent 2", "", "Amt: AED 12.34"},
		{"ccy-overrides-to-jpy", "the ccy group resolves JPY, which has exponent 0", "", "Amt: JPY 12.34"},
	}
	return syntheticGroup{file: "synthetic-currency-exponent.json", template: "synth.kwd", definition: def, cases: rows}
}

func syntheticDIBSeedAmounts(t *testing.T) syntheticGroup {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("seed", "dib.card.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	body := func(amount string) string {
		return "إشعار مشتريات\nالمبلغ\n" + amount + "\nبتاريخ 05-06-2026\n" +
			"الدفع الى\nSHOP\nرقم البطاقة\nXXXX1234"
	}
	return syntheticGroup{
		file: "synthetic-dib-card-seed.json", template: "dib.card.v1", definition: string(b),
		cases: []syntheticCase{
			{"aed", "the published seed reads a two-decimal AED amount", "", body("AED 250.00")},
			{"aed-at-end-of-body", "the trailing context also accepts the end of the text", "",
				"إشعار مشتريات\nبتاريخ 05-06-2026\nالمبلغ\nAED 250.00"},
			{"kwd-three-decimals", "the seed refuses a third decimal instead of reading 12.34", "", body("KWD 12.345")},
			{"aed-three-decimals", "the third decimal is refused whatever the currency", "", body("AED 12.345")},
			{"kwd-two-decimals", "KWD has exponent 3, so the executor refuses the amount", "", body("KWD 12.34")},
			{"jpy", "JPY has exponent 0, so the executor refuses the amount", "", body("JPY 1,200.00")},
		},
	}
}

func buildSyntheticFixture(t *testing.T, g syntheticGroup) ([]byte, templateFixture) {
	t.Helper()
	d, err := ParseDefinition([]byte(g.definition))
	if err != nil {
		t.Fatalf("%s: %v", g.file, err)
	}
	// A synthetic definition must be one the store would really accept.
	// Otherwise the fixture pins behaviour on a template that could never be
	// published, which is a fact about nothing.
	if err := ValidateForPublish(d); err != nil {
		t.Fatalf("%s: definition is not publishable: %v", g.file, err)
	}
	if d.ID != g.template {
		t.Fatalf("%s: definition id %q, group says %q", g.file, d.ID, g.template)
	}
	var compactBuf bytes.Buffer
	if err := json.Compact(&compactBuf, []byte(g.definition)); err != nil {
		t.Fatal(err)
	}
	f := templateFixture{
		Note: "Written by internal/tmpl TestWriteSyntheticTemplateFixtures. Regenerate with " +
			"HASALA_WRITE_CONFORMANCE=1 go test ./internal/tmpl/ -run TestWriteSyntheticTemplateFixtures " +
			"(no corpus needed); do not hand-edit. These are the input classes the real corpus contains NONE " +
			"of — the ENBD alert format, empty capture groups, and malformed conversions. `expect` is LITERAL " +
			"Go executor output: if a case's name says one thing and Go does another, the fixture records what " +
			"Go does and the TypeScript executor must reproduce THAT.",
		Spec:              "server/internal/tmpl/v2-template-format.md",
		SchemaVersion:     1,
		Template:          d.ID,
		Kind:              "synthetic",
		NormalizerVersion: d.NormalizerVersion,
		Definition:        compactBuf.Bytes(),
		Cases:             []templateCase{},
	}
	c, err := Compile(d)
	if err != nil {
		t.Fatalf("%s: %v", g.file, err)
	}
	seen := map[string]bool{}
	for _, sc := range g.cases {
		if seen[sc.name] {
			t.Fatalf("%s: duplicate case name %q", g.file, sc.name)
		}
		seen[sc.name] = true
		e, execErr := c.Execute(sc.subject, sc.body)
		f.Cases = append(f.Cases, templateCase{
			Name:                 fmt.Sprintf("%s/%s", d.ID, sc.name),
			Source:               "SYNTHETIC: " + sc.why,
			SubjectBase64:        base64.StdEncoding.EncodeToString([]byte(sc.subject)),
			NormalizedBodyBase64: base64.StdEncoding.EncodeToString([]byte(sc.body)),
			Expect:               expectOf(e, execErr),
		})
	}
	b, err := encodeTemplateFixture(f)
	if err != nil {
		t.Fatal(err)
	}
	return b, f
}

// TestWriteSyntheticTemplateFixtures regenerates the synthetic half. It needs
// no corpus, so any checkout can reproduce it:
//
//	HASALA_WRITE_CONFORMANCE=1 go test ./internal/tmpl/ -run TestWriteSyntheticTemplateFixtures -v
func TestWriteSyntheticTemplateFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	if err := os.MkdirAll(templateConformanceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, g := range syntheticGroups(t) {
		b, f := buildSyntheticFixture(t, g)
		if err := os.WriteFile(filepath.Join(templateConformanceDir, g.file), b, 0o644); err != nil {
			t.Fatal(err)
		}
		matched := 0
		for _, c := range f.Cases {
			if c.Expect.Matched {
				matched++
			}
		}
		t.Logf("%s: %d cases, %d matched, %d bytes", g.file, len(f.Cases), matched, len(b))
	}
}

// TestSyntheticFixturesAreWhatThisBuildProduces is the staleness guard for the
// synthetic half. Unlike the corpus half's guard it regenerates from the case
// TABLE rather than from the committed inputs, so it also catches a case that
// was added to the table and never written to disk.
func TestSyntheticFixturesAreWhatThisBuildProduces(t *testing.T) {
	for _, g := range syntheticGroups(t) {
		want, _ := buildSyntheticFixture(t, g)
		got, err := os.ReadFile(filepath.Join(templateConformanceDir, g.file))
		if err != nil {
			t.Fatalf("%v; regenerate with %s=1 go test ./internal/tmpl/ -run TestWriteSyntheticTemplateFixtures",
				err, writeFixturesEnv)
		}
		if string(got) != string(want) {
			t.Errorf("conformance/templates/%s is stale: this build produces different bytes. Regenerate with\n"+
				"  %s=1 go test ./internal/tmpl/ -run TestWriteSyntheticTemplateFixtures", g.file, writeFixturesEnv)
		}
	}
}
