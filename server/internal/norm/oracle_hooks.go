package norm

import "time"

// oracle_hooks.go exists for the oracle module (server/oracle, spec 02 §4.3):
// the corpus-equivalence gate moved there with v1ref and corpus, so the
// unexported seams it substitutes into are exported here, and only here. They
// add no behaviour. Nothing in the main module may call them.

// Trimmer is the line-trim function the pipeline is parameterised over (see
// trimmer). The gate swaps in v1's strings.TrimSpace and nothing else.
type Trimmer = trimmer

// NormalizeWithTrim is normalizeWith: Normalize with the trimmer swapped.
func NormalizeWithTrim(version int, raw []byte, receivedAt time.Time, trim Trimmer) (Result, error) {
	return normalizeWith(version, raw, receivedAt, trim)
}

// TrimExplicit is trimExplicit: v2's explicit trim set.
func TrimExplicit(s string) string { return trimExplicit(s) }

// HeadersOf is the header extraction (extract) alone, for the oracle's probe
// that compares it with v1's IMAP envelope over the corpus.
func HeadersOf(raw []byte) (subject, from string, ok bool) {
	_, _, _, subject, from, err := extract(raw)
	return subject, from, err == nil
}
