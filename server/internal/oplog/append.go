package oplog

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

// TypeFlagEdit is the whole vocabulary of op_log.type_flag: every row is a
// device's own encrypted batch (the op_log_type_flag_is_edit CHECK). ledgerd's
// "ingest" flag marked rows the server authored from inbound mail; the server
// authors nothing now (spec 02 §2.3, C5). The op type lives inside the
// ciphertext and must never be lifted into a column.
const TypeFlagEdit = "edit"

// Row is one op_log row: a sealed blob plus the position it occupies. Seq is
// assigned by the server and is the ONLY field a caller may not set —
// appendRows rejects a row that arrives with one, because a caller that
// believes it can choose its own seq has misunderstood the ordering guarantee.
type Row struct {
	UserID        uuid.UUID
	Seq           int64  // server-assigned; zero on the way in, populated on reads
	Stream        string // blob.StreamHot
	WriterID      string
	WriterCounter int64 // 1-based position within (writer_id, stream)
	TypeFlag      string
	Blob          []byte // a sealed frame v3, exactly one bucket (blob.LooksSealed)
	SizeBucket    int
	BlobHash      []byte // 32 bytes: blob.Hash(prev, sealed)
	PrevHash      []byte // 32 bytes: the previous blob hash in this (writer, stream) chain
	// HeadSig is the batch's DWK signature over HeadMessage (spec 01 §7.1),
	// stored on the LAST row of each upload batch only and nil on the others.
	// AppendClient sets it; a caller never does.
	HeadSig []byte
	// CreatedAt defaults to now() when left zero. It is therefore NOT monotone with seq, and
	// ordering the log by it instead of by seq is subtly wrong — replay folds by
	// seq, and nothing else is a total order. Treat it as a diagnostic
	// timestamp, never as a position.
	CreatedAt time.Time
}

// validate rejects a row that could never be stored, or that could be stored
// and then never read back.
//
// AppendClient runs it BEFORE the append transaction opens, so a client's
// invalid batch cannot even reach the counter, and appendTx runs it again
// inside the transaction, so no future append path can skip it (spec 02
// §11.2). A rollback restores the counter, so a rejected batch consumes
// nothing either way.
func (r Row) validate() error {
	switch {
	case r.UserID == uuid.Nil:
		return errors.New("user_id is zero")
	case r.Seq != 0:
		return fmt.Errorf("seq is server-assigned; leave it zero (got %d)", r.Seq)
	case r.Stream != blob.StreamHot:
		return fmt.Errorf("stream is %q, want %q", r.Stream, blob.StreamHot)
	case r.WriterID == "":
		return errors.New("writer_id is empty")
	case r.WriterCounter < 1:
		return fmt.Errorf("writer_counter is %d, and counters are 1-based", r.WriterCounter)
	case r.TypeFlag != TypeFlagEdit:
		return fmt.Errorf("type_flag is %q, want %q", r.TypeFlag, TypeFlagEdit)
	case len(r.Blob) == 0:
		return errors.New("blob is empty")
	case len(r.BlobHash) != 32:
		return fmt.Errorf("blob_hash is %d bytes, want 32", len(r.BlobHash))
	case len(r.PrevHash) != 32:
		return fmt.Errorf("prev_hash is %d bytes, want 32", len(r.PrevHash))
	}
	// Every frame is exactly one size bucket. The size checks run before the
	// plaintext predicate (spec 01 T18), so a wrong length is named as such.
	bucket, err := blob.BucketFor(len(r.Blob))
	if err != nil {
		return fmt.Errorf("blob is %d bytes: %w", len(r.Blob), err)
	}
	if bucket != len(r.Blob) {
		return fmt.Errorf("blob is %d bytes, which is not a size bucket", len(r.Blob))
	}
	if r.SizeBucket != len(r.Blob) {
		return fmt.Errorf("size_bucket is %d but the blob is %d bytes", r.SizeBucket, len(r.Blob))
	}

	// The plaintext refusal (spec 01 §8.1, F1): the same predicate the upload
	// handler ran, and the op_log_blob_is_sealed CHECK behind both.
	if err := blob.LooksSealed(r.Blob); err != nil {
		return err
	}

	// The blob must have been sealed FOR the position it is about to occupy.
	//
	// Nothing else on the write path checks this. The hash chain does not: a
	// blob sealed at counter 7, or for a different user entirely, chains
	// perfectly well at counter 1 — SHA256 does not care what the bytes mean.
	// Without this check such a row is stored, verifies, and is only caught
	// later on a device, as a tamper stop. The op_log_aad_matches_position
	// CHECK restates it in SQL.
	//
	// The server does this with no key, because the AAD is cleartext framing
	// ahead of the nonce. bytes.Equal rather than a constant-time compare on
	// purpose: both sides are public framing the caller already supplied.
	aad, err := blob.EmbeddedAAD(r.Blob)
	if err != nil {
		return fmt.Errorf("blob framing is unreadable: %w", err)
	}
	want := blob.Envelope{
		UserID: r.UserID, Stream: r.Stream, WriterID: r.WriterID, WriterCounter: r.WriterCounter,
	}.AAD()
	if !bytes.Equal(aad, want) {
		return fmt.Errorf("blob was sealed for position %q but is being stored at %q", aad, want)
	}
	return nil
}

