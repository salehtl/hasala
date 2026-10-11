// Package verify is the operator's integrity instrument: `hasalad verify
// structural` and `hasalad verify usage` (spec 02 §18.3).
//
//   - [Structural] answers "is the stored log internally consistent?" — six
//     invariants over op_log that the append path cannot violate and that
//     therefore only a bug, a repair script, a restore from a damaged backup or
//     a tampering operator can produce. S1–S4 and S6 check the rows that
//     survive; S5 is the only one that can tell a truncated tail apart from a
//     healthy log, because deleted rows leave nothing behind for the others to
//     see a hole in. (S7, the signed batch heads of spec 01 §7.1, arrives with
//     WS-2.)
//   - [UsageLedger] (usage.go) answers "does the per-account usage ledger agree
//     with the stored bytes?".
//
// # This package reads no content
//
// Every blob is ciphertext the server cannot open, and nothing here tries:
// [Structural] hashes stored bytes and reads CLEARTEXT FRAMING (the v3 header:
// key epoch and AAD). Findings never echo a value taken from a blob — only the
// position the ROW claims.
package verify

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/oplog"
)

// Finding is one violated invariant. Detail is written for an operator with a
// psql session: it names the position, never a value read out of a blob.
type Finding struct {
	ID     string    `json:"id"`
	UserID uuid.UUID `json:"user_id"`
	Detail string    `json:"detail"`
}

// The invariant identifiers. S-series are structural (op_log); U-series come
// from the usage reconciliation, so that `hasalad verify` has ONE exit path
// whichever half found the problem.
const (
	// S1SeqDense: per user, count(*) == max(seq) and min(seq) == 1. The seq
	// space has no holes, ever — the counter is a locked row, not a sequence
	// (oplog_seq in the baseline).
	S1SeqDense = "S1_seq_dense"
	// S2WriterChain: per (user, writer_id, stream), counters run 1..N and
	// blob_hash[n] == SHA256(blob_hash[n-1] ‖ blob[n]) RECOMPUTED from the
	// stored bytes (spec 01 §7).
	S2WriterChain = "S2_writer_chain"
	// S3AADMatchesRow: every blob's embedded associated data equals its row's
	// (user_id, stream, writer_id, writer_counter).
	S3AADMatchesRow = "S3_aad_matches_row"
	// S4BucketValid: octet_length(blob) == size_bucket, and size_bucket is one
	// of the seven rungs of blob.Buckets.
	S4BucketValid = "S4_bucket_valid"
	// S5CounterMatchesHead: per user, oplog_seq.next_seq == max(seq)+1 exactly.
	//
	// This is the only invariant that can see mail that is GONE rather than
	// out of order. S1 asks whether the surviving rows have holes between them,
	// which a truncated TAIL does not — 1..N-1 is perfectly dense, and an
	// entirely deleted log has nothing to be dense about. Restoring from a
	// short backup produces the first and a botched repair the second, and they
	// are the most likely real loss this system will ever see.
	//
	// The counter is the witness because nothing in production deletes an op
	// row and a rolled-back append restores the counter rather than burning the
	// value, so the equality is exact rather than an approximation with slack.
	S5CounterMatchesHead = "S5_counter_matches_head"
	// S6Sealed: every stored blob passes blob.LooksSealed (spec 01 §8.1). The
	// op_log_blob_is_sealed CHECK makes this unreachable on a database whose
	// constraints are intact; a restore into a hand-made schema is exactly the
	// database this tool is pointed at.
	S6Sealed = "S6_sealed"

	// U1UsageDrift: the per-account usage ledger (account_usage) disagrees with
	// the stored bytes it claims to count. It is a U-series rather than an
	// S-series finding because it is not an invariant of the op log — the log
	// can be perfectly consistent while the number admission compares against is
	// fiction, and that is precisely the failure it exists to see. See usage.go.
	U1UsageDrift = "U1_usage_drift"
)

// Paging. A row's blob can be a megabyte, so a row count alone bounds nothing:
// the byte budget is what keeps a verify of a large account from being an OOM
// on the operator's box.
const (
	pageRows  = 512
	pageBytes = 8 << 20
)

// maxFindings caps one run. A restore from a truncated backup can break every
// chain of every user, and an instrument that answers with a million lines is
// one nobody reads; the truncation is itself reported.
const maxFindings = 2000

// Structural runs the five op_log invariants (S1-S5) over every account.
func Structural(ctx context.Context, pool *pgxpool.Pool) ([]Finding, error) {
	return StructuralFor(ctx, pool, nil)
}

