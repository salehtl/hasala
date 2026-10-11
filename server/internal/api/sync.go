package api

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
)

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------
//
// These are the shapes the TypeScript client codes against. int64 fields are
// decimal STRINGS and chain hashes are hex; see the package doc for why.

// Row is one op-log row on the wire.
type Row struct {
	Seq           string    `json:"seq"`
	Stream        string    `json:"stream"`
	WriterID      string    `json:"writer_id"`
	WriterCounter string    `json:"writer_counter"`
	TypeFlag      string    `json:"type_flag"`
	SizeBucket    int       `json:"size_bucket"`
	BlobHash      string    `json:"blob_hash"` // hex
	PrevHash      string    `json:"prev_hash"` // hex
	CreatedAt     time.Time `json:"created_at"`
	Blob          string    `json:"blob"` // base64
	// HeadSig is the batch's DWK signature over HeadMessage (spec 01 §7.1), b64
	// on the last row of each upload batch and null on the others. A page
	// never ends inside a batch, so every writer's last row in a page has one.
	HeadSig *string `json:"head_sig"`
}

// PullResponse answers GET /api/v1/sync.
//
// Next is the largest seq returned FOR THIS STREAM and is what the caller sends
// back as `after`. Complete answers "is this client caught up on this stream",
// and it is computed against the stream's committed maximum rather than
// inferred from the page size — a page can end early because of the byte
// budget, and a client that read "short page, therefore done" would stop
// syncing with rows outstanding.
type PullResponse struct {
	Stream   string `json:"stream"`
	Rows     []Row  `json:"rows"`
	Next     string `json:"next"`
	Complete bool   `json:"complete"`
}

// HashEntry is one entry of the per-blob hash list (spec §3.3:72).
type HashEntry struct {
	Seq           string `json:"seq"`
	WriterID      string `json:"writer_id"`
	WriterCounter string `json:"writer_counter"`
	BlobHash      string `json:"blob_hash"` // hex
	PrevHash      string `json:"prev_hash"` // hex
}

// HashesResponse answers GET /api/v1/sync/hashes.
type HashesResponse struct {
	Stream   string      `json:"stream"`
	Hashes   []HashEntry `json:"hashes"`
	Next     string      `json:"next"`
	Complete bool        `json:"complete"`
}

// UploadBlob is one blob a device submits, already sealed for the position it
// declares and already chained by its author.
type UploadBlob struct {
	WriterCounter string `json:"writer_counter"`
	PrevHash      string `json:"prev_hash"` // hex
	BlobHash      string `json:"blob_hash"` // hex
	TypeFlag      string `json:"type_flag"`
	SizeBucket    int    `json:"size_bucket"`
	Blob          string `json:"blob"` // base64
}

// UploadRequest is POST /api/v1/sync. It carries no user id: the account is the
// one the session resolves to, always.
type UploadRequest struct {
	WriterID string       `json:"writer_id"`
	Stream   string       `json:"stream"`
	Blobs    []UploadBlob `json:"blobs"`
	// HeadSig is the writer's DWK signature over HeadMessage(user_id, c_last,
	// blob_hash_last, writer_id) for the batch's last blob (spec 01 §7.1, b64).
	HeadSig string `json:"head_sig"`
}

// UploadResponse returns the assigned seqs, in submission order.
type UploadResponse struct {
	Seqs []string `json:"seqs"`
}

// ---------------------------------------------------------------------------
// Pull
// ---------------------------------------------------------------------------

// pullSlots bounds the pulls in flight per account (spec 02 §11.3: at most 2;
// the third gets 429). The map holds one counter per account only while a
// pull runs.
type pullSlots struct {
	mu    sync.Mutex
	inUse map[uuid.UUID]int
}

func (p *pullSlots) acquire(u uuid.UUID) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inUse == nil {
		p.inUse = map[uuid.UUID]int{}
	}
	if p.inUse[u] >= maxConcurrentPulls {
		return false
	}
	p.inUse[u]++
	return true
}

func (p *pullSlots) release(u uuid.UUID) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inUse[u]--; p.inUse[u] <= 0 {
		delete(p.inUse, u)
	}
}

// pullAdmitted applies pull-user and the concurrency bound; the caller
// releases the slot when it returns true.
func (s *Server) pullAdmitted(w http.ResponseWriter, userID uuid.UUID) bool {
	if !s.PullPerUser.Allow(userID.String()) || !s.pulls.acquire(userID) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many pulls; try again shortly")
		return false
	}
	return true
}

