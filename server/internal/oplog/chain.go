package oplog

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/salehtl/hasala/server/internal/blob"
)

// This file implements the per-writer hash chains (spec 01 §7).
//
// # The rule, frozen
//
// For each (writer_id, stream) INDEPENDENTLY (there is one stream, "hot"):
//
//	blob_hash[n] = SHA256(blob_hash[n-1] || frame[n]),  blob_hash[0] = 32 zero bytes
//
// The hash covers the STORED bytes — the sealed, padded frame — so anyone
// holding the stored blob can recompute it, including a server that cannot
// read it. [blob.Hash] is the one implementation; the golden steps in
// conformance/blob/manifest.json pin the bytes every implementation must
// produce.
//
// # What these chains prove, and what they do NOT
//
// Every row is authored by a device, over frames sealed under a key the server
// does not hold (frame v3: the AEAD binds the header and prev_hash), so a
// server that drops, reorders or splices a device's ops is detected by that
// device and by the user's other devices. Linkage alone does not prove
// truncation or a fully re-chained history; those need a pinned head — the
// device's persisted head and the signed batch heads of spec 01 §7.1 (WS-2).
//
// Row.validate binds every blob to the position it is stored at, because the
// AAD is cleartext framing (blob.EmbeddedAAD), and refuses anything that does
// not look sealed (blob.LooksSealed).
//
// # Where the roster check lives (deliberately not here)
//
// A revoked or unknown writer must not be able to append. That decision needs
// auth.Writers.Roster, and auth imports this package (account creation calls
// EnsureSeqRow), so it cannot be made here without an import cycle. It belongs
// to the sync handler, which authenticates the session anyway; [Appender.AppendClient]
// therefore assumes its caller has already checked that writerID is a live
// writer of userID. The op_log_writer_fk foreign key is the database's half.

// ErrChainBreak means a writer's hash chain does not line up: a counter that
// skips, a prev_hash that does not match the row before it, or a blob_hash that
// is not SHA256(prev || bytes).
//
// It is a HARD STOP for a syncing client (spec §3.3:68) — the same class as
// oplog.ErrUnknownNewerVersion and deliberately NOT the same class as
// blob.ErrSetAside, which is a warning about one unreadable blob. Do not return
// it for anything less: a protocol mistake that costs nothing (a partially
// applied resend, say) must not raise a non-dismissable "your server may have
// tampered with your data" warning.
var ErrChainBreak = errors.New("writer hash chain break")

// The unique key that makes a (writer, stream, counter) position exclusive, and
// the SQLSTATE a collision on it raises. Named here because two code paths need
// to recognise exactly this violation and nothing else — see [isPositionTaken].
const (
	uniqueViolation    = "23505"
	positionConstraint = "op_log_position_uniq"
)

// errBatchAlreadyApplied unwinds the append transaction when the batch turns
// out to be a replay of rows that already committed. It never escapes
// AppendClient: the point is to roll back (returning the reserved seqs to the
// counter) and then answer with the seqs the rows already have.
var errBatchAlreadyApplied = errors.New("oplog: batch already applied")

// ErrPositionTaken means the database rejected a (writer, stream, counter) that
// the chain check had just approved. That combination is impossible while the
// ORDERING RULE on appendTx holds — the head is read under the counter lock, so
// a taken position is recognised as a replay before any INSERT — which is
// exactly why it is its own error and not ErrChainBreak.
//
// The distinction is load bearing in two directions. Down: ErrChainBreak is a
// client-facing sync hard stop (spec §3.3:68), and a server-side invariant
// violation must not masquerade as evidence that the operator dropped data. Up:
// if this error were folded into ErrChainBreak, reversing the two lines in
// appendTx would produce an identical error to the correct implementation and
// the ordering rule would become untestable.
var ErrPositionTaken = errors.New("oplog: chain position already held by different bytes")

// ErrPartiallyApplied means the batch STRADDLES the committed head: some of its
// rows are already stored and some are not. AppendClient refuses such a batch
// rather than trimming it (see that method's "Idempotent replay" section), and
// the remedy is the one this error states.
//
// It is deliberately NOT ErrChainBreak. A chain break is a sync hard stop with
// a non-dismissable "your server may have tampered with your data" warning
// (spec §3.3:68); a partial resend is a protocol mistake that costs nothing and
// has a trivial fix. Naming it is what lets the HTTP layer answer with that fix
// instead of an opaque 500 — the wording below is the client contract, quoted
// verbatim in the api package's doc and in the response body.
var ErrPartiallyApplied = errors.New("oplog: this batch is partly applied already: read the chain head and resend only the rows above it")