// StructuralFor runs them over the named accounts, or over all of them when
// users is empty. Findings are ordered by user, then by seq, so two runs over an
// unchanged database produce byte-identical output and a diff is meaningful.
func StructuralFor(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID) ([]Finding, error) {
	if pool == nil {
		return nil, errors.New("verify: pool is nil")
	}
	targets, err := userList(ctx, pool, users)
	if err != nil {
		return nil, err
	}
	var out []Finding
	for _, u := range targets {
		f, err := structuralUser(ctx, pool, u)
		if err != nil {
			return nil, err
		}
		out = append(out, f...)
		if len(out) >= maxFindings {
			out = out[:maxFindings]
			out = append(out, Finding{
				ID:     "truncated",
				Detail: fmt.Sprintf("stopped after %d findings; fix these and re-run", maxFindings),
			})
			return out, nil
		}
	}
	return out, nil
}

func userList(ctx context.Context, pool *pgxpool.Pool, want []uuid.UUID) ([]uuid.UUID, error) {
	if len(want) > 0 {
		out := slices.Clone(want)
		slices.SortFunc(out, func(a, b uuid.UUID) int { return bytes.Compare(a[:], b[:]) })
		return out, nil
	}
	rows, err := pool.Query(ctx, `SELECT id FROM users ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("verify: list users: %w", err)
	}
	defer rows.Close()
	var out []uuid.UUID
	for rows.Next() {
		var u uuid.UUID
		if err := rows.Scan(&u); err != nil {
			return nil, fmt.Errorf("verify: list users: %w", err)
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("verify: list users: %w", err)
	}
	return out, nil
}

func structuralUser(ctx context.Context, pool *pgxpool.Pool, u uuid.UUID) ([]Finding, error) {
	var out []Finding

	// --- S1: the seq space is dense ------------------------------------------
	var n, lo, hi int64
	if err := pool.QueryRow(ctx,
		`SELECT count(*), coalesce(min(seq),0), coalesce(max(seq),0) FROM op_log WHERE user_id = $1`,
		u).Scan(&n, &lo, &hi); err != nil {
		return nil, fmt.Errorf("verify: seq density for user %s: %w", u, err)
	}
	if n > 0 && (lo != 1 || hi != n) {
		out = append(out, Finding{ID: S1SeqDense, UserID: u, Detail: fmt.Sprintf(
			"%d rows spanning seq %d..%d: a dense log has min 1 and max == count, so %d position(s) are missing",
			n, lo, hi, hi-n)})
	}

	// --- S5: the counter agrees with the head --------------------------------
	//
	// Read in ONE statement with max(seq). Two statements are two snapshots, and
	// an append committing between them reports a break on a healthy log — the
	// counter row is UPDATEd inside the append transaction, so a reader that saw
	// the old counter and the new head would see next_seq <= max(seq) and cry
	// wolf on the busiest accounts.
	var (
		nextSeq int64
		headSeq int64
		haveSeq bool
	)
	err := pool.QueryRow(ctx, `
		SELECT s.next_seq, coalesce(max(o.seq), 0)
		  FROM oplog_seq s LEFT JOIN op_log o ON o.user_id = s.user_id
		 WHERE s.user_id = $1
		 GROUP BY s.next_seq`, u).Scan(&nextSeq, &headSeq)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		// No counter row. Harmless for an account that has never written an op
		// (account creation makes it); a hole in the evidence for one that has.
		if n > 0 {
			out = append(out, Finding{ID: S5CounterMatchesHead, UserID: u, Detail: fmt.Sprintf(
				"%d op rows exist but this account has no oplog_seq row, so there is nothing "+
					"left that knows how many ops it should have", n)})
		}
	case err != nil:
		return nil, fmt.Errorf("verify: seq counter for user %s: %w", u, err)
	default:
		haveSeq = true
	}
	if haveSeq && nextSeq != headSeq+1 {
		out = append(out, Finding{ID: S5CounterMatchesHead, UserID: u, Detail: fmt.Sprintf(
			"oplog_seq.next_seq is %d and the highest stored seq is %d: %d op(s) were assigned "+
				"a position and are no longer stored", nextSeq, headSeq, nextSeq-1-headSeq)})
	}

	// --- S2/S3/S4: one pass per stream, in seq order -------------------------
	//
	// Reading a STREAM in seq order yields each (writer, stream) chain in
	// counter order, because seq order is commit order and a chain's counters
	// only ever increase. That is what lets one pass verify every chain on the
	// stream at once without holding the log in memory.
	for _, stream := range []string{blob.StreamHot} {
		f, err := structuralStream(ctx, pool, u, stream)
		if err != nil {
			return nil, err
		}
		out = append(out, f...)
	}
	return out, nil
}

// chain is one (writer_id, stream) hash chain, mid-verification.
type chain struct {
	wantCounter int64
	prev        [32]byte
}

func structuralStream(ctx context.Context, pool *pgxpool.Pool, u uuid.UUID, stream string) ([]Finding, error) {
	var (
		out    []Finding
		chains = map[string]*chain{}
		after  int64
	)
	for {
		rows, err := oplog.Read(ctx, pool, u, stream, after, pageRows, pageBytes)
		if err != nil {
			return nil, fmt.Errorf("verify: read %s log for user %s: %w", stream, u, err)
		}
		if len(rows) == 0 {
			return out, nil
		}
		for _, r := range rows {
			after = r.Seq
			out = append(out, checkBucket(u, r)...)
			out = append(out, checkSealed(u, r)...)
			out = append(out, checkAAD(u, r)...)

			c, ok := chains[r.WriterID]
			if !ok {
				c = &chain{wantCounter: 1, prev: blob.ZeroHash}
				chains[r.WriterID] = c
			}
			out = append(out, checkChain(u, r, c)...)
		}
		if len(out) > maxFindings {
			return out, nil
		}
	}
}

func checkBucket(u uuid.UUID, r oplog.Row) []Finding {
	var out []Finding
	if len(r.Blob) != r.SizeBucket {
		out = append(out, Finding{ID: S4BucketValid, UserID: u, Detail: fmt.Sprintf(
			"seq %d: blob is %d bytes but size_bucket says %d", r.Seq, len(r.Blob), r.SizeBucket)})
	}
	if !slices.Contains(blob.Buckets, r.SizeBucket) {
		out = append(out, Finding{ID: S4BucketValid, UserID: u, Detail: fmt.Sprintf(
			"seq %d: size_bucket %d is not one of the seven rungs %v", r.Seq, r.SizeBucket, blob.Buckets)})
	}
	return out
}

// checkSealed runs the plaintext predicate over the stored bytes. It names the
// check that failed, which is a fact about framing, never a value.
func checkSealed(u uuid.UUID, r oplog.Row) []Finding {
	var re *blob.RefusalError
	if err := blob.LooksSealed(r.Blob); errors.As(err, &re) {
		return []Finding{{ID: S6Sealed, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob does not look sealed (check %s failed)", r.Seq, re.Check)}}
	}
	return nil
}

// checkAAD compares the blob's cleartext framing against the position the ROW
// claims. It never reports what it found: on a malformed blob the "embedded
// AAD" is arbitrary bytes lifted out of somebody's mail, and this package does
// not put those in an operator log.
func checkAAD(u uuid.UUID, r oplog.Row) []Finding {
	want := blob.Envelope{
		UserID: u, Stream: r.Stream, WriterID: r.WriterID, WriterCounter: r.WriterCounter,
	}
	got, err := blob.EmbeddedAAD(r.Blob)
	if err != nil {
		return []Finding{{ID: S3AADMatchesRow, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob's framing is unreadable, so it carries no position at all", r.Seq)}}
	}
	if !bytes.Equal(got, want.AAD()) {
		return []Finding{{ID: S3AADMatchesRow, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob was sealed for a different position than the row it occupies "+
				"(row says stream %q, writer %q, counter %d)", r.Seq, r.Stream, r.WriterID, r.WriterCounter)}}
	}
	return nil
}

// checkChain advances one chain by one row, reporting at most one finding and
// then RESYNCHRONIZING from the stored values. Without the resync a single
// tampered blob reports a break on every row after it, and the operator cannot
// tell one edit from a wholesale rewrite — which is the difference between a
// restore and an investigation.
func checkChain(u uuid.UUID, r oplog.Row, c *chain) []Finding {
	var out []Finding
	switch {
	case r.WriterCounter != c.wantCounter:
		out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
			"seq %d: writer %q on the %s stream is at counter %d, but the chain expected %d",
			r.Seq, r.WriterID, r.Stream, r.WriterCounter, c.wantCounter)})
	case !bytes.Equal(r.PrevHash, c.prev[:]):
		out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
			"seq %d: writer %q counter %d links to a prev_hash that is not the chain's head",
			r.Seq, r.WriterID, r.WriterCounter)})
	default:
		// The check that matters: RECOMPUTED from the stored bytes, so an
		// operator who edits a blob cannot keep the chain intact by also editing
		// the hash column.
		got := blob.Hash(c.prev, blob.Sealed{Bytes: r.Blob, SizeBucket: r.SizeBucket})
		if !bytes.Equal(r.BlobHash, got[:]) {
			out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
				"seq %d: writer %q counter %d stores a blob_hash its own bytes do not produce",
				r.Seq, r.WriterID, r.WriterCounter)})
		}
	}
	c.wantCounter = r.WriterCounter + 1
	if len(r.BlobHash) == 32 {
		c.prev = [32]byte(r.BlobHash)
	} else {
		// op_log_hashes_are_sha256 makes this unreachable; resync to genesis
		// rather than panicking on a database that has had its constraints
		// removed, which is exactly the database this tool is pointed at.
		c.prev = blob.ZeroHash
	}
	return out
}
