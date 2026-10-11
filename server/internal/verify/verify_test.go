package verify

import (
	"context"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// insertUser creates an account with two live device writers, dev-a and dev-b.
func insertUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	u := oplogtest.NewUser(t, pool)
	oplogtest.NewWriter(t, pool, u, "dev-a")
	oplogtest.NewWriter(t, pool, u, "dev-b")
	return u
}

// appendHot appends n sealed rows to dev-a's chain through the real appender,
// so every chain hash, counter and AAD is produced by production code.
func appendHot(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		oplogtest.Append(t, pool, u, "dev-a", 1)
	}
}

// appendPairs appends n rows to EACH of dev-a and dev-b, alternating, so the
// log holds two independent chains whose rows interleave by seq.
func appendPairs(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		oplogtest.Append(t, pool, u, "dev-a", 1)
		oplogtest.Append(t, pool, u, "dev-b", 1)
	}
}

func exec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(bg, sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

// tamperable lifts the database's own guarantees as the schema OWNER, which is
// the only way to get a damaged log into it at all: the runtime role cannot
// UPDATE or DELETE op_log, the append-only trigger refuses every role, and the
// CHECKs refuse an unsealed or misplaced blob. A restore into a hand-made
// schema is exactly the database this tool exists for.
func tamperable(t *testing.T, owner *pgxpool.Pool, constraints ...string) {
	t.Helper()
	exec(t, owner, `ALTER TABLE op_log DISABLE TRIGGER op_log_no_rewrite`)
	for _, c := range constraints {
		exec(t, owner, `ALTER TABLE op_log DROP CONSTRAINT `+c)
	}
}

func ids(f []Finding) []string {
	out := make([]string, 0, len(f))
	for _, x := range f {
		out = append(out, x.ID)
	}
	return out
}

func hasFinding(f []Finding, id string) bool {
	for _, x := range f {
		if x.ID == id {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The structural invariants
// ---------------------------------------------------------------------------

func TestS1DetectsAnInjectedGap(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 5)

	tamperable(t, owner)
	exec(t, owner, `DELETE FROM op_log WHERE user_id = $1 AND seq = 3`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S1SeqDense) {
		t.Fatalf("findings %v do not include %s: a hole in the seq space is the one thing "+
			"the append path can never produce, so nothing else will report it", ids(got), S1SeqDense)
	}
}

func TestS2DetectsATamperedBlob(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 3)

	// The LAST byte: inside the AEAD tag. It is inside the hashed bytes and
	// outside the AAD, so exactly one invariant can notice — and the result
	// still looks sealed (a non-zero tag), so S6 must stay quiet too.
	tamperable(t, owner)
	exec(t, owner, `UPDATE op_log SET blob = set_byte(blob, octet_length(blob) - 1, get_byte(blob, octet_length(blob) - 1) # 1)
	               WHERE user_id = $1 AND seq = 2`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S2WriterChain) {
		t.Fatalf("findings %v do not include %s", ids(got), S2WriterChain)
	}
	if hasFinding(got, S3AADMatchesRow) || hasFinding(got, S6Sealed) {
		t.Fatalf("findings %v name the AAD or the predicate for an edited tag byte", ids(got))
	}
}

// Each writer's chain is verified on its own: two devices' rows interleave by
// seq, and a combined chain would report a break on every healthy account.
func TestS2ChecksEachWriterSeparately(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendPairs(t, pool, u, 4)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("a healthy interleaved log yields %v, want none", ids(got))
	}
}

func TestS3DetectsABlobSealedForAnotherPosition(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 3)

	// The last AAD byte is the counter's last digit: "…|dev-a|3" becomes
	// "…|dev-a|4". Only the database's own AAD CHECK refuses that, so it is
	// dropped first.
	tamperable(t, owner, "op_log_aad_matches_position")
	exec(t, owner, `UPDATE op_log SET blob = set_byte(blob, 6 + get_byte(blob, 5) * 256 + get_byte(blob, 6), 52)
	               WHERE user_id = $1 AND seq = 3`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S3AADMatchesRow) {
		t.Fatalf("findings %v do not include %s", ids(got), S3AADMatchesRow)
	}
}

