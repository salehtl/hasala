package oplog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// sealBody is sealRow with a caller-chosen payload, so a test can put TWO
// DIFFERENT blobs at the same chain position — which is the only way to tell a
// benign replay of an already-applied batch apart from a genuine fork.
func sealBody(t *testing.T, u uuid.UUID, writerID, stream string, counter int64, prev [32]byte, body string) (Row, [32]byte) {
	t.Helper()
	env := blob.Envelope{UserID: u, Stream: stream, WriterID: writerID, WriterCounter: counter}
	s, err := blobtest.Seal3(env, 1, blobtest.TestEpochKey, prev, []byte(body))
	if err != nil {
		t.Fatal(err)
	}
	h := blob.Hash(prev, s)
	flag := TypeFlagEdit
	return Row{
		UserID:        u,
		Stream:        stream,
		WriterID:      writerID,
		WriterCounter: counter,
		TypeFlag:      flag,
		Blob:          s.Bytes,
		SizeBucket:    s.SizeBucket,
		BlobHash:      h[:],
		PrevHash:      prev[:],
	}, h
}

// chainFrom builds n rows continuing a (writer, stream) chain from
// (startCounter-1, prev), each sealed at its own position and linked to the one
// before it. It returns the rows and the new head hash.
func chainFrom(t *testing.T, u uuid.UUID, writerID, stream string, startCounter int64, prev [32]byte, n int) ([]Row, [32]byte) {
	t.Helper()
	out := make([]Row, 0, n)
	for i := 0; i < n; i++ {
		c := startCounter + int64(i)
		r, h := sealBody(t, u, writerID, stream, c, prev, fmt.Sprintf(`{"w":%q,"s":%q,"c":%d}`, writerID, stream, c))
		prev = h
		out = append(out, r)
	}
	return out, prev
}

// warmPool forces n connections to be established before a concurrency test
// starts. pgxpool opens lazily, so without this the "racers" stagger by however
// long a fresh connection takes and a test can pass under a broken
// implementation simply because nothing ever actually overlapped.
func warmPool(t *testing.T, pool *pgxpool.Pool, n int) {
	t.Helper()
	conns := make([]*pgxpool.Conn, 0, n)
	for i := 0; i < n; i++ {
		c, err := pool.Acquire(bg)
		if err != nil {
			t.Fatalf("warm pool: %v", err)
		}
		if err := c.Ping(bg); err != nil {
			t.Fatalf("warm pool ping: %v", err)
		}
		conns = append(conns, c)
	}
	for _, c := range conns {
		c.Release()
	}
}

// assertChainBreak insists on ErrChainBreak specifically — and, just as
// importantly, insists the error is NOT a raw unique-violation leaking out of
// the database. "Some error happened" is not the property under test: a
// constraint violation reaching the caller means the ordering rule in appendTx
// was not honoured, and it is the wrong thing to hand a client (spec §3.3:68
// makes a chain break a sync hard stop, which a duplicate-key error is not).
func assertChainBreak(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("want ErrChainBreak, got nil")
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		t.Fatalf("the database rejected this, not the chain check: %v", err)
	}
	if !errors.Is(err, ErrChainBreak) {
		t.Fatalf("want ErrChainBreak, got %T: %v", err, err)
	}
}

func countersOf(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, stream string) []int64 {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT writer_counter FROM op_log WHERE user_id=$1 AND writer_id=$2 AND stream=$3 ORDER BY seq`,
		u, writerID, stream)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []int64
	for rows.Next() {
		var c int64
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		got = append(got, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return got
}

// storedChain reads back one (writer, stream) chain in counter order.
func storedChain(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, stream string) []Row {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT seq, stream, writer_id, writer_counter, blob, size_bucket, blob_hash, prev_hash
		   FROM op_log WHERE user_id=$1 AND writer_id=$2 AND stream=$3 ORDER BY writer_counter`,
		u, writerID, stream)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		r := Row{UserID: u}
		if err := rows.Scan(&r.Seq, &r.Stream, &r.WriterID, &r.WriterCounter,
			&r.Blob, &r.SizeBucket, &r.BlobHash, &r.PrevHash); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// ---------------------------------------------------------------------------
