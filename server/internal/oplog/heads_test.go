package oplog

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// Signed heads (spec 01 §7.1, R-02) and the epoch rule (§8.3) on the append
// path, and the batch-aligned pull (spec 02 §11.3).

const headWriter = "ios-00000000-0000-4000-8000-00000000000a"

func TestABatchNeedsItsWritersHeadSignature(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)
	rows := rowsFor(t, u, headWriter, blob.StreamHot, 1, 3)
	last := rows[2]
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32))
	m, _ := keyproto.HeadMessage(u, 3, last.BlobHash, headWriter)
	first, _ := keyproto.HeadMessage(u, 1, rows[0].BlobHash, headWriter)
	otherUser, _ := keyproto.HeadMessage(uuid.New(), 3, last.BlobHash, headWriter)
	for name, sig := range map[string][]byte{
		"no signature":          nil,
		"64 zero bytes":         make([]byte, 64),
		"another writer's key":  ed25519.Sign(other, m),
		"over the first row":    ed25519.Sign(testDWK(headWriter), first),
		"over another user":     ed25519.Sign(testDWK(headWriter), otherUser),
		"another writer's head": testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000b", rows),
	} {
		if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, rows, sig); !errors.Is(err, ErrHeadSignature) {
			t.Errorf("%s: %v, want ErrHeadSignature", name, err)
		}
	}
	if got := seqsOf(t, pool, u); len(got) != 0 {
		t.Fatalf("a refused batch stored %d rows", len(got))
	}
	seqs, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, rows, testHeadSig(u, headWriter, rows))
	if err != nil {
		t.Fatal(err)
	}
	// Stored on the last row only.
	var signed, unsigned int
	if err := pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE head_sig IS NOT NULL), count(*) FILTER (WHERE head_sig IS NULL)
		FROM op_log WHERE user_id = $1`, u).Scan(&signed, &unsigned); err != nil {
		t.Fatal(err)
	}
	if signed != 1 || unsigned != 2 {
		t.Fatalf("%d signed and %d unsigned rows, want 1 and 2", signed, unsigned)
	}
	// A byte-identical replay returns the original seqs without re-verifying
	// the head (spec 01 §8.3): a client whose response was lost resends it.
	again, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, rows, nil)
	if err != nil || len(again) != 3 || again[0] != seqs[0] {
		t.Fatalf("replay: %v, %v; want %v", again, err, seqs)
	}
}

func TestOnlyALiveEnrolledWriterOfAKeyedAccountAppends(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)

	stranger := "ios-00000000-0000-4000-8000-0000000000ee"
	rows := rowsFor(t, u, stranger, blob.StreamHot, 1, 1)
	if _, err := a.AppendClient(bg, u, stranger, blob.StreamHot, rows, testHeadSig(u, stranger, rows)); !errors.Is(err, ErrUnknownWriter) {
		t.Fatalf("an unenrolled writer: %v", err)
	}
	if _, err := pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`, u, headWriter); err != nil {
		t.Fatal(err)
	}
	rows = rowsFor(t, u, headWriter, blob.StreamHot, 1, 1)
	if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, rows, testHeadSig(u, headWriter, rows)); !errors.Is(err, ErrWriterRevoked) {
		t.Fatalf("a revoked writer: %v", err)
	}
	b := insertUser(t, pool)
	if _, err := pool.Exec(bg, `DELETE FROM account_keys WHERE user_id = $1`, b); err != nil {
		t.Fatal(err)
	}
	rows = rowsFor(t, b, headWriter, blob.StreamHot, 1, 1)
	if _, err := a.AppendClient(bg, b, headWriter, blob.StreamHot, rows, testHeadSig(b, headWriter, rows)); !errors.Is(err, ErrKeysRequired) {
		t.Fatalf("an account without keys: %v", err)
	}
}

func TestAboveTheHeadEveryFrameCarriesTheCurrentEpoch(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)
	first := rowsFor(t, u, headWriter, blob.StreamHot, 1, 1)
	if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, first, testHeadSig(u, headWriter, first)); err != nil {
		t.Fatal(err)
	}
	// A frame sealed at epoch 2 while the account is at 1: 409 stale_epoch.
	prev := [32]byte(first[0].BlobHash)
	s, err := blobtest.Seal3(blob.Envelope{UserID: u, Stream: blob.StreamHot, WriterID: headWriter, WriterCounter: 2},
		2, blobtest.TestEpochKey, prev, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	h := blob.Hash(prev, s)
	r := []Row{{WriterCounter: 2, Blob: s.Bytes, SizeBucket: s.SizeBucket, BlobHash: h[:], PrevHash: prev[:]}}
	_, err = a.AppendClient(bg, u, headWriter, blob.StreamHot, r, testHeadSig(u, headWriter, r))
	var stale *StaleEpochError
	if !errors.As(err, &stale) || !errors.Is(err, ErrStaleEpoch) || stale.Current != 1 || stale.Frame != 2 {
		t.Fatalf("epoch 2 at current 1: %v", err)
	}
	// The epoch rises; a replay of the epoch-1 batch is still recognised.
	if _, err := pool.Exec(bg, `UPDATE account_keys SET current_epoch = 2 WHERE user_id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, first, nil); err != nil {
		t.Fatalf("a replay below the head was refused for its epoch: %v", err)
	}
	if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, r, testHeadSig(u, headWriter, r)); err != nil {
		t.Fatalf("epoch 2 at current 2: %v", err)
	}
}

func TestAPageNeverEndsInsideABatch(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u := insertUser(t, pool)
	rows := rowsFor(t, u, headWriter, blob.StreamHot, 1, 8)
	if _, err := a.AppendClient(bg, u, headWriter, blob.StreamHot, rows, testHeadSig(u, headWriter, rows)); err != nil {
		t.Fatal(err)
	}
	page, err := Read(bg, pool, u, blob.StreamHot, 0, 1, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(page) != 8 || page[7].HeadSig == nil || page[6].HeadSig != nil {
		t.Fatalf("a 1-row page of an 8-row batch returned %d rows", len(page))
	}
	hashes, err := Hashes(bg, pool, u, blob.StreamHot, 0, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(hashes) != 8 {
		t.Fatalf("a 3-row hash page of an 8-row batch returned %d rows", len(hashes))
	}
}