// Appender writes rows to the op log. It owns the one place a seq is ever
// allocated.
//
// Its one public write path is [Appender.AppendClient] (a device's own,
// pre-chained, sealed blobs) — see chain.go. There is deliberately no exported
// way to append without the chain check, and no server author at all.
type Appender struct {
	Pool *pgxpool.Pool
	// Budget is the per-account admission gate. nil does NOT mean "no budget":
	// it means a gate over Pool, built on demand by [Appender.budget].
	//
	// That default is the whole reason the ceiling is enforceable. If an unset
	// field disabled accounting, then every Appender literal in the tree —
	// api.New's, and every test's — would be silently unbudgeted, and the one
	// that mattered would be discovered in production. The field exists only so
	// a caller can inject a gate with a different clock or pool, never to turn
	// the gate off.
	Budget *budget.Gate
}

// EnsureSeqRow creates a user's counter row. It is called from auth.UpsertUser
// INSIDE the user-creation transaction, so the row exists before that user's
// first append and appendTx's own INSERT ... ON CONFLICT DO NOTHING is a no-op
// in steady state.
//
// "No-op" is not the same as "free": an INSERT whose conflicting row is being
// UPDATEd by an in-flight transaction must WAIT to learn whether that update
// commits. So an append arriving during another append for the same user blocks
// here, one statement before allocSeq, rather than at the counter itself. That
// changes nothing about correctness — the same transaction is being waited on
// either way — but it is worth knowing before writing a test that tries to
// interleave two appends at a chosen point.
//
// It takes a pgx.Tx rather than a pool deliberately: a counter row created in a
// separate transaction from the user could be committed while the user is not,
// or vice versa.
//
// ON CONFLICT DO NOTHING, not DO UPDATE: re-running this for an existing user
// must not reset next_seq. A reset would hand the next append a seq that
// already exists in op_log, which the (user_id, seq) primary key would then
// reject — recoverable, but it would stall that user's appends permanently.
func EnsureSeqRow(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
	if userID == uuid.Nil {
		return errors.New("oplog: EnsureSeqRow: user_id is zero")
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO oplog_seq (user_id) VALUES ($1) ON CONFLICT DO NOTHING`, userID); err != nil {
		return fmt.Errorf("oplog: ensure seq row: %w", err)
	}
	return nil
}

// appendRows allocates a contiguous block of seqs for one user and writes rows
// in the order given, returning the assigned seqs in that same order. Every row
// must carry the same UserID.
//
// It is unexported because every append must go through a chain check:
// [Appender.AppendClient] verifies a device's chain, and prepare is what it
// supplies — see [prepareFunc] and the ORDERING RULE on appendTx.
//
// # Gap-freeness
//
// seq must be gap-free and monotone per user: spec §3.7 resolves FX rates by
// folding the log by seq, so a hole changes computed budget totals. The
// guarantee comes from the per-user counter ROW, not from a sequence:
//
//   - The UPDATE below locks oplog_seq for this user until the transaction
//     commits, so a second append for the same user cannot even allocate until
//     this one finishes. Commit order is therefore identical to seq order, and
//     a committed seq N implies every seq below N is committed.
//   - Rollback is the reason this beats a sequence. A rolled-back UPDATE
//     restores the counter, so a failed append consumes nothing. nextval()
//     burns its value permanently and a watermark then has to reconstruct which
//     values were lost versus merely slow.
//   - The no-DUPLICATE half of that argument rests on READ COMMITTED
//     specifically: a blocked UPDATE re-evaluates `next_seq + $n` against the
//     row version the winner committed (EvalPlanQual), rather than against the
//     stale version it first read. That is why the isolation level is pinned
//     below instead of inherited — see pgtx.BeginReadCommitted.
//   - A crash cannot punch a hole either. The counter update and the row
//     inserts are one transaction, so one commit record covers both; commit-LSN
//     order equals commit order equals seq order, and recovery replays a WAL
//     PREFIX. A crash can therefore only truncate the tail of the log, never
//     remove something from its middle. That holds under synchronous_commit=off
//     too, which loses a suffix of commits, not an interior one.
//
// Do NOT replace this with a sequence plus a published watermark.
//
// # Ambiguous commit: an error does not always mean "not appended"
//
// If the context deadline expires (or the connection drops) during tx.Commit,
// appendRows returns an error for an append that may in fact have COMMITTED —
// the rows are present and next_seq has advanced, but the caller never learns
// its seqs. Gap-freeness is unaffected; retry semantics are not.
//
// This is why UNIQUE (user_id, writer_id, stream, writer_counter) is load
// bearing beyond chain integrity: it makes the ambiguity DETECTABLE. A caller
// that retries the same (writer_id, stream, writer_counter) after an error and
// receives SQLSTATE 23505 on that constraint must read it as "already applied"
// and resolve its seqs by reading the log back — NOT as a failure to retry
// again, which would loop forever. [Appender.AppendClient] owns that
// translation, in two layers: a retried batch whose counters sit at or below
// the committed head is recognised as a replay and answered with the stored
// seqs (which is why 23505 is not reached in the first place), and
// [isPositionTaken] handles the constraint violation itself as the backstop.
// See AppendClient's "Idempotent replay" section.
//
// # Accepted cost
//
// The row lock is held across the blob INSERTs, so a large upload serialises
// this one user's other appends for the duration of that write. It is
// bounded, per-user, and cheaper than reconstructing gap-freeness elsewhere.
// This is a deliberate trade, not an oversight (ledgerd's Decision 3).
func (a *Appender) appendRows(ctx context.Context, rows []Row, prepare prepareFunc) ([]int64, error) {
	if len(rows) == 0 {
		// Appending nothing must not touch the counter. Opening a transaction
		// to allocate a zero-length block would take the lock for no reason.
		return nil, nil
	}
	userID := rows[0].UserID
	for i, r := range rows {
		if r.UserID != userID {
			// One user per call is not a convenience restriction: a call
			// spanning two users would have to lock two counter rows, and two
			// such calls in opposite order would deadlock.
			return nil, fmt.Errorf("oplog: append: row %d belongs to user %s, row 0 to %s", i, r.UserID, userID)
		}
		if r.Seq != 0 {
			// Checked here as well as in validate() because prepare runs after
			// the counter is taken, and a caller-chosen seq is the one field
			// whose rejection must never depend on a hook.
			return nil, fmt.Errorf("oplog: append: row %d: seq is server-assigned; leave it zero (got %d)", i, r.Seq)
		}
	}

	// Pinned, not inherited; see pgtx.BeginReadCommitted for why. Measured
	// under `repeatable read`: 41 of 60 concurrent appends failed with
	// SQLSTATE 40001, the first from EnsureSeqRow — the statement that does
	// nothing in steady state. No holes appeared (a serialization failure is
	// a rollback, and a rollback restores the counter), so that is an
	// availability failure rather than corruption; it is still a silent,
	// config-dependent one.
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return nil, fmt.Errorf("oplog: append: begin: %w", err)
	}
	// Rolled back on a context detached from the caller's via pgtx.Rollback.
	// If ctx is already cancelled, tx.Rollback(ctx) fails immediately and pgx
	// destroys the connection; gap-freeness does not depend on this either
	// way (a destroyed connection makes the server abort the transaction,
	// which is exactly what restores the counter) but a clean rollback
	// returns the connection to the pool instead of burning it.
	defer pgtx.Rollback(ctx, tx)

	seqs, err := a.appendTx(ctx, tx, userID, rows, prepare)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("oplog: append: commit: %w", err)
	}
	return seqs, nil
}

// prepareFunc runs inside the append transaction, after allocSeq has taken the
// user's counter lock and before any row is inserted. It is where the
// per-(writer, stream) chain is verified (AppendClient).
//
// It may fill in or check any field of rows in place, but it must NOT change
// how many rows there are: the seq block is already reserved by the time it
// runs, so dropping a row would burn a seq and leave a hole. Returning an error
// aborts the whole append, which restores the counter and stores nothing.
type prepareFunc func(ctx context.Context, tx pgx.Tx, rows []Row) error

// appendTx is the body of an append, minus the transaction management. The
// per-(writer, stream) chain check runs as prepare, between allocSeq and
// insertRows, so seq allocation stays in exactly one place for every append
// path.
//
// ORDERING RULE, and it is not a style preference: allocSeq comes FIRST, before
// prepare and therefore before any read of a writer's chain head. Reading the
// head before taking the counter lock lets two concurrent uploads from one
// writer both observe head=5 and race for counter 6; the UNIQUE (user_id,
// writer_id, stream, writer_counter) constraint would catch that, but as a
// constraint violation rather than a chain break — the wrong error to hand a
// client, and detection where the ordering could have made it impossible.
//
// Reversing these two statements is pinned twice.
// TestTheChainCheckRunsAfterTheCounterLockIsTaken asserts the rule itself,
// deterministically and on one connection: a prepare hook reads oplog_seq on
// the append's own transaction and finds next_seq already advanced.
// TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak asserts the
// consequence: under the reversed order the loser's error is SQLSTATE 23505,
// not ErrChainBreak.
func (a *Appender) appendTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, rows []Row, prepare prepareFunc) ([]int64, error) {
	if err := EnsureSeqRow(ctx, tx, userID); err != nil {
		return nil, err
	}
	start, err := allocSeq(ctx, tx, userID, len(rows))
	if err != nil {
		return nil, err
	}
	if prepare != nil {
		if err := prepare(ctx, tx, rows); err != nil {
			return nil, err
		}
	}
	// Validated again inside the transaction, after prepare, so no append path
	// can skip LooksSealed (spec 02 §11.2). A failure here still costs nothing:
	// the rollback restores the counter, so an invalid batch leaves no hole.
	for i, r := range rows {
		if err := r.validate(); err != nil {
			return nil, fmt.Errorf("oplog: append: row %d: %w", i, err)
		}
	}
	// Admission, in the one place there is no way to append around.
	//
	// It is here rather than at an endpoint on purpose: a ceiling written "per
	// upload" binds only the endpoints that remember to call it, and the next
	// path that appends would not.
	//
	// It runs after allocSeq (the ORDERING RULE above) and after prepare: the
	// counter lock is already held, so same-account appends are serialized
	// before the usage row is touched and no deadlock between two appends is
	// possible.
	if err := a.admit(ctx, tx, userID, rows); err != nil {
		return nil, err
	}
	seqs := make([]int64, len(rows))
	for i := range rows {
		seqs[i] = start + int64(i)
	}
	if err := insertRows(ctx, tx, rows, seqs); err != nil {
		return nil, err
	}
	return seqs, nil
}

// budget returns the admission gate, defaulting to one over this appender's
// own pool. See the Budget field.
func (a *Appender) budget() *budget.Gate {
	if a.Budget != nil {
		return a.Budget
	}
	return budget.New(a.Pool)
}

// admit charges this batch's stored bytes to the account.
//
// The bytes counted are len(Blob) — the framed, bucket-padded bytes actually
// written to the column — because that is what fills the disk and what
// internal/verify's reconciliation computes (sum(octet_length(blob))). There
// is one stream, so one resource.
func (a *Appender) admit(ctx context.Context, tx pgx.Tx, userID uuid.UUID, rows []Row) error {
	var n int64
	for _, r := range rows {
		n += int64(len(r.Blob))
	}
	if err := a.budget().Admit(ctx, tx, userID, budget.ResourceOplogHotBytes, n); err != nil {
		return fmt.Errorf("oplog: append: %w", err)
	}
	return nil
}

const insertRowSQL = `INSERT INTO op_log
	(user_id, seq, stream, writer_id, writer_counter, type_flag,
	 blob, size_bucket, blob_hash, prev_hash, head_sig, created_at)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, coalesce($12::timestamptz, now()))`

// allocSeq takes the user's counter lock and reserves n consecutive values,
// returning the first. It is the ONLY place a seq is ever allocated.
//
// The two statements are deliberately not folded into one
// `INSERT ... ON CONFLICT ... RETURNING`: with DO NOTHING, Postgres suppresses
// RETURNING output on the conflict path, so the common case (the row already
// exists, which is every append after the first) returns zero rows and the Scan
// fails with pgx.ErrNoRows. The DO UPDATE form avoids that but turns every
// append into a write to a row it did not need to insert. Two statements are
// boring and correct.
//
// RETURNING sees the row as UPDATEd, so `next_seq - $2` is the value next_seq
// held BEFORE this call — i.e. the first seq of the reserved block.
func allocSeq(ctx context.Context, tx pgx.Tx, userID uuid.UUID, n int) (int64, error) {
	var start int64
	err := tx.QueryRow(ctx,
		`UPDATE oplog_seq SET next_seq = next_seq + $2 WHERE user_id = $1 RETURNING next_seq - $2`,
		userID, int64(n)).Scan(&start)
	if err != nil {
		return 0, fmt.Errorf("oplog: allocate %d seqs for user %s: %w", n, userID, err)
	}
	return start, nil
}

func insertRows(ctx context.Context, tx pgx.Tx, rows []Row, seqs []int64) error {
	batch := &pgx.Batch{}
	for i, r := range rows {
		var createdAt *time.Time
		if !r.CreatedAt.IsZero() {
			t := r.CreatedAt
			createdAt = &t
		}
		var headSig any
		if r.HeadSig != nil {
			headSig = r.HeadSig
		}
		batch.Queue(insertRowSQL, r.UserID, seqs[i], r.Stream, r.WriterID, r.WriterCounter,
			r.TypeFlag, r.Blob, r.SizeBucket, r.BlobHash, r.PrevHash, headSig, createdAt)
	}
	br := tx.SendBatch(ctx, batch)
	var firstErr error
	for i := range rows {
		if _, err := br.Exec(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("oplog: append: insert row %d (seq %d): %w", i, seqs[i], err)
		}
	}
	// Close must happen before the transaction is used again, and it reports any
	// error the per-statement Execs did not surface.
	if err := br.Close(); err != nil && firstErr == nil {
		firstErr = fmt.Errorf("oplog: append: insert batch: %w", err)
	}
	return firstErr
}

// MaxSeq is the highest seq committed for a user, or 0 if there are none.
//
// It reads op_log rather than oplog_seq.next_seq on purpose: next_seq counts
// allocations, including one an in-flight transaction may still roll back,
// while op_log counts what a reader can actually see. Because seq order equals
// commit order, the two agree whenever nothing is in flight, and when something
// is, this is the answer a sync cursor wants.
func (a *Appender) MaxSeq(ctx context.Context, userID uuid.UUID) (int64, error) {
	var max int64
	err := a.Pool.QueryRow(ctx,
		`SELECT coalesce(max(seq), 0) FROM op_log WHERE user_id = $1`, userID).Scan(&max)
	if err != nil {
		return 0, fmt.Errorf("oplog: max seq for user %s: %w", userID, err)
	}
	return max, nil
}
