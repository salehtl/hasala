package tmpl

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// fixtures.go holds the template conformance fixture TYPES and the seed list.
// It is test data, exported (rather than living in a _test.go file) because
// two modules use it: this package's tests re-execute every committed fixture,
// and the corpus fixture writer, which reads the operator's v1 corpus, lives in
// the oracle module (server/oracle/gates/tmpl, spec 02 §4.3) with the corpus
// reader. Nothing in hasalad's build graph reaches this package (spec 02 §4.4
// fence 1).

// CorpusTemplateDir is where the corpus-*.json files live: the same
// repo-relative path inside the private salehtl/hasala-fixtures checkout named
// by HASALA_PRIVATE_FIXTURES, because every case is real bank mail (see
// internal/privatefixtures).
const CorpusTemplateDir = "conformance/templates"

// SeedTemplateFiles are the published seed templates, in the order their files
// are written. Named explicitly rather than globbed: a regeneration must not
// silently pick up a template someone dropped into testdata/.
var SeedTemplateFiles = []string{
	"dib.card.v1.json",
	"dib.account.v1.json",
	"enbd.alert.v1.json",
	"enbd.transfer.v1.json",
	"adib.alert.v1.json",
	"adib.account.v1.json",
}

// TemplateFixture is one committed template conformance file.
type TemplateFixture struct {
	Note          string `json:"note"`
	Spec          string `json:"spec"`
	SchemaVersion int    `json:"schema_version"`
	Template      string `json:"template"`
	// Kind is "corpus" (real v1 mail, regenerated only from a snapshot of the
	// operator's mailbox) or "synthetic" (hand-written inputs for the shapes
	// the corpus contains none of, regenerable anywhere). The distinction is
	// worth carrying: a suite of only the second kind proves the executor
	// agrees with itself about inputs someone imagined.
	Kind              string `json:"kind"`
	NormalizerVersion int    `json:"normalizer_version"`
	// Definition is the template's own JSON, verbatim from testdata, so a case
	// is executable with nothing else.
	Definition json.RawMessage `json:"definition"`
	Cases      []TemplateCase  `json:"cases"`
}

// TemplateCase is one case of a TemplateFixture.
type TemplateCase struct {
	Name   string `json:"name"`
	Source string `json:"source"`
	// Subject and body are base64 for the same reason the normalizer fixtures
	// are: they carry CR, U+FEFF, bidi controls and Arabic, and a JSON string
	// is not the place to find out which of those a reviewer's editor rewrote.
	SubjectBase64        string         `json:"subject_base64"`
	NormalizedBodyBase64 string         `json:"normalized_body_base64"`
	Expect               TemplateExpect `json:"expect"`
}

// TemplateExpect is what Go's executor produced. Every field is recorded on
// every case, including the ones where the template did NOT match: an
// executor that returns a partial extraction where the other returns a zero
// one is a difference the diagnostics ledger would report differently, and
// checking only the matched cases would not see it.
type TemplateExpect struct {
	Matched bool `json:"matched"`
	// Error is the sentinel Execute returned, as a stable string. "" means nil.
	Error string `json:"error"`
	// AmountMinor is a DECIMAL STRING. int64 does not survive JSON in
	// JavaScript — 9,007,199,254,740,993 parses to ...992 — and the TypeScript
	// executor produces a BigInt, so the wire form is the one both can read
	// exactly.
	AmountMinor string `json:"amount_minor"`
	Currency    string `json:"currency"`
	Direction   string `json:"direction"`
	// PostedAt is RFC3339 in UTC, or "" for the zero time (date_from=email, or
	// a body date nothing produced).
	PostedAt    string   `json:"posted_at"`
	Merchant    string   `json:"merchant"`
	Last4       string   `json:"last4"`
	IsTransfer  bool     `json:"is_transfer"`
	EmptyGroups []string `json:"empty_groups"`
}

// ErrorKind maps Execute's error to the stable string the fixture stores.
func ErrorKind(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrNoMatch):
		return "no_match"
	case errors.Is(err, ErrMissingField):
		return "missing_field"
	case errors.Is(err, ErrTooLarge):
		return "too_large"
	case errors.Is(err, ErrDefinition):
		return "definition"
	default:
		return "other"
	}
}

// ExpectOf records what Go's executor produced, in the fixture's form.
func ExpectOf(e Extraction, err error) TemplateExpect {
	posted := ""
	if !e.PostedAt.IsZero() {
		posted = e.PostedAt.UTC().Format(time.RFC3339)
	}
	groups := e.EmptyGroups
	if groups == nil {
		groups = []string{}
	}
	return TemplateExpect{
		Matched:     e.Matched,
		Error:       ErrorKind(err),
		AmountMinor: strconv.FormatInt(e.AmountMinor, 10),
		Currency:    e.Currency,
		Direction:   e.Direction,
		PostedAt:    posted,
		Merchant:    e.Merchant,
		Last4:       e.Last4,
		IsTransfer:  e.IsTransfer,
		EmptyGroups: groups,
	}
}

// LoadSeedTemplates reads the seed templates named by SeedTemplateFiles from
// dir (internal/tmpl/testdata), refusing any that is not publishable: a
// fixture may only be written from a PUBLISHABLE template.
func LoadSeedTemplates(dir string) ([]Definition, []json.RawMessage, error) {
	defs := make([]Definition, 0, len(SeedTemplateFiles))
	raws := make([]json.RawMessage, 0, len(SeedTemplateFiles))
	for _, name := range SeedTemplateFiles {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, nil, err
		}
		d, err := ParseDefinition(b)
		if err != nil {
			return nil, nil, fmt.Errorf("%s: %w", name, err)
		}
		if err := ValidateForPublish(d); err != nil {
			return nil, nil, fmt.Errorf("%s: a fixture may only be written from a PUBLISHABLE template: %w", name, err)
		}
		var compact bytes.Buffer
		if err := json.Compact(&compact, b); err != nil {
			return nil, nil, err
		}
		defs = append(defs, d)
		raws = append(raws, json.RawMessage(compact.Bytes()))
	}
	return defs, raws, nil
}

// EncodeTemplateFixture renders a fixture exactly as it is committed.
func EncodeTemplateFixture(f TemplateFixture) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	if err := e.Encode(f); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
