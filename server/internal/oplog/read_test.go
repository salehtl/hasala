package oplog

import (
	"bytes"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// seedInterleaved appends n rounds of one row from dev-a and one from dev-b,
// so the two writers' chains share one seq space and neither is contiguous in
// it. It returns nothing: every assertion below reads the rows back.
func seedInterleaved(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, n int) {
	t.Helper()
	a := &Appender{Pool: pool}
	for i := 0; i < n; i++ {
		for _, w := range []string{"ios-00000000-0000-4000-8000-00000000000a", "ios-00000000-0000-4000-8000-00000000000b"} {
			c, head, err := a.Head(bg, u, w, blob.StreamHot)
			if err != nil {
				t.Fatal(err)
			}
			rows, _ := chainFrom(t, u, w, blob.StreamHot, c+1, head, 1)
			if _, err := a.AppendClient(bg, u, w, blob.StreamHot, rows, testHeadSig(u, w, rows)); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// writerRows keeps one writer's rows, in the order given.
func writerRows(rows []Row, writer string) []Row {
	var out []Row
	for _, r := range rows {
		if r.WriterID == writer {
			out = append(out, r)
		}
	}
	return out
}

func TestReadReturnsTheLogInSeqOrderAndEachChainVerifies(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	seedInterleaved(t, pool, u, 5)

	rows, err := Read(bg, pool, u, blob.StreamHot, 0, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 10 {
		t.Fatalf("read %d rows, want 10", len(rows))
	}
	for i, r := range rows {
		if r.Seq != int64(i+1) {
			t.Fatalf("row %d has seq %d, want %d", i, r.Seq, i+1)
		}
		if len(r.Blob) == 0 || len(r.BlobHash) != 32 || len(r.PrevHash) != 32 {
			t.Fatalf("row %d came back without its bytes or hashes", i)
		}
	}
	// One writer's rows are 1,3,5,7,9 in seq, which is NOT a gap: each chain
	// is per writer, and each verifies from genesis on its own.
	for _, w := range []string{"ios-00000000-0000-4000-8000-00000000000a", "ios-00000000-0000-4000-8000-00000000000b"} {
		mine := writerRows(rows, w)
		if len(mine) != 5 || mine[1].Seq-mine[0].Seq != 2 {
			t.Fatalf("%s: %d rows; the fixture is not interleaved", w, len(mine))
		}
		if err := VerifyChain(mine, 0, blob.ZeroHash); err != nil {
			t.Fatalf("%s's rows must verify as one chain from genesis: %v", w, err)
		}
	}
}

func TestReadIsScopedToTheUser(t *testing.T) {
	pool := pgtest.New(t)
	a, b := insertUser(t, pool), insertUser(t, pool)
	seedInterleaved(t, pool, a, 3)
	seedInterleaved(t, pool, b, 3)

	rows, err := Read(bg, pool, a, blob.StreamHot, 0, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.UserID != a {
			t.Fatalf("a read for user %s returned a row belonging to %s", a, r.UserID)
		}
	}
	if len(rows) != 6 {
		t.Fatalf("read %d rows, want 6 — the other user's rows leaked in", len(rows))
	}
}

func TestReadPagesFromTheCursor(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	seedInterleaved(t, pool, u, 10)

	var seen []int64
	after := int64(0)
	for {
		rows, err := Read(bg, pool, u, blob.StreamHot, after, 4, 1<<20)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) == 0 {
			break
		}
		for _, r := range rows {
			seen = append(seen, r.Seq)
		}
		after = rows[len(rows)-1].Seq
	}
	if len(seen) != 20 {
		t.Fatalf("paged %d rows, want 20", len(seen))
	}
	for i, q := range seen {
		if q != int64(i+1) {
			t.Fatalf("paged seqs %v are not 1..20", seen)
		}
	}
}

func TestReadStopsAtTheByteBudgetButAlwaysReturnsOneRow(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	seedInterleaved(t, pool, u, 5)

	// Every blob is padded to the smallest bucket, so the budget arithmetic is
	// exact rather than approximate.
	one, err := Read(bg, pool, u, blob.StreamHot, 0, 100, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(one) != 1 {
		t.Fatalf("a 1-byte budget returned %d rows, want exactly 1: a client that "+
			"cannot fetch even one row can never advance its cursor", len(one))
	}
	bucket := len(one[0].Blob)
	two, err := Read(bg, pool, u, blob.StreamHot, 0, 100, 2*bucket)
	if err != nil {
		t.Fatal(err)
	}
	if len(two) != 2 {
		t.Fatalf("a %d-byte budget returned %d rows, want 2", 2*bucket, len(two))
	}
}

func TestTheByteBudgetIsAppliedByTheDatabaseNotOnlyInGo(t *testing.T) {
	// Read's Go-side budget bounds what this process RETAINS. It cannot bound
	// what Postgres sends, because pgx drains a result set it stops scanning —
	// so if the budget lived only in Go, a 500-row page of megabyte blobs would
	// still cross the wire in full. This asserts the database itself returns the
	// budgeted prefix, by running the query directly.
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	seedInterleaved(t, pool, u, 6)

	all, err := Read(bg, pool, u, blob.StreamHot, 0, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	bucket := int64(len(all[0].Blob))

	for _, tc := range []struct {
		budget int64
		want   int
	}{{1, 1}, {bucket, 1}, {2 * bucket, 2}, {100 * bucket, 12}} {
		rows, err := pool.Query(bg, readPageSQL, u, blob.StreamHot, int64(0), 100, tc.budget)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for rows.Next() {
			n++
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		if n != tc.want {
			t.Fatalf("the database returned %d rows for a %d-byte budget, want %d", n, tc.budget, tc.want)
		}
	}
}

func TestReadAndHashesRejectAnUnknownStream(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	if _, err := Read(bg, pool, u, "warm", 0, 10, 1<<20); err == nil {
		t.Fatal("Read accepted a stream that is not hot")
	}
	if _, err := Hashes(bg, pool, u, "warm", 0, 10); err == nil {
		t.Fatal("Hashes accepted a stream that is not hot")
	}
	if _, err := StreamMaxSeq(bg, pool, u, "warm"); err == nil {
		t.Fatal("StreamMaxSeq accepted a stream that is not hot")
	}
	if _, err := Read(bg, pool, u, "cold", 0, 10, 1<<20); err == nil {
		t.Fatal("Read accepted ledgerd's retired cold stream")
	}
}

func TestHashesCoverEveryRowAndLinkAsAChain(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	seedInterleaved(t, pool, u, 6)

	rows, err := Read(bg, pool, u, blob.StreamHot, 0, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	hashes, err := Hashes(bg, pool, u, blob.StreamHot, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(hashes) != len(rows) {
		t.Fatalf("%d hashes for %d rows", len(hashes), len(rows))
	}
	prev := map[string][32]byte{"ios-00000000-0000-4000-8000-00000000000a": blob.ZeroHash, "ios-00000000-0000-4000-8000-00000000000b": blob.ZeroHash}
	for i, h := range hashes {
		if h.Seq != rows[i].Seq || h.WriterID != rows[i].WriterID || h.WriterCounter != rows[i].WriterCounter {
			t.Fatalf("hash %d describes a different row than the log does", i)
		}
		if !bytes.Equal(h.BlobHash, rows[i].BlobHash) {
			t.Fatalf("hash %d is %x, but the row stores %x", i, h.BlobHash, rows[i].BlobHash)
		}
		// The link check a client can run WITHOUT downloading a single body:
		// within each writer, every entry's prev_hash is the previous entry's
		// blob_hash, and the first is the genesis hash.
		p := prev[h.WriterID]
		if !bytes.Equal(h.PrevHash, p[:]) {
			t.Fatalf("hash %d links to %x, but %s's list is at %x", i, h.PrevHash, h.WriterID, p)
		}
		prev[h.WriterID] = [32]byte(h.BlobHash)
	}
}

func TestHashesAreScopedToTheUserAndStream(t *testing.T) {
	pool := pgtest.New(t)
	a, b := insertUser(t, pool), insertUser(t, pool)
	seedInterleaved(t, pool, a, 4)
	seedInterleaved(t, pool, b, 4)

	hashes, err := Hashes(bg, pool, a, blob.StreamHot, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(hashes) != 8 {
		t.Fatalf("got %d hashes for user a, want 8", len(hashes))
	}
	// seq is per user, so both users own a seq 1: identity has to be tested on
	// the blob hashes, which differ because the AAD binds the user id.
	rows, err := Read(bg, pool, b, blob.StreamHot, 0, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hashes {
		if h.Stream != blob.StreamHot {
			t.Fatalf("a hot hash list contains a %q row", h.Stream)
		}
		for _, r := range rows {
			if bytes.Equal(h.BlobHash, r.BlobHash) {
				t.Fatalf("user a's hash list contains %x, which is user b's blob", h.BlobHash)
			}
		}
	}
}

func TestStreamMaxSeqIsPerUser(t *testing.T) {
	pool := pgtest.New(t)
	u, other := insertUser(t, pool), insertUser(t, pool)
	seedInterleaved(t, pool, u, 3)
	seedInterleaved(t, pool, other, 9)

	hot, err := StreamMaxSeq(bg, pool, u, blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	if hot != 6 {
		t.Fatalf("max seq is %d, want 6", hot)
	}
	empty := insertUser(t, pool)
	if got, err := StreamMaxSeq(bg, pool, empty, blob.StreamHot); err != nil || got != 0 {
		t.Fatalf("StreamMaxSeq on an empty log = (%d, %v), want (0, nil)", got, err)
	}
}

func TestPartiallyAppliedBatchIsNamedSoTheAPICanTellTheClientWhatToDo(t *testing.T) {
	// The client contract: "read the chain head and resend only the rows above
	// it". The HTTP layer has to recognise this case to say that, and it must
	// not be reported as a chain break (spec §3.3:68 hard stop).
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[:2], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[:2])); err != nil {
		t.Fatal(err)
	}
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[1:], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[1:]))
	if !errors.Is(err, ErrPartiallyApplied) {
		t.Fatalf("a straddling resend returned %v, want ErrPartiallyApplied", err)
	}
	if errors.Is(err, ErrChainBreak) {
		t.Fatalf("a partial resend must not be reported as a chain break: %v", err)
	}
}