// The chain rule itself. These need no database: they are the property a CLIENT
// checks over rows it pulled, which is where "the server dropped or reordered
// my ops" is actually detected (spec §3.3(a)).
// ---------------------------------------------------------------------------

// TestChainRuleIsPinnedByAGoldenVector freezes the formula the TypeScript port
// must reproduce byte for byte: blob_hash[n] = SHA256(blob_hash[n-1] ‖ bytes[n]),
// starting from 32 zero bytes. A change here is a data migration, not a code
// change, so it is pinned against constants rather than against a
// reimplementation of itself.
func TestChainRuleIsPinnedByAGoldenVector(t *testing.T) {
	first := blob.Hash(blob.ZeroHash, blob.Sealed{Bytes: bytesOf(0xab, 1024), SizeBucket: 1024})
	const wantFirst = "b972e78fb27a0866f41fd72ab4687e18aed94a66c8e32314ac654e8247c3e3d3"
	if got := hex.EncodeToString(first[:]); got != wantFirst {
		t.Fatalf("chain hash 1 = %s, want %s", got, wantFirst)
	}
	second := blob.Hash(first, blob.Sealed{Bytes: bytesOf(0xcd, 1024), SizeBucket: 1024})
	const wantSecond = "1eb123521be8de11640db812996ae32d973f6ed53d3eff1f3e080fa377761eb4"
	if got := hex.EncodeToString(second[:]); got != wantSecond {
		t.Fatalf("chain hash 2 = %s, want %s", got, wantSecond)
	}
	// And the genesis really is 32 zero bytes, not "no bytes at all".
	if blob.ZeroHash != ([32]byte{}) {
		t.Fatal("ZeroHash is not 32 zero bytes")
	}
	direct := sha256.Sum256(append(make([]byte, 32), bytesOf(0xab, 1024)...))
	if direct != first {
		t.Fatal("blob.Hash is not SHA256(prev || bytes)")
	}
}

func bytesOf(b byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestVerifyChainAcceptsAContiguousRun(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 5)
	if err := VerifyChain(rows, 0, blob.ZeroHash); err != nil {
		t.Fatalf("a well-formed chain must verify: %v", err)
	}
	// And a suffix verifies against the head it continues from.
	var prev [32]byte
	copy(prev[:], rows[1].BlobHash)
	if err := VerifyChain(rows[2:], 2, prev); err != nil {
		t.Fatalf("a suffix must verify against its own head: %v", err)
	}
}

// The first blob of a chain links to 32 zero bytes and nothing else. Without
// this, a writer could start its chain anywhere and a client verifying from
// genesis would have nothing to anchor against.
func TestFirstBlobOfAChainLinksToZeroHash(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if err := VerifyChain(rows, 0, blob.ZeroHash); err != nil {
		t.Fatalf("counter 1 chained from ZeroHash must verify: %v", err)
	}
	var junk [32]byte
	junk[0] = 1
	forged, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, junk, 1)
	if err := VerifyChain(forged, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("counter 1 with a non-zero prev must break: %v", err)
	}
}

// THE integrity property, part 1: an op the server never delivered is detected.
func TestVerifyChainDetectsADroppedOp(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 5)
	dropped := append(append([]Row{}, rows[:2]...), rows[3:]...) // 1,2,4,5
	if err := VerifyChain(dropped, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a dropped op must break the chain, got %v", err)
	}
}

// THE integrity property, part 2: ops served out of order are detected.
func TestVerifyChainDetectsAReorderedOp(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 5)
	swapped := append([]Row{}, rows...)
	swapped[2], swapped[3] = swapped[3], swapped[2]
	if err := VerifyChain(swapped, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a reordered op must break the chain, got %v", err)
	}
}

