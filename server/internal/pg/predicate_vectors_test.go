package pg_test

import (
	"encoding/json"
	"errors"
	"os"
	"testing"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/cryptoref/vectors"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// TestPredicateVectorsAgreeAcrossGoAndSQL runs conformance/crypto-v3/
// predicate.json through Go's LooksSealed and the SQL function behind the
// op_log_blob_is_sealed CHECK (spec 01 §15.1: Go, Swift and Postgres must
// agree on every case). The expectation is the file's; neither side computes
// it here.
func TestPredicateVectorsAgreeAcrossGoAndSQL(t *testing.T) {
	raw, err := os.ReadFile("../../../conformance/crypto-v3/predicate.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []vectors.PredicateCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Cases) < 32 {
		t.Fatalf("%d predicate cases; spec 01 V-F has 32", len(file.Cases))
	}
	pool := pgtest.New(t)
	for _, c := range file.Cases {
		b := c.Build()
		if len(b) != c.N {
			t.Fatalf("%s: built %d bytes, the case says %d", c.Name, len(b), c.N)
		}
		got := "ok"
		var re *blob.RefusalError
		if err := blob.LooksSealed(b); errors.As(err, &re) {
			got = re.Check
		}
		if got != c.Want {
			t.Errorf("%s: Go LooksSealed says %s, the vector says %s", c.Name, got, c.Want)
		}
		var ok bool
		if err := pool.QueryRow(bg, `SELECT hasala_frame_is_sealed($1)`, b).Scan(&ok); err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if ok != (c.Want == "ok") {
			t.Errorf("%s: SQL says %v, the vector says %s", c.Name, ok, c.Want)
		}
	}
}