// querier is the read surface shared by *pgxpool.Pool and pgx.Tx, so the head
// read has ONE implementation whether it runs standalone or inside an append
// transaction. Two implementations would be two places for the chain rule to
// drift.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Head returns the highest committed counter of one (writer, stream) chain and
// its blob hash, or (0, blob.ZeroHash) when that chain has no rows yet — which
// is exactly the (counter, prev) a chain's first blob must be built against.
func (a *Appender) Head(ctx context.Context, userID uuid.UUID, writerID, stream string) (int64, [32]byte, error) {
	return headOf(ctx, a.Pool, userID, writerID, stream)
}

// headOf reads one chain head. Counters within a (writer, stream) are
// contiguous by construction, so the row with the largest counter IS the head;
// the UNIQUE (user_id, writer_id, stream, writer_counter) index serves this
// ordered lookup directly.
func headOf(ctx context.Context, q querier, userID uuid.UUID, writerID, stream string) (int64, [32]byte, error) {
	var (
		counter int64
		hash    []byte
	)
	err := q.QueryRow(ctx,
		`SELECT writer_counter, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = $3
		  ORDER BY writer_counter DESC LIMIT 1`, userID, writerID, stream).Scan(&counter, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, blob.ZeroHash, nil
	}
	if err != nil {
		return 0, blob.ZeroHash, fmt.Errorf("oplog: head of (%s, %s) for user %s: %w", writerID, stream, userID, err)
	}
	if len(hash) != 32 {
		return 0, blob.ZeroHash, fmt.Errorf("oplog: head of (%s, %s) for user %s: blob_hash is %d bytes", writerID, stream, userID, len(hash))
	}
	return counter, [32]byte(hash), nil
}

// VerifyChain reports whether rows are a contiguous, correctly hashed
// continuation of the chain head (fromCounter, fromHash) — use (0,
// blob.ZeroHash) to verify from genesis. Rows must be in counter order and all
// from one (writer_id, stream).
//
// This is the CLIENT's check. Every hash is RECOMPUTED from the row's stored
// bytes rather than read from the row, so a server that substitutes a blob
// cannot keep the chain intact by also editing the hash column.
//
// # Exactly what it detects, and what it cannot
//
// It detects any break RELATIVE TO (fromCounter, fromHash): an op missing from
// the middle, two ops served out of order, a substituted or edited blob, a
// forged prev_hash, a run that does not continue the head it was verified
// against, and rows from more than one (writer, stream) spliced together.
//
// It does NOT, by itself, detect a server that RE-CHAINS what it serves. A
// truncation (a genuine 1..5 served as 1..3) verifies. A whole alternative
// history, correctly chained from genesis, verifies. Both are caught only by
// comparing the head this function ends at against a head the verifier already
// trusts — which is what a persisted local head gives a returning device, what
// spec §3.3(c)'s writer_checkpoint op gives a device auditing a PEER's chain,
// and what plan invariant I11_roster_checkpoint enforces. Callers must not read
// "VerifyChain passed" as "the server served me everything"; it means "what the
// server served me is a consistent continuation of the head I gave it".
//
// Every failure wraps ErrChainBreak, including "these rows are not all from one
// writer and stream" — a caller that mixed them has a bug, but a SERVER that
// returned them has misbehaved (interleaving two writers with continuous
// counters and honestly recomputed hashes passes every other check here), and
// failing closed is the safe reading of an ambiguous input.
func VerifyChain(rows []Row, fromCounter int64, fromHash [32]byte) error {
	if len(rows) == 0 {
		return nil
	}
	writerID, stream := rows[0].WriterID, rows[0].Stream
	prev := fromHash
	want := fromCounter + 1
	for i, r := range rows {
		if r.WriterID != writerID || r.Stream != stream {
			return fmt.Errorf("%w: row %d is (%s, %s), but the chain is (%s, %s)",
				ErrChainBreak, i, r.WriterID, r.Stream, writerID, stream)
		}
		if r.WriterCounter != want {
			return fmt.Errorf("%w: (%s, %s) row %d has counter %d, want %d",
				ErrChainBreak, writerID, stream, i, r.WriterCounter, want)
		}
		if !bytes.Equal(r.PrevHash, prev[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d links to %x, but the chain is at %x",
				ErrChainBreak, writerID, stream, r.WriterCounter, r.PrevHash, prev)
		}
		got := blob.Hash(prev, blob.Sealed{Bytes: r.Blob, SizeBucket: r.SizeBucket})
		if !bytes.Equal(r.BlobHash, got[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d claims hash %x, but its bytes hash to %x",
				ErrChainBreak, writerID, stream, r.WriterCounter, r.BlobHash, got)
		}
		prev = got
		want++
	}
	return nil
}