// THE integrity property, part 3: substituted bytes are detected even when the
// counters and links are all internally consistent, because the hash is
// recomputed from the stored bytes rather than trusted.
func TestVerifyChainDetectsATamperedBlob(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[1].Blob = append([]byte(nil), rows[1].Blob...)
	rows[1].Blob[600] ^= 0xff
	if err := VerifyChain(rows, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a tampered blob must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsAForgedPrevHash(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[2].PrevHash = bytesOf(0x11, 32)
	if err := VerifyChain(rows, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a forged prev_hash must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsAChainThatDoesNotContinueTheHead(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 4, blob.ZeroHash, 2)
	if err := VerifyChain(rows, 2, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("counter 4 after head 2 must break, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// Head
// ---------------------------------------------------------------------------

func TestHeadOfAnUnusedChainIsZero(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	c, h, err := a.Head(bg, u, "dev-a", blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	if c != 0 || h != blob.ZeroHash {
		t.Fatalf("Head = (%d, %x), want (0, zero)", c, h)
	}
}

func TestHeadAdvancesWithEveryAppend(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	rows, want := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows); err != nil {
		t.Fatal(err)
	}
	c, h, err := a.Head(bg, u, "dev-a", blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	if c != 3 || h != want {
		t.Fatalf("Head = (%d, %x), want (3, %x)", c, h, want)
	}
	// Another writer's chain is untouched by this one.
	if c, _, err := a.Head(bg, u, "dev-b", blob.StreamHot); err != nil || c != 0 {
		t.Fatalf("dev-b head = (%d, %v), want (0, nil)", c, err)
	}
}

// ---------------------------------------------------------------------------
// AppendClient: the chain is verified at append time
// ---------------------------------------------------------------------------

func TestClientAppendRejectsCounterGap(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, head := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 2)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows); err != nil {
		t.Fatal(err)
	}
	gapped, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 4, head, 1)
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, gapped)
	assertChainBreak(t, err)

	assertGapFree(t, pool, u, 2)
	if got := nextSeqOf(t, pool, u); got != 3 {
		t.Fatalf("next_seq = %d after a rejected append, want 3", got)
	}
}

func TestClientAppendRejectsForgedPrevHash(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows); err != nil {
		t.Fatal(err)
	}
	var forged [32]byte
	forged[3] = 0x99
	next, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 2, forged, 1)
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, next)
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 1)
}

func TestClientAppendRejectsRecomputedHashMismatch(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	// The row claims a hash that is not SHA256(prev || blob). A server that
	// stored the caller's word for it would let a writer make its own chain
	// unverifiable from the stored bytes.
	rows[0].BlobHash = bytesOf(0x42, 32)
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows)
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1 — a rejected append burned a seq", got)
	}
}

func TestChainBreakRollsBackTheWholeBatch(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[2].PrevHash = bytesOf(0x7e, 32) // the third row breaks the run
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows)
	assertChainBreak(t, err)

	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1 — the rejected batch burned seqs", got)
	}
}

func TestClientAppendRejectsRowsThatDisagreeWithTheCall(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "dev-b", blob.StreamHot, rows); err == nil {
		t.Fatal("a row naming another writer must be rejected, not silently rewritten")
	}
	if _, err := a.AppendClient(bg, uuid.New(), "dev-a", blob.StreamHot, rows); err == nil {
		t.Fatal("a row naming another user must be rejected")
	}
	// The row-versus-call STREAM disagreement is not asserted here: there are
	// only two streams, so it can only be tested against cold, which
	// TestClientAppendRejectsTheColdStream now refuses one check earlier.
	assertGapFree(t, pool, u, 0)
}

// ---------------------------------------------------------------------------
// The ambiguous-commit contract (append.go's "an error does not always mean
// 'not appended'"): a naive retry of a batch that in fact committed must be
// answered with its seqs, not with an error that loops forever.
// ---------------------------------------------------------------------------