func TestS4DetectsABlobThatIsNotASizeBucket(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 2)

	tamperable(t, owner, "op_log_blob_fills_bucket", "op_log_bucket_is_on_the_ladder", "op_log_blob_is_sealed")
	exec(t, owner, `UPDATE op_log SET blob = blob || blob, size_bucket = 2048 WHERE user_id = $1 AND seq = 1`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S4BucketValid) {
		t.Fatalf("findings %v do not include %s: 2048 is not one of %v", ids(got), S4BucketValid, blob.Buckets)
	}
}

// S6 is the predicate over stored bytes. The op_log_blob_is_sealed CHECK makes
// it unreachable on an intact schema, so the test removes the CHECK first.
func TestS6DetectsAStoredBlobThatDoesNotLookSealed(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 2)

	tamperable(t, owner, "op_log_blob_is_sealed")
	// Zero the nonce: bytes [7+L, 19+L).
	exec(t, owner, `UPDATE op_log SET blob = overlay(blob placing '\x000000000000000000000000'::bytea
	                    FROM 8 + get_byte(blob, 5) * 256 + get_byte(blob, 6) FOR 12)
	               WHERE user_id = $1 AND seq = 2`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S6Sealed) {
		t.Fatalf("findings %v do not include %s", ids(got), S6Sealed)
	}
}

func TestCleanDatabaseYieldsNoFindings(t *testing.T) {
	pool := pgtest.New(t)
	for i := 0; i < 3; i++ {
		u := insertUser(t, pool)
		appendPairs(t, pool, u, 2)
		appendHot(t, pool, u, 1)
	}
	// A user with no log at all: the empty case must not be a finding either.
	insertUser(t, pool)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("clean database yields %v, want none", got)
	}
}

func TestStructuralCanBeScopedToOneUser(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	broken := insertUser(t, pool)
	clean := insertUser(t, pool)
	appendHot(t, pool, broken, 3)
	appendHot(t, pool, clean, 3)
	tamperable(t, owner)
	exec(t, owner, `DELETE FROM op_log WHERE user_id = $1 AND seq = 2`, broken)

	only, err := StructuralFor(bg, pool, []uuid.UUID{clean})
	if err != nil {
		t.Fatalf("StructuralFor: %v", err)
	}
	if len(only) != 0 {
		t.Fatalf("scoping to the healthy user yields %v, want none", ids(only))
	}
	all, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if len(all) == 0 {
		t.Fatal("the unscoped run found nothing, so the scoped run proved nothing")
	}
	for _, f := range all {
		if f.UserID != broken {
			t.Fatalf("finding %s names user %s, want %s", f.ID, f.UserID, broken)
		}
	}
}

// S5 is the only invariant that can see a TRUNCATED tail or a wholly deleted
// log: the surviving rows are dense and chain perfectly. oplog_seq.next_seq is
// the witness: no production path deletes an op row, and a rolled-back append
// restores the counter, so next_seq == max(seq)+1 exactly.
func TestS5DetectsATruncatedTail(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 5)

	tamperable(t, owner)
	exec(t, owner, `DELETE FROM op_log WHERE user_id = $1 AND seq = 5`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if hasFinding(got, S1SeqDense) {
		t.Fatal("S1 reported a truncated tail; if it can, this test is not about S5")
	}
	if !hasFinding(got, S5CounterMatchesHead) {
		t.Fatalf("findings %v do not include %s: 4 dense rows under a counter that says 6 "+
			"means a row was destroyed", ids(got), S5CounterMatchesHead)
	}
}

func TestS5DetectsAWhollyDeletedLog(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 3)

	tamperable(t, owner)
	exec(t, owner, `DELETE FROM op_log WHERE user_id = $1`, u)

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if !hasFinding(got, S5CounterMatchesHead) {
		t.Fatalf("findings %v do not include %s: an empty log under a counter of 4 is not "+
			"a new account", ids(got), S5CounterMatchesHead)
	}
}

func TestS5IsSilentOnAHealthyAndOnAnEmptyLog(t *testing.T) {
	pool := pgtest.New(t)
	busy := insertUser(t, pool)
	appendPairs(t, pool, busy, 3)
	insertUser(t, pool) // never wrote an op: next_seq 1, no rows, and that is correct

	got, err := Structural(bg, pool)
	if err != nil {
		t.Fatalf("Structural: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("clean database yields %v, want none", got)
	}
}
