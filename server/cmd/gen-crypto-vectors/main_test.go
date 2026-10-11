package main

import (
	"testing"

	"github.com/salehtl/hasala/server/internal/cryptoref/vectors"
)

// TestCommittedVectorsAreCurrent regenerates conformance/crypto-v3/ and the
// api-v1 message and step-up files and requires the committed ones byte for
// byte. A change to any byte layout, input or note shows up here first; the
// fix is `go run ./cmd/gen-crypto-vectors` and a reviewed diff of the
// vectors, never an edit by hand.
func TestCommittedVectorsAreCurrent(t *testing.T) {
	files, err := vectors.Generate("../../..")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < 20 {
		t.Fatalf("generated %d files", len(files))
	}
	for _, s := range Diff("../../..", files) {
		t.Errorf("stale vector file: %s (run: cd server && go run ./cmd/gen-crypto-vectors)", s)
	}
}