func TestResendingACommittedBatchReturnsItsSeqsInsteadOfFailing(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	first, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows)
	if err != nil {
		t.Fatal(err)
	}
	// The client never saw the response (deadline expired during Commit) and
	// sends the identical batch again.
	again, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows)
	if err != nil {
		t.Fatalf("a resend of an already-applied batch must not fail: %v", err)
	}
	if !reflect.DeepEqual(first, again) {
		t.Fatalf("resend returned %v, want the original %v", again, first)
	}
	assertGapFree(t, pool, u, 3)
	if got := nextSeqOf(t, pool, u); got != 4 {
		t.Fatalf("next_seq = %d, want 4 — the resend burned a seq", got)
	}
	// An older, fully-applied prefix is answered the same way.
	prefix, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows[:2])
	if err != nil {
		t.Fatalf("a resend of an applied prefix must not fail: %v", err)
	}
	if !reflect.DeepEqual(prefix, first[:2]) {
		t.Fatalf("prefix resend returned %v, want %v", prefix, first[:2])
	}
}

func TestResendingDifferentBytesAtAnAppliedCounterIsAChainBreak(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows); err != nil {
		t.Fatal(err)
	}
	other, _ := sealBody(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, `{"forked":true}`)
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, []Row{other})
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 1)
}

func TestAPartiallyAppliedResendIsRejectedWithoutClaimingAChainBreak(t *testing.T) {
	// Counters 1..2 are applied; the client resends 2..3. This is a protocol
	// mistake, not evidence the server lost anything, so it must NOT be
	// ErrChainBreak — spec §3.3:68 makes that a sync hard stop with a
	// non-dismissable warning.
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows[:2]); err != nil {
		t.Fatal(err)
	}
	_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows[1:])
	if err == nil {
		t.Fatal("a partially-applied batch must be rejected")
	}
	if errors.Is(err, ErrChainBreak) {
		t.Fatalf("a partial resend must not be reported as a chain break: %v", err)
	}
	assertGapFree(t, pool, u, 2)
	// Resubmitting only the new row works.
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, rows[2:]); err != nil {
		t.Fatalf("the suffix must be appendable: %v", err)
	}
	assertGapFree(t, pool, u, 3)
}

// ---------------------------------------------------------------------------
// The ORDERING RULE: allocSeq (the counter lock) FIRST, then the head read.
// ---------------------------------------------------------------------------

// TestTheChainCheckRunsAfterTheCounterLockIsTaken is the ORDERING RULE, pinned
// directly and without any timing: it drives appendTx with a prepare hook that
// reads the user's counter row on the append's OWN transaction. allocSeq is the
// statement that takes that row's lock, so "has next_seq already advanced by
// len(rows) when the chain check runs?" is exactly "was the lock taken first?".
//
// Swap the two statements in appendTx and this fails deterministically, on one
// connection, with no concurrency. The CONSEQUENCE of getting it wrong — a
// second upload from the same writer colliding in the unique index instead of
// being answered with ErrChainBreak — is pinned separately by
// TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak.
func TestTheChainCheckRunsAfterTheCounterLockIsTaken(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 3)
	var seen int64
	prepare := func(ctx context.Context, tx pgx.Tx, rows []Row) error {
		return tx.QueryRow(ctx, `SELECT next_seq FROM oplog_seq WHERE user_id=$1`, u).Scan(&seen)
	}
	if _, err := a.appendRows(bg, rows, prepare); err != nil {
		t.Fatal(err)
	}
	if want := int64(1 + len(rows)); seen != want {
		t.Fatalf("the chain check saw next_seq=%d, want %d: allocSeq has NOT taken the counter lock "+
			"before the chain head is read, so two concurrent uploads from one writer can both "+
			"observe the same head and race for the same counter", seen, want)
	}
}