// AppendClient appends one writer's blobs to one stream, verifying that they
// continue that (writer, stream) chain before anything is stored. The client
// authored these blobs and their hashes — the server only checks arithmetic it
// can redo from the stored bytes, which is all it is able to check without the
// key (and all it should be trusted to check).
//
// The caller must have established that writerID is a live, registered writer
// of userID; see the roster note at the top of this file.
//
// # Idempotent replay (the ambiguous-commit contract)
//
// appendRows documents that a deadline expiring during Commit returns an error
// for an append that may have committed. This is the method that makes a naive
// retry safe: a batch whose counters are at or below the committed head is a
// REPLAY, not a gap, so if every row's blob_hash matches what is already stored
// at that position the call returns those rows' original seqs and appends
// nothing. Byte-identical is the whole test — different bytes at an applied
// counter is a forked writer, which is ErrChainBreak.
//
// A batch that straddles the head (some rows applied, some not) is refused with
// a plain error rather than ErrChainBreak: the seq block is reserved for the
// whole batch before the head is known, so shrinking it mid-transaction would
// either burn a seq or unwind the counter, and neither is worth doing for a
// case the client can avoid by reading its head and resending only the rows
// above it.
func (a *Appender) AppendClient(ctx context.Context, userID uuid.UUID, writerID, stream string, rows []Row) ([]int64, error) {
	if len(rows) == 0 {
		return nil, nil
	}
	if stream != blob.StreamHot {
		// The only stream (the op_log_stream_is_hot CHECK). ledgerd's cold
		// stream carried raw mail from the server's own writer, which no
		// longer exists.
		return nil, fmt.Errorf("oplog: append client: stream %q, want %q", stream, blob.StreamHot)
	}

	// Copied, not mutated in place: a caller's slice is its own, and filling in
	// fields it left blank must not be visible to it as a side effect.
	batch := make([]Row, len(rows))
	copy(batch, rows)
	for i := range batch {
		r := &batch[i]
		// Zero means "as this call says"; a conflicting value means the caller
		// disagrees with itself, and guessing which half it meant is worse than
		// refusing.
		if r.UserID != uuid.Nil && r.UserID != userID {
			return nil, fmt.Errorf("oplog: append client: row %d names user %s, the call names %s", i, r.UserID, userID)
		}
		if r.WriterID != "" && r.WriterID != writerID {
			return nil, fmt.Errorf("oplog: append client: row %d names writer %q, the call names %q", i, r.WriterID, writerID)
		}
		if r.Stream != "" && r.Stream != stream {
			return nil, fmt.Errorf("oplog: append client: row %d names stream %q, the call names %q", i, r.Stream, stream)
		}
		r.UserID, r.WriterID, r.Stream = userID, writerID, stream
		if r.TypeFlag == "" {
			r.TypeFlag = TypeFlagEdit
		}
		if r.TypeFlag != TypeFlagEdit {
			// type_flag has one value: every row is a device's own batch
			// (ledgerd's server-authored "ingest" rows are retired).
			return nil, fmt.Errorf("oplog: append client: row %d has type_flag %q, want %q", i, r.TypeFlag, TypeFlagEdit)
		}
		if err := r.validate(); err != nil {
			return nil, fmt.Errorf("oplog: append client: row %d: %w", i, err)
		}
	}
	// Everything checkable without the database is checked before the counter
	// is touched: the links WITHIN the batch and every recomputed hash. Only
	// the join to the stored head needs the append transaction, and it is the
	// one thing that must be read under the counter lock.
	var claimedPrev [32]byte
	copy(claimedPrev[:], batch[0].PrevHash)
	if err := VerifyChain(batch, batch[0].WriterCounter-1, claimedPrev); err != nil {
		return nil, err
	}

	var replayed []int64
	prepare := func(ctx context.Context, tx pgx.Tx, rows []Row) error {
		headCounter, headHash, err := headOf(ctx, tx, userID, writerID, stream)
		if err != nil {
			return err
		}
		if rows[0].WriterCounter <= headCounter {
			seqs, err := appliedSeqs(ctx, tx, userID, writerID, stream, rows)
			if err != nil {
				return err
			}
			replayed = seqs
			return errBatchAlreadyApplied
		}
		if rows[0].WriterCounter != headCounter+1 {
			return fmt.Errorf("%w: (%s, %s) is at counter %d, this batch starts at %d",
				ErrChainBreak, writerID, stream, headCounter, rows[0].WriterCounter)
		}
		if !bytes.Equal(rows[0].PrevHash, headHash[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d links to %x, but the stored head is %x",
				ErrChainBreak, writerID, stream, rows[0].WriterCounter, rows[0].PrevHash, headHash)
		}
		return nil
	}

	seqs, err := a.appendRows(ctx, batch, prepare)
	if errors.Is(err, errBatchAlreadyApplied) {
		return replayed, nil
	}
	return a.resolveAppendErr(ctx, userID, writerID, stream, batch, seqs, err)
}

