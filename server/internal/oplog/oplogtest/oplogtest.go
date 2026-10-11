// Package oplogtest builds op-log fixtures for tests: an account, a device
// writer, and sealed frame v3 rows appended through the real appender. TEST
// ONLY: it seals with internal/blob/blobtest, which cmd/hasalad's build graph
// must never reach (spec 02 §4.4 fences 1 and 3).
package oplogtest

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/oplog"
)

var bg = context.Background()

// NewUser creates an account row and its oplog_seq row in one transaction, as
// account creation does.
func NewUser(t testing.TB, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(bg) }()
	sub := make([]byte, 32)
	if _, err := rand.Read(sub); err != nil {
		t.Fatal(err)
	}
	var id uuid.UUID
	if err := tx.QueryRow(bg,
		`INSERT INTO users (idp, idp_sub_hash, created_at) VALUES ('passkey', $1, now()) RETURNING id`,
		sub).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if err := oplog.EnsureSeqRow(bg, tx, id); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	return id
}

// NewWriter enrols a live device writer for the account with a fresh Ed25519
// key, directly in the roster (the registration ceremony is auth's to test),
// and returns the private key.
func NewWriter(t testing.TB, pool *pgxpool.Pool, userID uuid.UUID, writerID string) ed25519.PrivateKey {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg,
		`INSERT INTO writers (user_id, writer_id, kind, pubkey, registered_at) VALUES ($1, $2, 'device', $3, now())`,
		userID, writerID, []byte(pub)); err != nil {
		t.Fatalf("oplogtest: enrol writer %s: %v", writerID, err)
	}
	return priv
}

// Rows builds n consecutive sealed rows for one writer, starting after
// (counter, prev): counters counter+1 … counter+n, each chained to the one
// before, each a frame v3 sealed under blobtest.TestEpochKey at epoch 1.
func Rows(t testing.TB, userID uuid.UUID, writerID string, counter int64, prev [32]byte, n int) []oplog.Row {
	t.Helper()
	out := make([]oplog.Row, 0, n)
	for i := 0; i < n; i++ {
		c := counter + int64(i) + 1
		env := blob.Envelope{UserID: userID, Stream: blob.StreamHot, WriterID: writerID, WriterCounter: c}
		s, err := blobtest.Seal3(env, 1, blobtest.TestEpochKey, prev,
			[]byte(fmt.Sprintf(`{"v":4,"kind":"ops","ops":[{"n":%d}]}`, c)))
		if err != nil {
			t.Fatalf("oplogtest: seal counter %d: %v", c, err)
		}
		h := blob.Hash(prev, s)
		out = append(out, oplog.Row{
			UserID: userID, Stream: blob.StreamHot, WriterID: writerID, WriterCounter: c,
			TypeFlag: oplog.TypeFlagEdit, Blob: s.Bytes, SizeBucket: s.SizeBucket,
			BlobHash: append([]byte(nil), h[:]...), PrevHash: append([]byte(nil), prev[:]...),
		})
		prev = h
	}
	return out
}

// Append appends n sealed rows to the writer's chain through the real
// appender, continuing from its committed head, and returns their seqs.
func Append(t testing.TB, pool *pgxpool.Pool, userID uuid.UUID, writerID string, n int) []int64 {
	t.Helper()
	ap := &oplog.Appender{Pool: pool}
	counter, head, err := ap.Head(bg, userID, writerID, blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	seqs, err := ap.AppendClient(bg, userID, writerID, blob.StreamHot, Rows(t, userID, writerID, counter, head, n))
	if err != nil {
		t.Fatalf("oplogtest: append %d rows for %s: %v", n, writerID, err)
	}
	return seqs
}

// Opaque returns n bytes of pseudo-random filler that passes LooksSealed's
// zero checks wherever it lands, for tests that need a frame-shaped value
// without a key.
func Opaque(n int) []byte {
	out := make([]byte, 0, n)
	seed := sha256.Sum256([]byte("oplogtest"))
	for len(out) < n {
		seed = sha256.Sum256(seed[:])
		out = append(out, seed[:]...)
	}
	return out[:n]
}
