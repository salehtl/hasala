package origin

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The SMTP lane never reads an Authentication-Results header, and this test is
// what keeps that true.
//
// # Why a source scan, and why it lives here
//
// origin/dkim.go's package comment states the rule outright: on SMTP-received
// mail any hop that can open a TCP connection can forge an Authentication-
// Results header claiming dkim=pass for a bank, so this receiver recomputes
// origin from a signature and a DNS key and NEVER reads that header. The Gmail
// mailbox lane (spec D4) does trust Authentication-Results — but ONLY the one
// Gmail itself wrote, and ONLY over an authenticated provider API, and that
// parser lives in client/src (client/src/mail/authres.ts). The hard fence in
// D4 is that the Go side never grows an A-R reader of its own. This test pins
// that: no non-test file under internal/ may READ an Authentication-Results
// header.
//
// It scans source TEXT rather than types, the same trade verify/inbound.go's
// deliverRe makes: it needs no build, and it cannot be fooled by anything a
// reviewer would not also miss. Its own failure mode — a regex that silently
// matches nothing — is closed by the positive control below, which asserts the
// scan really does see header-name literals in the tree.
//
// # The discriminator
//
// Reading a header by name requires naming it as a quoted string literal to a
// header lookup (h.Get("…")). Prose comments write the name unquoted, and the
// ARC lane legitimately reads "ARC-Authentication-Results" — a DIFFERENT field.
// So the scan matches the QUOTED header-name literal and splits on the ARC-
// prefix: an "ARC-Authentication-Results" literal is allowed; a bare
// "Authentication-Results" literal is the forbidden read.
var arHeaderLiteral = regexp.MustCompile(`(?i)"(arc-)?authentication-results"`)

func TestNoInternalFileReadsAnAuthenticationResultsHeader(t *testing.T) {
	const root = ".." // this package sits in internal/origin; ".." is internal/

	var forbidden []string
	arcAllowed := 0
	filesScanned := 0

	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		filesScanned++
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, m := range arHeaderLiteral.FindAllStringSubmatch(string(src), -1) {
			if strings.EqualFold(m[1], "arc-") {
				// "ARC-Authentication-Results": a distinct field the ARC
				// verifier is allowed to read.
				arcAllowed++
				continue
			}
			forbidden = append(forbidden, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("scanning internal/ for Authentication-Results reads: %v", err)
	}

	// Positive controls: prove the scan actually ran and the regex actually
	// bites, so a green result can never mean "matched nothing because the walk
	// was empty" or "the pattern is broken".
	if filesScanned == 0 {
		t.Fatal("scanned no .go files — the walk root or filter is wrong, and this " +
			"test would pass no matter what any file contained")
	}
	if arcAllowed == 0 {
		t.Fatal("the scan found no \"ARC-Authentication-Results\" literal anywhere in " +
			"internal/, which means the regex matches nothing — a fence that cannot " +
			"fire. internal/arc reads that field; expected at least one match")
	}

	if len(forbidden) > 0 {
		t.Errorf("a non-test file under internal/ reads an Authentication-Results header, "+
			"which the SMTP lane must never do (spec D4; origin/dkim.go package comment). "+
			"The A-R trust primitive lives ONLY in client/src/mail/authres.ts. Offending "+
			"file(s): %s", strings.Join(forbidden, ", "))
	}
}