// resolveAppendErr turns the outcome of appendRows into AppendClient's answer.
//
// It is a separate function so its SQLSTATE 23505 arm can be tested. That arm
// is unreachable in a correct build — the head is read under the counter lock,
// so a taken position is recognised as a replay before any INSERT, and
// headOf returns max(writer_counter), so a position that passes the head check
// cannot already exist. It is implemented anyway because the alternative is
// handing a client a raw duplicate-key error it cannot act on (the
// ambiguous-commit contract on appendRows names this SQLSTATE explicitly), and
// because an edit that reverses the ordering rule must fail loudly rather than
// corrupt anything. Splitting it out beat the alternative of a test-only hook
// in the production path.
func (a *Appender) resolveAppendErr(ctx context.Context, userID uuid.UUID, writerID, stream string, batch []Row, seqs []int64, err error) ([]int64, error) {
	switch {
	case err == nil:
		return seqs, nil
	case isPositionTaken(err):
		applied, resolveErr := appliedSeqs(ctx, a.Pool, userID, writerID, stream, batch)
		if resolveErr != nil {
			// Deliberately NOT wrapped with %w: resolveErr may be
			// ErrChainBreak, and a client must not be hard-stopped by a
			// server-side invariant violation. See ErrPositionTaken.
			return nil, fmt.Errorf("%w: (%s, %s): %v", ErrPositionTaken, writerID, stream, resolveErr)
		}
		return applied, nil
	default:
		return nil, err
	}
}

// appliedSeqs resolves a batch that appears to have been stored already: it
// returns each row's committed seq when EVERY row is present at its position
// with byte-identical content.
//
//   - A position holding different bytes is a forked writer — two devices
//     sharing one writer id, or a device that lost state and reused counters —
//     and that is a genuine ErrChainBreak.
//   - A position that is not stored at all means the batch is only partly
//     applied. That is a protocol mistake with a trivial fix, so it is a plain
//     error: reporting it as a chain break would hard-stop the client's sync
//     over nothing (spec §3.3:68).
func appliedSeqs(ctx context.Context, q querier, userID uuid.UUID, writerID, stream string, rows []Row) ([]int64, error) {
	counters := make([]int64, len(rows))
	for i, r := range rows {
		counters[i] = r.WriterCounter
	}
	q1, err := q.Query(ctx,
		`SELECT writer_counter, seq, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = $3 AND writer_counter = ANY($4)`,
		userID, writerID, stream, counters)
	if err != nil {
		return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
	}
	defer q1.Close()
	type stored struct {
		seq  int64
		hash []byte
	}
	found := make(map[int64]stored, len(rows))
	for q1.Next() {
		var (
			counter, seq int64
			hash         []byte
		)
		if err := q1.Scan(&counter, &seq, &hash); err != nil {
			return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
		}
		found[counter] = stored{seq: seq, hash: hash}
	}
	if err := q1.Err(); err != nil {
		return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
	}

	out := make([]int64, len(rows))
	for i, r := range rows {
		s, ok := found[r.WriterCounter]
		if !ok {
			return nil, fmt.Errorf("%w: (%s, %s) counter %d is not stored, but this batch also contains counters that are",
				ErrPartiallyApplied, writerID, stream, r.WriterCounter)
		}
		if !bytes.Equal(s.hash, r.BlobHash) {
			return nil, fmt.Errorf("%w: (%s, %s) counter %d already holds different bytes (stored %x, submitted %x)",
				ErrChainBreak, writerID, stream, r.WriterCounter, s.hash, r.BlobHash)
		}
		out[i] = s.seq
	}
	return out, nil
}

// isPositionTaken reports whether err is a unique violation on the
// (user_id, writer_id, stream, writer_counter) key specifically. It is
// deliberately narrow: a 23505 on op_log_pkey is a corrupted seq counter
// (append.go's TestACorruptedCounterFailsLoudly...), an entirely different
// failure that must not be translated into "already applied".
func isPositionTaken(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == uniqueViolation && pgErr.ConstraintName == positionConstraint
}