func (s *Server) handlePull(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.pullAdmitted(w, userID) {
		return
	}
	defer s.pulls.release(userID)
	stream, ok := requireStream(w, r)
	if !ok {
		return
	}
	after, err := parseCursor(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	limit, err := parseLimit(r, defaultPullLimit, maxPullLimit)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	rows, err := oplog.Read(r.Context(), s.Pool, userID, stream, after, limit, s.PullByteBudget)
	if err != nil {
		s.logf("api: pull %s for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := PullResponse{Stream: stream, Rows: make([]Row, 0, len(rows))}
	// An empty page leaves the cursor exactly where the caller had it, so a
	// client that keeps sending `next` back never rewinds.
	next := after
	for _, row := range rows {
		next = row.Seq
		var headSig *string
		if row.HeadSig != nil {
			hs := base64.StdEncoding.EncodeToString(row.HeadSig)
			headSig = &hs
		}
		out.Rows = append(out.Rows, Row{
			HeadSig:       headSig,
			Seq:           strconv.FormatInt(row.Seq, 10),
			Stream:        row.Stream,
			WriterID:      row.WriterID,
			WriterCounter: strconv.FormatInt(row.WriterCounter, 10),
			TypeFlag:      row.TypeFlag,
			SizeBucket:    row.SizeBucket,
			BlobHash:      hex.EncodeToString(row.BlobHash),
			PrevHash:      hex.EncodeToString(row.PrevHash),
			CreatedAt:     row.CreatedAt,
			Blob:          base64.StdEncoding.EncodeToString(row.Blob),
		})
	}
	out.Next = strconv.FormatInt(next, 10)

	// Asked AFTER the page, never before: rows committed in between make this
	// report "not complete", which costs one empty round trip. The other order
	// can report complete while rows exist, which costs the client its data.
	maxSeq, err := oplog.StreamMaxSeq(r.Context(), s.Pool, userID, stream)
	if err != nil {
		s.logf("api: pull %s max seq for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out.Complete = next >= maxSeq
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHashes(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.pullAdmitted(w, userID) {
		return
	}
	defer s.pulls.release(userID)
	stream, ok := requireStream(w, r)
	if !ok {
		return
	}
	after, err := parseCursor(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	limit, err := parseLimit(r, defaultHashLimit, maxHashLimit)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	hashes, err := oplog.Hashes(r.Context(), s.Pool, userID, stream, after, limit)
	if err != nil {
		s.logf("api: hashes %s for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := HashesResponse{Stream: stream, Hashes: make([]HashEntry, 0, len(hashes))}
	next := after
	for _, h := range hashes {
		next = h.Seq
		out.Hashes = append(out.Hashes, HashEntry{
			Seq:           strconv.FormatInt(h.Seq, 10),
			WriterID:      h.WriterID,
			WriterCounter: strconv.FormatInt(h.WriterCounter, 10),
			BlobHash:      hex.EncodeToString(h.BlobHash),
			PrevHash:      hex.EncodeToString(h.PrevHash),
		})
	}
	out.Next = strconv.FormatInt(next, 10)
	maxSeq, err := oplog.StreamMaxSeq(r.Context(), s.Pool, userID, stream)
	if err != nil {
		s.logf("api: hashes %s max seq for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out.Complete = next >= maxSeq
	writeJSON(w, http.StatusOK, out)
}

// requireStream reads the `stream` query parameter. There is one stream:
// absent means hot, and anything else is 400 bad_stream (spec 02 §11.3).
func requireStream(w http.ResponseWriter, r *http.Request) (string, bool) {
	stream := r.URL.Query().Get("stream")
	if stream == "" {
		return blob.StreamHot, true
	}
	if stream != blob.StreamHot {
		writeErr(w, http.StatusBadRequest, "bad_stream", "stream must be "+strconv.Quote(blob.StreamHot))
		return "", false
	}
	return stream, true
}

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

// handleUpload appends a device's own blobs (spec 02 #30, §11.1).
//
// Order matters and is not arbitrary:
//
//  1. the session resolves the account — there is no user field on the wire;
//  2. the body's shape: the stream, the batch size, a 64-byte head_sig;
//  3. the writer: the §4.8 grammar, then the session must be bound to exactly
//     that writer (spec 02 §9.4), and it must be live;
//  4. the account has keys;
//  5. every blob is validated structurally — size, the plaintext predicate,
//     and the embedded AAD of the exact position it is being stored at;
//  6. only then does the append transaction open, where the writer row is
//     read FOR SHARE, the chain joined to the stored head, the epoch checked
//     for rows above the head, and the head signature verified over the last
//     row as the server recomputed it.
//
// Nothing is stored unless the whole batch is: oplog.AppendClient rolls back as
// a unit, so a rejected batch consumes neither a seq nor a counter.
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	// The request budget, spent before anything is read. It is the POOL
	// fairness control — one account cannot occupy the 16-connection pool with
	// back-to-back append transactions — and it is explicitly NOT the storage
	// control; see the syncRate block in api.go for the arithmetic that shows
	// why no request rate could be.
	if !s.SyncPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many uploads; try again shortly")
		return
	}
	var req UploadRequest
	if !decodeBody(w, r, maxUploadBytes, &req) {
		return
	}
	if req.Stream == "" {
		req.Stream = blob.StreamHot
	}
	if req.Stream != blob.StreamHot {
		writeErr(w, http.StatusBadRequest, "bad_stream", "stream must be "+strconv.Quote(blob.StreamHot))
		return
	}
	if len(req.Blobs) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "blobs is empty")
		return
	}
	if len(req.Blobs) > maxUploadBlobs {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large",
			"at most "+strconv.Itoa(maxUploadBlobs)+" blobs per upload")
		return
	}
	headSig, err := base64.StdEncoding.DecodeString(req.HeadSig)
	if err != nil || len(headSig) != keyproto.Ed25519SigSize {
		writeErr(w, http.StatusBadRequest, "bad_signature", "head_sig must be a 64-byte signature in base64")
		return
	}
	if !keyproto.ValidWriterID(req.WriterID) {
		writeErr(w, http.StatusBadRequest, "bad_writer_id", "writer_id does not match the ios-<uuid v4> grammar")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if info.WriterID == "" {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return
	}
	if req.WriterID != info.WriterID {
		writeErr(w, http.StatusForbidden, "writer_mismatch", "")
		return
	}
	if !s.requireBound(w, r, info) {
		return
	}
	var hasKeys bool
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT EXISTS (SELECT 1 FROM account_keys WHERE user_id = $1)`, userID).Scan(&hasKeys); err != nil {
		s.logf("api: upload for %s: read keys: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if !hasKeys {
		writeErr(w, http.StatusForbidden, "keys_required", "")
		return
	}

	rows := make([]oplog.Row, 0, len(req.Blobs))
	for i, b := range req.Blobs {
		row, refusal := decodeUploadBlob(userID, req.WriterID, req.Stream, b)
		if refusal != nil {
			if refusal.code == "plaintext_refused" {
				// Logged with the check name only: what a client sent in a
				// refused frame is never echoed into an operator log.
				s.logf("api: upload for %s: blob %d refused as plaintext (%s)", userID, i, refusal.detail)
			}
			writeErr(w, refusal.status, refusal.code, "blobs["+strconv.Itoa(i)+"]: "+refusal.detail)
			return
		}
		rows = append(rows, row)
	}

	// The batch's INTERNAL consistency is checked here, before the append, so
	// that its failure is answered as what it is: a client-side arithmetic
	// error. oplog.AppendClient runs the same check and reports ErrChainBreak,
	// a sync hard stop; nothing the server did can make the blobs of one
	// request fail to link to each other, so a client bug must never tell a
	// user their operator may have tampered with their log. What is left for
	// AppendClient's ErrChainBreak is the HEAD-relative case.
	var claimedPrev [32]byte
	copy(claimedPrev[:], rows[0].PrevHash)
	if err := oplog.VerifyChain(rows, rows[0].WriterCounter-1, claimedPrev); err != nil {
		s.logf("api: upload for %s: batch is not internally chained: %v", userID, err)
		writeErr(w, http.StatusBadRequest, "bad_request",
			"the blobs in this batch do not chain to each other: counters must be consecutive, "+
				"each prev_hash must be the previous blob_hash, and each blob_hash must be "+
				"SHA256(prev_hash || blob)")
		return
	}

	// The byte budget, spent immediately before the append and charged in the
	// bytes that are about to become durable, after validation (a malformed
	// batch costs no budget), all-or-nothing per batch like the append.
	var uploadBytes int
	for _, row := range rows {
		uploadBytes += len(row.Blob)
	}
	if !s.SyncUploadBytes.AllowN(userID.String(), float64(uploadBytes)) {
		// 429 rather than 413: the batch is not too large, it is too soon.
		s.logf("api: upload for %s: %d bytes over the upload byte budget", userID, uploadBytes)
		w.Header().Set("Retry-After", "60")
		writeErr(w, http.StatusTooManyRequests, "upload_bytes",
			"this account has uploaded more than its share of data recently; "+
				"the queued changes are safe on this device and will upload shortly")
		return
	}

	seqs, err := s.Appender.AppendClient(r.Context(), userID, req.WriterID, req.Stream, rows, headSig)
	if err != nil {
		s.writeAppendErr(w, r, userID, err)
		return
	}
	out := UploadResponse{Seqs: make([]string, len(seqs))}
	for i, q := range seqs {
		out.Seqs[i] = strconv.FormatInt(q, 10)
	}
	writeJSON(w, http.StatusOK, out)
}

// uploadRefusal is why one blob of an upload cannot be stored: the HTTP status,
// the spec 02 §6.3 error code, and a detail about the caller's own submission.
type uploadRefusal struct {
	status       int
	code, detail string
}

func refuseBlob(status int, code, detail string) *uploadRefusal {
	return &uploadRefusal{status: status, code: code, detail: detail}
}

// decodeUploadBlob turns one wire blob into an oplog.Row, or says why it
// cannot be one. The order is spec 02 §11.1 step 5: the size checks first
// (spec 01 T18), then the plaintext predicate, then the position.
//
// The predicate is the server half of F1: a blob that does not look like a
// sealed frame v3 — a ledgerd v1 or v2 frame, a zero nonce or tag, zero
// padding or a cleartext gzip header where ciphertext should be — is refused
// with 400 plaintext_refused naming the check, before anything is stored.
// oplog.Row.validate runs it again inside the append and the
// op_log_blob_is_sealed CHECK is the database's guarantee behind both.
//
// The AAD check stops a blob being stored at a position it was not sealed for,
// including a blob sealed for ANOTHER USER. It reads the cleartext header, so
// the server needs no key. The key-epoch check against the account's current
// epoch (409 stale_epoch) runs inside oplog.AppendClient after the head read,
// for rows above the stored head only (spec 01 §8.3), so a replayed batch is
// never refused for its epoch.
func decodeUploadBlob(userID uuid.UUID, writerID, stream string, b UploadBlob) (oplog.Row, *uploadRefusal) {
	counter, err := strconv.ParseInt(b.WriterCounter, 10, 64)
	if err != nil || counter < 1 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "writer_counter must be a decimal integer of at least 1")
	}
	raw, err := base64.StdEncoding.DecodeString(b.Blob)
	if err != nil {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "blob is not base64")
	}
	// Checked before the bucket check so an oversize blob is a 413 and not a
	// confusing "not a size bucket" 400.
	if len(raw) > blob.MaxBucket {
		return oplog.Row{}, refuseBlob(http.StatusRequestEntityTooLarge, "too_large",
			"blob is "+strconv.Itoa(len(raw))+" bytes, cap is "+strconv.Itoa(blob.MaxBucket))
	}
	if b.SizeBucket != len(raw) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_bucket",
			"size_bucket is "+strconv.Itoa(b.SizeBucket)+" but the blob is "+strconv.Itoa(len(raw))+" bytes")
	}
	if !blob.IsBucket(len(raw)) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_bucket",
			"blob is "+strconv.Itoa(len(raw))+" bytes, which is not a size bucket")
	}
	frame, err := blob.Parse3(raw)
	if err != nil {
		var re *blob.RefusalError
		if errors.As(err, &re) {
			return oplog.Row{}, refuseBlob(http.StatusBadRequest, "plaintext_refused", re.Check)
		}
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "plaintext_refused", "framing")
	}
	want := blob.Envelope{UserID: userID, Stream: stream, WriterID: writerID, WriterCounter: counter}
	if err := want.Validate(); err != nil {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "the position this blob claims is not a valid one")
	}
	if !bytes.Equal(frame.AAD, want.AAD()) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "aad_mismatch",
			"the blob was sealed for a different position than the one it is being stored at")
	}
	blobHash, err := hex.DecodeString(b.BlobHash)
	if err != nil || len(blobHash) != 32 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "blob_hash must be 64 hex characters")
	}
	prevHash, err := hex.DecodeString(b.PrevHash)
	if err != nil || len(prevHash) != 32 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "prev_hash must be 64 hex characters")
	}
	if b.TypeFlag != "" && b.TypeFlag != oplog.TypeFlagEdit {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "type_flag must be "+strconv.Quote(oplog.TypeFlagEdit))
	}
	return oplog.Row{
		UserID:        userID,
		Stream:        stream,
		WriterID:      writerID,
		WriterCounter: counter,
		TypeFlag:      oplog.TypeFlagEdit,
		Blob:          raw,
		SizeBucket:    len(raw),
		BlobHash:      blobHash,
		PrevHash:      prevHash,
	}, nil
}

// writeAppendErr maps the append's outcomes onto statuses a client can act on.
//
// The three conflict cases are deliberately distinguished in the DETAIL and not
// in the status, because a client's remedy differs: a chain break is a sync
// hard stop (spec §3.3:68), a partial resend has a trivial fix, and a taken
// position is a server-side invariant violation the client cannot repair. All
// three describe the caller's own log, so the detail discloses nothing.
func (s *Server) writeAppendErr(w http.ResponseWriter, r *http.Request, userID uuid.UUID, err error) {
	var stale *oplog.StaleEpochError
	switch {
	case errors.As(err, &stale):
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusConflict, "stale_epoch", "current_epoch "+strconv.FormatInt(stale.Current, 10))
	case errors.Is(err, oplog.ErrHeadSignature), errors.Is(err, oplog.ErrWriterRevoked),
		errors.Is(err, oplog.ErrUnknownWriter), errors.Is(err, oplog.ErrKeysRequired):
		s.writeKeyErr(w, r, err)
	case errors.Is(err, oplog.ErrPartiallyApplied):
		// The client contract, quoted verbatim from oplog/chain.go: the server
		// refuses a straddling batch rather than trimming it.
		writeErr(w, http.StatusConflict, "conflict",
			"read the chain head and resend only the rows above it")
	case errors.Is(err, oplog.ErrChainBreak):
		writeErr(w, http.StatusConflict, "chain_break", err.Error())
	case errors.Is(err, budget.ErrRefused):
		// The account is at its cumulative op-log ceiling. This is a POLICY
		// outcome, not a fault, and it used to fall through to the 500 below —
		// so an account that had filled its budget was told the server was
		// broken, which is both untrue and unactionable.
		//
		// 413 rather than 429, and the pair has to stay distinguishable: the
		// 429 upload_bytes above is the byte-weighted LIMITER, charged before
		// the append, and it means "too soon — the same batch will be accepted
		// shortly". This means "too much — the same batch will never be
		// accepted until something is deleted or the ceiling is raised". A
		// client that retried this on a timer would retry forever.
		var refused *budget.RefusedError
		if errors.As(err, &refused) {
			s.logf("api: upload for %s: over the account ceiling: %v", userID, err)
			writeJSON(w, http.StatusRequestEntityTooLarge, errorBody{
				Error: "account_full",
				Detail: "this account is at its storage ceiling; nothing in this upload was stored, " +
					"and it stays queued on this device",
				// The account's own numbers, so the app can say something true
				// instead of "sync failed": how much it holds, how much this
				// upload asked for, and what the ceiling is.
				Budget: &BudgetInfo{Resource: refused.Resource, Have: refused.Have, Delta: refused.Delta, Limit: refused.Limit},
			})
			return
		}
		// ErrRefused without the concrete error is not reachable from
		// budget.Admit, but answering a 500 because the DETAIL is missing would
		// throw away the one thing this case exists to get right.
		s.logf("api: upload for %s: over the account ceiling, without detail: %v", userID, err)
		writeErr(w, http.StatusRequestEntityTooLarge, "account_full",
			"this account is at its storage ceiling; nothing in this upload was stored")
	case errors.Is(err, oplog.ErrPositionTaken):
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusConflict, "conflict", "that chain position is already held")
	default:
		// Everything reachable here has already been screened by
		// decodeUploadBlob, so this is a server-side failure and gets no
		// detail.
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	}
}