// TestAnAppendQueuedBehindAnotherSeesTheCommittedHead: an append that arrives
// while another transaction holds the counter is answered against the head that
// transaction commits, never against the stale one it saw on arrival. Here the
// queued append submits DIFFERENT bytes at the counter the winner takes, so the
// only correct answer is ErrChainBreak.
//
// (The statement it actually blocks on is EnsureSeqRow's
// `INSERT ... ON CONFLICT DO NOTHING`, not allocSeq: an insert whose conflicting
// row is being updated by an in-flight transaction has to wait to learn whether
// that update commits. That is why this test is a companion to the ordering pin
// above rather than the pin itself — the external interleaving it can create is
// the same under both orderings.)
func TestAnAppendQueuedBehindAnotherSeesTheCommittedHead(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	first, h1 := chainFrom(t, u, "dev-a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, first); err != nil {
		t.Fatal(err)
	}

	// The winner: holds the counter lock, has written counter 2, not committed.
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	winner, _ := sealBody(t, u, "dev-a", blob.StreamHot, 2, h1, `{"winner":true}`)
	if _, err := a.appendTx(bg, tx, u, []Row{winner}, nil); err != nil {
		t.Fatal(err)
	}

	// The racer: a DIFFERENT blob at counter 2, submitted while the winner
	// still holds the lock.
	racer, _ := sealBody(t, u, "dev-a", blob.StreamHot, 2, h1, `{"racer":true}`)
	done := make(chan error, 1)
	go func() {
		_, err := a.AppendClient(bg, u, "dev-a", blob.StreamHot, []Row{racer})
		done <- err
	}()

	waitForLockWaiter(t, pool)
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}

	select {
	case err := <-done:
		assertChainBreak(t, err)
	case <-time.After(30 * time.Second):
		t.Fatal("the racing append never returned")
	}
	assertGapFree(t, pool, u, 2)
	if got := countersOf(t, pool, u, "dev-a", blob.StreamHot); !reflect.DeepEqual(got, []int64{1, 2}) {
		t.Fatalf("counters = %v, want [1 2]", got)
	}
}

// waitForLockWaiter blocks until some backend on this database is waiting on a
// lock, which is how the test knows the racer has reached the counter — under
// either ordering. Polling this instead of sleeping keeps the test both fast
// and free of a timing assumption that would silently stop testing anything.
func waitForLockWaiter(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := pool.QueryRow(bg,
			`SELECT count(*) FROM pg_stat_activity
			  WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("no backend ever blocked on the counter lock; the test premise does not hold")
}

// TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak is the realistic
// shape of the same rule: two uploads from one device, in flight at once, both
// claiming the next counter. Exactly one must win and the loser must get
// ErrChainBreak — never a duplicate-key error.
func TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	const rounds = 25
	counter, head := int64(0), blob.ZeroHash
	for round := 0; round < rounds; round++ {
		bodies := [2]string{fmt.Sprintf(`{"a":%d}`, round), fmt.Sprintf(`{"b":%d}`, round)}
		var racers [2][]Row
		for i, body := range bodies {
			r, _ := sealBody(t, u, "dev-a", blob.StreamHot, counter+1, head, body)
			racers[i] = []Row{r}
		}
		var (
			wg    sync.WaitGroup
			start = make(chan struct{})
			errs  [2]error
		)
		for i := range racers {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				_, errs[i] = a.AppendClient(bg, u, "dev-a", blob.StreamHot, racers[i])
			}(i)
		}
		close(start)
		wg.Wait()

		wins := 0
		for i, err := range errs {
			if err == nil {
				wins++
				continue
			}
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
				t.Fatalf("round %d racer %d: the database rejected the append instead of the chain check: %v", round, i, err)
			}
			if !errors.Is(err, ErrChainBreak) {
				t.Fatalf("round %d racer %d: want ErrChainBreak, got %T: %v", round, i, err, err)
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d of 2 racers won, want exactly 1 (errs: %v)", round, wins, errs)
		}
		var err error
		if counter, head, err = a.Head(bg, u, "dev-a", blob.StreamHot); err != nil {
			t.Fatal(err)
		}
		if counter != int64(round+1) {
			t.Fatalf("round %d: head counter = %d, want %d", round, counter, round+1)
		}
	}
	assertGapFree(t, pool, u, rounds)
}
