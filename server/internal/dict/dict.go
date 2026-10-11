// Package dict is the merchant dictionary's canonicalization and match
// semantics: the oracle that conformance/dict/matching.json pins and that the
// app's bundled dictionary and its Swift matcher must agree with (spec 02 §4.1,
// D-2). It is not in hasalad's build graph (spec 02 §4.4 fence 1).
//
// ledgerd's crowd dictionary — the submission store, the K-distinct-submitter
// gate, moderation, the delta feed and the submitter HMAC — was removed in the
// hasalad surgery (spec 02 §2.3, A-11): the server no longer learns which
// merchants anyone transacts with. The dictionary now ships inside the app
// (spec 03c §8.5), exported from the operator's v1 corpus by
// server/oracle/cmd/export-dictionary.
package dict

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode"
)

// K was ledgerd's crowd-suppression threshold. Nothing enforces it since the
// crowd dictionary went; it stays because conformance/dict/matching.json
// records it in its limits block and the fixture's bytes are pinned.
const K = 3

// Match types. 'regex' is deliberately absent: a regex shipped to every device
// is a denial-of-service and a matcher divergence waiting to happen.
const (
	MatchContains = "contains"
	MatchExact    = "exact"
)

// Bounds on the two user-supplied strings. Runes, not bytes: a bound in bytes
// would silently be three times tighter for an Arabic merchant name.
const (
	maxPatternRunes = 64
	// minPatternRunes is the floor for an `exact` pattern, which matches one
	// merchant string and nothing else.
	minPatternRunes = 2
	// minContainsRunes is the floor for a `contains` pattern, which is a
	// substring test running on every device.
	//
	// A short one is a wildcard wearing a merchant's clothes: `on -> charity`
	// passes every gate this design has — three real users can genuinely submit
	// it — and then matches AMAZON, NOON and TALABAT ONLINE everywhere. The k
	// threshold cannot catch that, because breadth is not rarity.
	//
	// Four is measured rather than guessed: the operator's own 212 seeded v1
	// rules bottom out at exactly four characters, so this rejects nothing
	// real.
	minContainsRunes = 4
	maxCategoryRunes = 32
)

var (
	// ErrInvalidEntry rejects a pattern or category that does not fit the
	// bounded shape.
	ErrInvalidEntry = errors.New("dict: invalid entry")
)

// Entry is one published mapping: the whole of what a client receives.
type Entry struct {
	Pattern  string `json:"pattern"`
	Match    string `json:"match"`
	Category string `json:"category"`
}

// ---------------------------------------------------------------------------
// Canonicalization
// ---------------------------------------------------------------------------

// Canonicalize returns the storable form of an entry, or ErrInvalidEntry.
//
// Canonicalization is a k-gate concern, not tidiness. Without it "CARREFOUR",
// "Carrefour" and "  carrefour  " are three entries with one submitter each
// rather than one entry with three, and the threshold splits into pieces no
// single one of which ever reaches it — while the merchant is just as
// identifying as before.
//
// Errors name the FIELD and never echo the VALUE, following internal/diag:
// the value here is the merchant string itself, and an error that quoted it
// would route the content straight into an operator log.
func Canonicalize(e Entry) (Entry, error) {
	// Checked on the RAW input, before collapsing. A merchant name is one
	// line, and collapse() below squeezes every run of Unicode whitespace —
	// including a newline — to a single space, so without this a two-line
	// paste would be silently JOINED into a valid-looking pattern rather than
	// refused. Silently accepting a caller's structural mistake is how text
	// that was never meant to be a merchant name ends up stored as one.
	if hasLineBreak(e.Pattern) || hasLineBreak(e.Category) {
		return Entry{}, fmt.Errorf("%w: a pattern and a category are each a single line", ErrInvalidEntry)
	}
	out := Entry{
		Pattern:  collapse(e.Pattern),
		Match:    strings.ToLower(strings.TrimSpace(e.Match)),
		Category: collapse(e.Category),
	}
	if out.Match == "" {
		out.Match = MatchContains
	}
	if !slices.Contains([]string{MatchContains, MatchExact}, out.Match) {
		return Entry{}, fmt.Errorf("%w: match must be one of %v (a regex published to every "+
			"client is a fleet-wide execution surface)", ErrInvalidEntry,
			[]string{MatchContains, MatchExact})
	}
	// A `contains` pattern is a substring test that will run on every device,
	// so it carries a higher floor than an `exact` one: see minContainsRunes.
	minRunes := minPatternRunes
	if out.Match == MatchContains {
		minRunes = minContainsRunes
	}
	if n := len([]rune(out.Pattern)); n < minRunes || n > maxPatternRunes {
		return Entry{}, fmt.Errorf("%w: a %q pattern must be %d..%d characters, got %d",
			ErrInvalidEntry, out.Match, minRunes, maxPatternRunes, n)
	}
	if !hasAlnum(out.Pattern) {
		return Entry{}, fmt.Errorf("%w: pattern must contain a letter or a digit; a pattern of "+
			"pure punctuation matches merchants it has nothing to do with", ErrInvalidEntry)
	}
	if hasUnprintable(out.Pattern) {
		return Entry{}, fmt.Errorf("%w: pattern must be a single line of printable text", ErrInvalidEntry)
	}
	if n := len([]rune(out.Category)); n < 2 || n > maxCategoryRunes {
		return Entry{}, fmt.Errorf("%w: category must be 2..%d characters, got %d",
			ErrInvalidEntry, maxCategoryRunes, n)
	}
	if !isCategoryLabel(out.Category) {
		return Entry{}, fmt.Errorf("%w: category must be a short label of letters, digits, "+
			"spaces and -_/&, not free text", ErrInvalidEntry)
	}
	return out, nil
}

// collapse lower-cases, trims, and squeezes every run of whitespace to one
// space. strings.Fields splits on all Unicode space, so a non-breaking space
// pasted out of a bank statement collapses like an ordinary one.
func collapse(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

// hasLineBreak reports whether s contains any rune that ends a line. The list
// is every one Unicode defines, not just \n: U+0085, U+2028 and U+2029 break a
// line in a rendered console exactly as \n does.
func hasLineBreak(s string) bool {
	return strings.ContainsAny(s, "\n\r\v\f  ")
}

func hasAlnum(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return true
		}
	}
	return false
}

// hasUnprintable rejects control, format, surrogate and private-use runes.
// unicode.IsPrint is not enough on its own: it accepts the ASCII space but
// rejects other space runes that collapse() has already removed, and it does
// not consider bidi format characters, which can reorder a rendered merchant
// name in an operator console.
func hasUnprintable(s string) bool {
	for _, r := range s {
		if r == ' ' {
			continue
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Co, r) ||
			unicode.Is(unicode.Cs, r) || !unicode.IsPrint(r) {
			return true
		}
	}
	return false
}

// isCategoryLabel mirrors dict_entries_category_is_a_bounded_label. Keeping the
// two in step is the same argument diag makes: the Go check is the guard, the
// CHECK constraint is the guarantee, because a guarantee that only holds when
// callers behave is not one.
func isCategoryLabel(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		case i > 0 && (r == ' ' || r == '_' || r == '/' || r == '&' || r == '-'):
		default:
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// The submitter pseudonym
// ---------------------------------------------------------------------------
