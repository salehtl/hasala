package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

type harness struct {
	t    *testing.T
	pool *pgxpool.Pool
	srv  *Server
	h    http.Handler
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pool := pgtest.New(t)
	srv := &Server{
		Pool:     pool,
		Sessions: &auth.Sessions{Pool: pool, TTL: time.Hour},
		Writers:  &auth.Writers{Pool: pool},
		Appender: &oplog.Appender{Pool: pool},
		Logf:     func(string, ...any) {},
	}
	return &harness{t: t, pool: pool, srv: srv, h: srv.Handler()}
}

// user creates an account with synthetic account keys (so it can upload). sub
// only names it in the test.
func (h *harness) user(sub string) uuid.UUID {
	h.t.Helper()
	u := h.userWithoutKeys(sub)
	oplogtest.AddKeys(h.t, h.pool, u)
	return u
}

// userWithoutKeys is an account that has not bootstrapped.
func (h *harness) userWithoutKeys(sub string) uuid.UUID {
	h.t.Helper()
	return oplogtest.NewUserWithoutKeys(h.t, h.pool)
}

func (h *harness) session(u uuid.UUID) string {
	h.t.Helper()
	tok, err := h.srv.Sessions.Issue(bg, u)
	if err != nil {
		h.t.Fatal(err)
	}
	return tok
}

// writer enrols a live device writer directly in the roster, with the
// deterministic DWK oplogtest.DWK(id) signs heads with. Registration itself
// (the AAK signature) is routes_writers_test.go's subject.
func (h *harness) writer(u uuid.UUID, id string) ed25519.PrivateKey {
	h.t.Helper()
	return oplogtest.NewWriter(h.t, h.pool, u, id)
}

// bind binds tok's session to writer id directly (spec 02 §9.4's binding is
// set by registration and bootstrap; these tests are about what a bound
// session may do).
func (h *harness) bind(tok, id string) {
	h.t.Helper()
	if _, err := h.pool.Exec(bg, `UPDATE sessions SET writer_id = $2 WHERE token_hash = $1`, auth.SessionHash(tok), id); err != nil {
		h.t.Fatal(err)
	}
}

// signHeads controls req's convenience for POST /api/v1/sync: an
// UploadRequest without a head_sig is signed with the writer's deterministic
// DWK, and an unbound session is bound to the request's writer when that
// writer exists on the session's account. Tests about heads and binding turn
// it off.
var signHeads = true

// prepareUpload applies signHeads to one upload body.
func (h *harness) prepareUpload(token string, req *UploadRequest) {
	h.t.Helper()
	if !signHeads || token == "" {
		return
	}
	info, err := h.srv.Sessions.Info(bg, token)
	if err != nil {
		return
	}
	if info.WriterID == "" {
		_, _ = h.pool.Exec(bg, `UPDATE sessions SET writer_id = $3
			WHERE token_hash = $1 AND writer_id IS NULL
			  AND EXISTS (SELECT 1 FROM writers WHERE user_id = $2 AND writer_id = $3)`, info.Hash, info.UserID, req.WriterID)
	}
	if req.HeadSig != "" || len(req.Blobs) == 0 || !keyproto.ValidWriterID(req.WriterID) {
		return
	}
	last := req.Blobs[len(req.Blobs)-1]
	c, err1 := strconv.ParseInt(last.WriterCounter, 10, 64)
	hash, err2 := hex.DecodeString(last.BlobHash)
	if err1 != nil || err2 != nil || len(hash) != 32 {
		return
	}
	m, err := keyproto.HeadMessage(info.UserID, uint64(c), hash, req.WriterID)
	if err != nil {
		return
	}
	req.HeadSig = base64.StdEncoding.EncodeToString(ed25519.Sign(oplogtest.DWK(req.WriterID), m))
}

func (h *harness) req(method, path, token string, body any) *httptest.ResponseRecorder {
	h.t.Helper()
	switch b := body.(type) {
	case UploadRequest:
		h.prepareUpload(token, &b)
		body = b
	case *UploadRequest:
		h.prepareUpload(token, b)
	}
	var r *http.Request
	switch b := body.(type) {
	case nil:
		r = httptest.NewRequest(method, path, nil)
	case []byte:
		r = httptest.NewRequest(method, path, bytes.NewReader(b))
		r.Header.Set("Content-Type", "application/json")
	default:
		raw, err := json.Marshal(b)
		if err != nil {
			h.t.Fatal(err)
		}
		r = httptest.NewRequest(method, path, bytes.NewReader(raw))
		r.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.h.ServeHTTP(w, r)
	return w
}

func decodeJSON[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var out T
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %s: %v", w.Body.String(), err)
	}
	return out
}

func wantStatus(t *testing.T, w *httptest.ResponseRecorder, want int) {
	t.Helper()
	if w.Code != want {
		t.Fatalf("status %d, want %d (body %s)", w.Code, want, w.Body.String())
	}
}

// wantError asserts the spec 02 §6.3 error code of a refusal.
func wantError(t *testing.T, w *httptest.ResponseRecorder, code string) {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body.Error != code {
		t.Fatalf("error code %q, want %q (body %s)", body.Error, code, w.Body.String())
	}
}

// seedWriter is the writer h.seed appends under.
var seedWriter = oplogtest.WID(0x5eed)

// seed appends n sealed frame v3 rows for the account through the real
// appender, under seedWriter, enrolled for the purpose.
func (h *harness) seed(u uuid.UUID, n int) {
	h.t.Helper()
	var exists bool
	if err := h.pool.QueryRow(bg,
		`SELECT EXISTS (SELECT 1 FROM writers WHERE user_id = $1 AND writer_id = $2)`, u, seedWriter).Scan(&exists); err != nil {
		h.t.Fatal(err)
	}
	if !exists {
		oplogtest.AddKeys(h.t, h.pool, u)
		oplogtest.NewWriter(h.t, h.pool, u, seedWriter)
	}
	oplogtest.Append(h.t, h.pool, u, seedWriter, n)
}

// sealUpload builds one wire blob for the upload endpoint: a frame v3 sealed
// at exactly the position it declares.
func sealUpload(t *testing.T, u uuid.UUID, writerID string, counter int64, prev [32]byte, body string) (UploadBlob, [32]byte) {
	t.Helper()
	sealed, err := blobtest.Seal3(blob.Envelope{
		UserID: u, Stream: blob.StreamHot, WriterID: writerID, WriterCounter: counter,
	}, 1, blobtest.TestEpochKey, prev, []byte(body))
	if err != nil {
		t.Fatal(err)
	}
	return wireBlob(counter, prev, sealed.Bytes)
}

// wireBlob frames arbitrary bytes as an upload blob with honest chain
// arithmetic, so a refusal can only be about the bytes themselves.
func wireBlob(counter int64, prev [32]byte, raw []byte) (UploadBlob, [32]byte) {
	h := blob.Hash(prev, blob.Sealed{Bytes: raw, SizeBucket: len(raw)})
	return UploadBlob{
		WriterCounter: strconv.FormatInt(counter, 10),
		PrevHash:      hex.EncodeToString(prev[:]),
		BlobHash:      hex.EncodeToString(h[:]),
		TypeFlag:      oplog.TypeFlagEdit,
		SizeBucket:    len(raw),
		Blob:          base64.StdEncoding.EncodeToString(raw),
	}, h
}

func uploadChain(t *testing.T, u uuid.UUID, writerID string, start int64, prev [32]byte, n int) ([]UploadBlob, [32]byte) {
	t.Helper()
	out := make([]UploadBlob, 0, n)
	for i := 0; i < n; i++ {
		b, h := sealUpload(t, u, writerID, start+int64(i), prev, fmt.Sprintf(`{"op":%d}`, start+int64(i)))
		out = append(out, b)
		prev = h
	}
	return out, prev
}

func countRows(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM op_log WHERE user_id = $1`, u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// ---------------------------------------------------------------------------
// Pull
// ---------------------------------------------------------------------------

func TestSyncReturnsOnlyTheCallersRows(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.seed(a, 2)
	h.seed(b, 3)

	got := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot", h.session(a), nil))
	if len(got.Rows) != 2 {
		t.Fatalf("user a pulled %d hot rows, want 2", len(got.Rows))
	}
	bRows := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot", h.session(b), nil))
	for _, ra := range got.Rows {
		for _, rb := range bRows.Rows {
			if ra.Seq == rb.Seq && ra.BlobHash == rb.BlobHash {
				t.Fatal("user a and user b were served the same row")
			}
		}
	}
}

func TestSyncIgnoresAUserIDSuppliedByTheCaller(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.seed(b, 4)

	// Every query is scoped by the RESOLVED session user. A user_id in the
	// request must be inert, not authoritative.
	got := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&user_id="+b.String(), h.session(a), nil))
	if len(got.Rows) != 0 {
		t.Fatalf("a user_id query parameter pulled %d of another user's rows", len(got.Rows))
	}
}

func TestAPullOfTheWholeLogIsCompleteAndVerifiesAsOneChain(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	h.seed(u, 10)

	got := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100", h.session(u), nil))
	if len(got.Rows) != 10 {
		t.Fatalf("pulled %d rows, want 10", len(got.Rows))
	}
	if !got.Complete {
		t.Fatal("a pull that returned the whole stream reported complete=false")
	}
	rows := make([]oplog.Row, len(got.Rows))
	var last int64
	for i, r := range got.Rows {
		seq := mustInt(t, r.Seq)
		if seq <= last {
			t.Fatalf("row %d seq %d does not follow %d", i, seq, last)
		}
		last = seq
		if r.Stream != blob.StreamHot {
			t.Fatalf("row %d is on stream %q", i, r.Stream)
		}
		if got := mustInt(t, r.WriterCounter); got != int64(i+1) {
			t.Fatalf("row %d has writer_counter %d, want %d", i, got, i+1)
		}
		rows[i] = wireToRow(t, r)
	}
	if err := oplog.VerifyChain(rows, 0, blob.ZeroHash); err != nil {
		t.Fatalf("the pulled rows must verify as one chain from genesis: %v", err)
	}
	if got.Next != got.Rows[len(got.Rows)-1].Seq {
		t.Fatalf("next is %q, want the last seq %q", got.Next, got.Rows[len(got.Rows)-1].Seq)
	}
}

func TestSyncCursorPagesWithoutGapsWithinAStream(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.seed(u, 250)

	var counters []int64
	after := "0"
	pages := 0
	for {
		got := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100&after="+after, tok, nil))
		pages++
		for _, r := range got.Rows {
			counters = append(counters, mustInt(t, r.WriterCounter))
		}
		if got.Complete {
			break
		}
		if len(got.Rows) == 0 {
			t.Fatal("an incomplete page returned no rows: the cursor cannot advance")
		}
		after = got.Next
		if pages > 10 {
			t.Fatal("paging did not terminate")
		}
	}
	if len(counters) != 250 {
		t.Fatalf("paged %d rows, want 250", len(counters))
	}
	for i, c := range counters {
		if c != int64(i+1) {
			t.Fatalf("counter %d is %d, want %d — the pages do not concatenate", i, c, i+1)
		}
	}
}

func TestHashListCoversEveryBlobAndMatchesTheStoredHashes(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.seed(u, 8)

	rows := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100", tok, nil))
	hashes := decodeJSON[HashesResponse](t, h.req("GET", "/api/v1/sync/hashes?stream=hot&limit=100", tok, nil))
	if len(hashes.Hashes) != len(rows.Rows) {
		t.Fatalf("%d hashes for %d rows", len(hashes.Hashes), len(rows.Rows))
	}
	prev := hex.EncodeToString(blob.ZeroHash[:])
	for i, e := range hashes.Hashes {
		if e.Seq != rows.Rows[i].Seq || e.BlobHash != rows.Rows[i].BlobHash {
			t.Fatalf("hash %d does not match the stored row", i)
		}
		if e.PrevHash != prev {
			t.Fatalf("hash %d links to %s, but the list is at %s", i, e.PrevHash, prev)
		}
		if e.WriterCounter != strconv.Itoa(i+1) {
			t.Fatalf("hash %d has counter %s, want %d", i, e.WriterCounter, i+1)
		}
		prev = e.BlobHash
	}
	if !hashes.Complete {
		t.Fatal("a hash list covering the whole stream reported complete=false")
	}
}

func TestAPullTruncatedByTheByteBudgetIsNotComplete(t *testing.T) {
	// This is the case `complete` exists for and the one a page-size heuristic
	// gets wrong: the page ends early because of BYTES, not because the row
	// limit was reached or the stream ran out. A client told "complete" here
	// stops syncing with rows outstanding.
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	// Five one-row batches: a page never ends inside a batch (spec 02 §11.3),
	// so the byte budget can cut only between batches.
	for i := 0; i < 5; i++ {
		h.seed(u, 1)
	}
	h.srv.PullByteBudget = 2 * 1024 // two smallest-bucket blobs
	h.h = h.srv.Handler()

	first := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100", tok, nil))
	if len(first.Rows) != 2 {
		t.Fatalf("a 2 KiB budget returned %d rows, want 2", len(first.Rows))
	}
	if first.Complete {
		t.Fatal("a page truncated by the byte budget reported complete=true; " +
			"the client would stop syncing with 3 rows outstanding")
	}

	// And the cursor still walks the whole stream.
	seen := len(first.Rows)
	next := first.Next
	for i := 0; i < 10; i++ {
		page := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100&after="+next, tok, nil))
		seen += len(page.Rows)
		next = page.Next
		if page.Complete {
			break
		}
	}
	if seen != 5 {
		t.Fatalf("paging under a byte budget saw %d rows, want 5", seen)
	}
}

func TestACursorPastTheEndOfTheStreamIsCursorAhead(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)

	for _, path := range []string{"/api/v1/sync?stream=hot", "/api/v1/sync/hashes?stream=hot"} {
		wantStatus(t, h.req("GET", path+"&after=0", tok, nil), http.StatusOK)
		w := h.req("GET", path+"&after=1", tok, nil)
		wantStatus(t, w, http.StatusConflict)
		if got := decodeJSON[map[string]any](t, w)["error"]; got != "cursor_ahead" {
			t.Fatalf("%s on an empty stream answered error %v, want cursor_ahead", path, got)
		}
	}

	h.seed(u, 3)
	all := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&limit=100", tok, nil))
	end := mustInt(t, all.Next)
	at := strconv.FormatInt(end, 10)
	past := strconv.FormatInt(end+1, 10)

	tip := decodeJSON[PullResponse](t, h.req("GET", "/api/v1/sync?stream=hot&after="+at, tok, nil))
	if len(tip.Rows) != 0 || !tip.Complete || tip.Next != at {
		t.Fatalf("a pull at the end answered %d rows, complete=%v, next=%s", len(tip.Rows), tip.Complete, tip.Next)
	}
	tipHashes := decodeJSON[HashesResponse](t, h.req("GET", "/api/v1/sync/hashes?stream=hot&after="+at, tok, nil))
	if len(tipHashes.Hashes) != 0 || !tipHashes.Complete {
		t.Fatalf("a hash list at the end answered %d hashes, complete=%v", len(tipHashes.Hashes), tipHashes.Complete)
	}

	for _, path := range []string{"/api/v1/sync?stream=hot&after=", "/api/v1/sync/hashes?stream=hot&after="} {
		w := h.req("GET", path+past, tok, nil)
		wantStatus(t, w, http.StatusConflict)
		if got := decodeJSON[map[string]any](t, w)["error"]; got != "cursor_ahead" {
			t.Fatalf("%s%s answered error %v, want cursor_ahead", path, past, got)
		}
	}
}

func TestPullHasOneStream(t *testing.T) {
	// Spec 02 §11.3: `stream` absent means hot, and every other value —
	// ledgerd's retired cold stream included — is 400 bad_stream.
	h := newHarness(t)
	tok := h.session(h.user("u"))
	for _, path := range []string{
		"/api/v1/sync?stream=warm", "/api/v1/sync?stream=cold",
		"/api/v1/sync/hashes?stream=cold",
	} {
		w := h.req("GET", path, tok, nil)
		wantStatus(t, w, http.StatusBadRequest)
		if got := decodeJSON[map[string]any](t, w)["error"]; got != "bad_stream" {
			t.Fatalf("%s answered error %v, want bad_stream", path, got)
		}
	}
	wantStatus(t, h.req("GET", "/api/v1/sync", tok, nil), http.StatusOK)
	wantStatus(t, h.req("GET", "/api/v1/sync/hashes?stream=", tok, nil), http.StatusOK)
}

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

func TestUploadAppendsAndIsIdempotentOnResend(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 3)
	body := UploadRequest{WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs}
	w := h.req("POST", "/api/v1/sync", tok, body)
	wantStatus(t, w, http.StatusOK)
	first := decodeJSON[UploadResponse](t, w)
	if len(first.Seqs) != 3 {
		t.Fatalf("upload returned %d seqs, want 3", len(first.Seqs))
	}

	again := decodeJSON[UploadResponse](t, h.req("POST", "/api/v1/sync", tok, body))
	if fmt.Sprint(again.Seqs) != fmt.Sprint(first.Seqs) {
		t.Fatalf("a byte-identical resend returned %v, want the original %v", again.Seqs, first.Seqs)
	}
	if n := countRows(t, h.pool, u); n != 3 {
		t.Fatalf("op_log holds %d rows after a resend, want 3", n)
	}
}

func TestUploadRejectsAWriterIDTheCallerDoesNotOwn(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.writer(b, "ios-00000000-0000-4000-8000-00000000000b")
	blobs, _ := uploadChain(t, a, "ios-00000000-0000-4000-8000-00000000000b", 1, blob.ZeroHash, 1)

	w := h.req("POST", "/api/v1/sync", h.session(a), UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000b", Stream: blob.StreamHot, Blobs: blobs,
	})
	wantStatus(t, w, http.StatusForbidden)
	if n := countRows(t, h.pool, a); n != 0 {
		t.Fatalf("%d rows were appended for a writer the caller does not own", n)
	}
	if n := countRows(t, h.pool, b); n != 0 {
		t.Fatalf("%d rows were appended into the OTHER user's log", n)
	}
}

func TestUploadCannotWriteIntoAnotherUsersLog(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.writer(a, "ios-00000000-0000-4000-8000-00000000000a")
	h.writer(b, "ios-00000000-0000-4000-8000-00000000000a") // same writer id, different account

	// Blobs sealed for user b's AAD, submitted on user a's session. There is no
	// user field on the wire, so the only way to aim at b is through the AAD —
	// and the position check must refuse it.
	blobs, _ := uploadChain(t, b, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 1)
	w := h.req("POST", "/api/v1/sync", h.session(a), UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	})
	wantStatus(t, w, http.StatusBadRequest)
	if n := countRows(t, h.pool, b); n != 0 {
		t.Fatalf("%d rows landed in the other user's log", n)
	}
	if n := countRows(t, h.pool, a); n != 0 {
		t.Fatalf("%d rows landed under the caller with someone else's AAD", n)
	}
}

func TestUploadRejectsARevokedWriter(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")
	h.bind(tok, "ios-00000000-0000-4000-8000-00000000000a")

	// Revocation itself (step-up, the pinned head) is auth's to test; here
	// the writer row is revoked and its session survived, which is the state
	// the upload path must refuse on its own (403 writer_revoked).
	if _, err := h.pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`,
		u, "ios-00000000-0000-4000-8000-00000000000a"); err != nil {
		t.Fatal(err)
	}
	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 1)
	w := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	})
	wantStatus(t, w, http.StatusForbidden)
	wantError(t, w, "writer_revoked")
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows were appended by a revoked writer", n)
	}
}

func TestUploadRejectsBlobWhoseAADDoesNotMatchTheRow(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	// Sealed for counter 5, submitted as counter 1. The bytes are well formed
	// and the chain arithmetic is honest; only the position is a lie.
	b, _ := sealUpload(t, u, "ios-00000000-0000-4000-8000-00000000000a", 5, blob.ZeroHash, `{"moved":true}`)
	b.WriterCounter = "1"
	w := h.req("POST", "/api/v1/sync", h.session(u), UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{b},
	})
	wantStatus(t, w, http.StatusBadRequest)
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows were stored at a position they were not sealed for", n)
	}
}

func TestUploadRejectsOversizeAndBadBucket(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	good, _ := sealUpload(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, `{"op":1}`)

	mismatched := good
	mismatched.SizeBucket = good.SizeBucket * 2
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{mismatched},
	}), http.StatusBadRequest)

	notABucket := good
	raw, _ := base64.StdEncoding.DecodeString(good.Blob)
	notABucket.Blob = base64.StdEncoding.EncodeToString(raw[:len(raw)-1])
	notABucket.SizeBucket = len(raw) - 1
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{notABucket},
	}), http.StatusBadRequest)

	oversize := good
	big := make([]byte, blob.MaxBucket+1)
	oversize.Blob = base64.StdEncoding.EncodeToString(big)
	oversize.SizeBucket = len(big)
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{oversize},
	}), http.StatusRequestEntityTooLarge)

	// The framing version is frozen (blob's package doc: "Nothing else may
	// move"), so a blob declaring another one is unopenable by every client
	// that will ever read it. Storing it is permanent, silent loss — the log is
	// append-only — so it is refused at the door rather than set aside later.
	// An empty blob must be a clean 400, not a panic on raw[0].
	empty := good
	empty.Blob, empty.SizeBucket = "", 0
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{empty},
	}), http.StatusBadRequest)

	badVersion := good
	raw2, _ := base64.StdEncoding.DecodeString(good.Blob)
	raw2 = append([]byte(nil), raw2...)
	raw2[0] = blob.Version3 + 1
	badVersion.Blob = base64.StdEncoding.EncodeToString(raw2)
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{badVersion},
	}), http.StatusBadRequest)

	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d malformed rows were stored", n)
	}
}

func TestUploadRefusesAnyStreamButHot(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")
	b, _ := sealUpload(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, `{"raw":true}`)
	w := h.req("POST", "/api/v1/sync", h.session(u), UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: "cold", Blobs: []UploadBlob{b},
	})
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "bad_stream")
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows were stored on a retired stream", n)
	}
}

func TestUploadReportsAChainBreakAsAConflict(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 3)
	// Skip counter 1: the batch starts above the stored head.
	w := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs[1:],
	})
	wantStatus(t, w, http.StatusConflict)
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows were appended past a chain break", n)
	}
}

func TestABatchThatDoesNotChainToItselfIsAClientErrorNotATamperSignal(t *testing.T) {
	// oplog.AppendClient verifies the batch's internal links BEFORE it touches
	// the database, so an inconsistency there is provably the client's own
	// arithmetic — nothing the server did could have caused it. Answering it
	// with the chain-break signal would raise spec §3.3:68's non-dismissable
	// "your server may have tampered with your data" warning over a client bug.
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	// Row 2's blob_hash is not SHA256(prev || bytes): purely a local mistake.
	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 2)
	bad := blobs[1]
	bad.BlobHash = hex.EncodeToString(make([]byte, 32))
	w := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{blobs[0], bad},
	})
	wantStatus(t, w, http.StatusBadRequest)
	if bytes.Contains(w.Body.Bytes(), []byte("chain_break")) {
		t.Fatalf("a client-side batch error raised the tamper hard stop: %s", w.Body.String())
	}

	// A batch whose rows do not link to each other is the same class.
	blobs2, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 2)
	unlinked := blobs2[1]
	unlinked.PrevHash = hex.EncodeToString(bytes.Repeat([]byte{7}, 32))
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{blobs2[0], unlinked},
	}), http.StatusBadRequest)

	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows were stored from an inconsistent batch", n)
	}

	// The head-relative case is still the hard stop: whether the client skipped
	// or the server lost rows is genuinely ambiguous, and that is the one this
	// signal is for.
	good, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 3)
	conflict := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: good[1:],
	})
	wantStatus(t, conflict, http.StatusConflict)
	if !bytes.Contains(conflict.Body.Bytes(), []byte("chain_break")) {
		t.Fatalf("a head mismatch must still be a chain break: %s", conflict.Body.String())
	}
}

func TestUploadTellsAPartialResendToResendAboveTheHead(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")

	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 3)
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs[:2],
	}), http.StatusOK)

	// Counters 1..2 are applied; resending 2..3 straddles the head. The server
	// refuses rather than trimming, and must say what the client should do.
	w := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs[1:],
	})
	wantStatus(t, w, http.StatusConflict)
	if !bytes.Contains(w.Body.Bytes(), []byte("read the chain head and resend only the rows above it")) {
		t.Fatalf("a straddling resend must quote the client contract verbatim, got %s", w.Body.String())
	}
	// And the documented remedy must work.
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs[2:],
	}), http.StatusOK)
}

func TestConcurrentUploadsFromOneWriterProduceOneWinner(t *testing.T) {
	// pgxpool connects lazily, so an unwarmed race staggers its own racers and
	// passes under implementations that do not actually serialise.
	pool := pgtest.New(t)
	warmPool(t, pool, 4)
	srv := &Server{
		Pool:     pool,
		Sessions: &auth.Sessions{Pool: pool, TTL: time.Hour},
		Writers:  &auth.Writers{Pool: pool},
		Appender: &oplog.Appender{Pool: pool},
		Logf:     func(string, ...any) {},
	}
	h := &harness{t: t, pool: pool, srv: srv, h: srv.Handler()}

	for round := 0; round < 5; round++ {
		u := h.user(fmt.Sprintf("race-%d", round))
		tok := h.session(u)
		h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")
		one, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 1)
		two, _ := sealUpload(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, `{"other":true}`)

		var wg sync.WaitGroup
		codes := make([]int, 2)
		start := make(chan struct{})
		for i, body := range []UploadRequest{
			{WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: one},
			{WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: []UploadBlob{two}},
		} {
			wg.Add(1)
			go func(i int, body UploadRequest) {
				defer wg.Done()
				<-start
				codes[i] = h.req("POST", "/api/v1/sync", tok, body).Code
			}(i, body)
		}
		close(start)
		wg.Wait()

		ok, conflict := 0, 0
		for _, c := range codes {
			switch c {
			case http.StatusOK:
				ok++
			case http.StatusConflict:
				conflict++
			default:
				t.Fatalf("round %d: unexpected status %d", round, c)
			}
		}
		if ok != 1 || conflict != 1 {
			t.Fatalf("round %d: %d ok / %d conflict, want exactly one of each (codes %v)", round, ok, conflict, codes)
		}
		if n := countRows(t, h.pool, u); n != 1 {
			t.Fatalf("round %d: %d rows stored, want 1", round, n)
		}
	}
}

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

// ---------------------------------------------------------------------------
// Authentication and authorization
// ---------------------------------------------------------------------------

func TestEveryEndpointRefusesAnAbsentSession(t *testing.T) {
	h := newHarness(t)
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/v1/sync?stream=hot"},
		{"GET", "/api/v1/sync/hashes?stream=hot"},
		{"POST", "/api/v1/sync"},
		{"GET", "/api/v1/writers"},
		{"POST", "/api/v1/writers/challenge"},
		{"POST", "/api/v1/writers/register"},
	} {
		w := h.req(c.method, c.path, "", nil)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s without a session returned %d, want 401", c.method, c.path, w.Code)
		}
	}
}

func TestUnknownExpiredAndRevokedSessionsAreIndistinguishable(t *testing.T) {
	pool := pgtest.New(t)
	now := time.Now()
	clock := func() time.Time { return now }
	srv := &Server{
		Pool:     pool,
		Sessions: &auth.Sessions{Pool: pool, TTL: time.Hour, Now: clock},
		Writers:  &auth.Writers{Pool: pool, Now: clock},
		Appender: &oplog.Appender{Pool: pool},
		Logf:     func(string, ...any) {},
	}
	h := &harness{t: t, pool: pool, srv: srv, h: srv.Handler()}
	u := h.user("u")

	expired := h.session(u)
	revoked := h.session(u)
	if err := srv.Sessions.Revoke(bg, revoked); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Hour) // kills `expired`; `revoked` is already dead
	unknown := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

	type answer struct {
		code    int
		body    string
		headers string
	}
	var got []answer
	for _, tok := range []string{unknown, expired, revoked, "not-base64-at-all", ""} {
		w := h.req("GET", "/api/v1/sync?stream=hot", tok, nil)
		got = append(got, answer{w.Code, w.Body.String(), fmt.Sprint(w.Header())})
	}
	for i, a := range got {
		if a.code != http.StatusUnauthorized {
			t.Fatalf("case %d returned %d, want 401", i, a.code)
		}
		if a != got[0] {
			t.Fatalf("case %d answered %+v; case 0 answered %+v — the difference is an oracle", i, a, got[0])
		}
	}
}

func TestABearerTokenAloneCannotRegisterAWriter(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	d := authtest.NewDevice(t)
	nonce := decodeJSON[ChallengeResponse](t, h.req("POST", "/api/v1/writers/challenge", tok, nil))

	// A session buys a nonce and nothing else: without the authority key's
	// signature, registration fails (spec 01 §10.5), whatever key signs.
	raw, _ := base64.StdEncoding.DecodeString(nonce.Nonce)
	m, _ := keyproto.RegistrationMessage(raw, d.WriterID, d.DWKPub(), d.DAKPub())
	w := h.req("POST", "/api/v1/writers/register", tok, RegisterRequest{
		WriterID: d.WriterID, Alg: "ed25519", PubKey: b64(d.DWKPub()), DAKPubkey: b64(d.DAKPub()),
		Nonce: nonce.Nonce, Sig: b64(ed25519.Sign(d.DWK, m)),
	})
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "bad_signature")
	roster := decodeJSON[WritersResponse](t, h.req("GET", "/api/v1/writers", tok, nil))
	if len(roster.Writers) != 0 {
		t.Fatalf("a bare session enrolled %d writers", len(roster.Writers))
	}
}

func mustNewKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func TestRosterIsScopedToTheCaller(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.writer(a, "ios-00000000-0000-4000-8000-00000000000a")
	h.writer(b, "ios-00000000-0000-4000-8000-00000000000b")

	// One entry: there is no server-side writer any more (spec 02 §2 retires
	// ledgerd's per-account `ingest` writer with the mail path).
	roster := decodeJSON[WritersResponse](t, h.req("GET", "/api/v1/writers", h.session(a), nil))
	if len(roster.Writers) != 1 || roster.Writers[0].WriterID != "ios-00000000-0000-4000-8000-00000000000a" {
		t.Fatalf("roster for user a is %+v, want dev-a alone", roster.Writers)
	}
	got := roster.Writers[0]
	if got.PubKey == "" || got.DAKPubkey == "" || got.Alg != "ed25519" {
		t.Fatalf("roster entry is missing its key material or alg: %+v", got)
	}
	if got.RevokedAt != nil {
		t.Fatal("a live writer came back with a revoked_at")
	}
}

// ---------------------------------------------------------------------------
// Response headers
// ---------------------------------------------------------------------------

func TestResponsesAreNotCacheable(t *testing.T) {
	// The pull response carries the user's op log. It may not be written to a
	// shared cache, a proxy, or a client's disk cache.
	h := newHarness(t)
	pull := h.req("GET", "/api/v1/sync?stream=hot", h.session(h.user("u")), nil)
	wantStatus(t, pull, http.StatusOK)
	if got := pull.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("a pull of the op log has Cache-Control %q, want no-store", got)
	}
}

func TestEveryResponseCarriesTheSecurityHeaders(t *testing.T) {
	// Spec 02 §6.2, on success, on refusal and on the 404 fallback alike.
	h := newHarness(t)
	tok := h.session(h.user("u"))
	for _, w := range []*httptest.ResponseRecorder{
		h.req("GET", "/api/v1/sync?stream=hot", tok, nil),
		h.req("GET", "/api/v1/sync?stream=hot", "", nil),
		h.req("GET", "/nope", "", nil),
		h.req("GET", "/healthz", "", nil),
	} {
		for k, want := range map[string]string{
			"X-Content-Type-Options":       "nosniff",
			"Referrer-Policy":              "no-referrer",
			"Content-Security-Policy":      "default-src 'none'; frame-ancestors 'none'",
			"Cross-Origin-Resource-Policy": "same-origin",
		} {
			if got := w.Header().Get(k); got != want {
				t.Fatalf("status %d response has %s %q, want %q", w.Code, k, got, want)
			}
		}
	}
}

func TestUploadSizeCapsAgree(t *testing.T) {
	// A batch that satisfies maxUploadBlobs must fit maxUploadBytes, or a
	// conforming client hits the generic body-cap 413 instead of the per-blob
	// answer that says which blob is wrong and why. Pure arithmetic, asserted
	// so the two constants cannot drift apart.
	worst := base64.StdEncoding.EncodedLen(blob.MaxBucket)*maxUploadBlobs + 1024
	if worst > maxUploadBytes {
		t.Fatalf("%d max-size blobs base64-encode to %d bytes, over the %d-byte body cap: "+
			"lower maxUploadBlobs or raise maxUploadBytes", maxUploadBlobs, worst, maxUploadBytes)
	}
}

// ---------------------------------------------------------------------------
// Rate limits
// ---------------------------------------------------------------------------

func TestRegistrationAttemptsAreRateLimited(t *testing.T) {
	// The challenge cap bounds SUCCESSFUL registrations only. A failed attempt
	// — a replayed nonce, say — consumes no challenge budget and still costs
	// two database round trips inside consumeChallenge before any signature
	// work happens.
	h := newHarness(t)
	h.srv.RegisterPerUser = NewLimiter(0, 3, 128, time.Now)
	h.h = h.srv.Handler()
	u := h.user("u")
	tok := h.session(u)
	other := h.session(h.user("other"))

	body := RegisterRequest{
		WriterID:  "ios-00000000-0000-4000-8000-00000000000a",
		Alg:       "ed25519",
		PubKey:    base64.StdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize)),
		DAKPubkey: base64.StdEncoding.EncodeToString(make([]byte, 65)),
		Nonce:     base64.StdEncoding.EncodeToString(make([]byte, auth.ChallengeNonceBytes)),
		Sig:       base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)),
	}
	attempted, limited := 0, 0
	for i := 0; i < 30; i++ {
		switch h.req("POST", "/api/v1/writers/register", tok, body).Code {
		case http.StatusTooManyRequests:
			limited++
		default:
			attempted++
		}
	}
	if attempted != 3 {
		t.Fatalf("%d registration attempts reached the signature path, want the cap of 3", attempted)
	}
	if limited == 0 {
		t.Fatal("no attempt was rate limited")
	}
	// Per user, not global.
	if code := h.req("POST", "/api/v1/writers/register", other, body).Code; code == http.StatusTooManyRequests {
		t.Fatal("one account's failed attempts rate-limited another account")
	}
}

func TestChallengeMintingIsCappedPerUser(t *testing.T) {
	h := newHarness(t)
	h.srv.ChallengePerUser = NewLimiter(0, 4, 128, time.Now)
	h.h = h.srv.Handler()
	a, b := h.user("a"), h.user("b")
	tokA, tokB := h.session(a), h.session(b)

	allowed := 0
	for i := 0; i < 30; i++ {
		switch h.req("POST", "/api/v1/writers/challenge", tokA, nil).Code {
		case http.StatusOK:
			allowed++
		case http.StatusTooManyRequests:
		default:
			t.Fatalf("challenge %d returned an unexpected status", i)
		}
	}
	if allowed != 4 {
		t.Fatalf("one session minted %d challenges, want the cap of 4", allowed)
	}
	var stored int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM writer_challenges WHERE user_id = $1`, a).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != 4 {
		t.Fatalf("%d challenge rows were written despite the cap", stored)
	}
	// The cap is per user, not global: one account cannot lock another out.
	wantStatus(t, h.req("POST", "/api/v1/writers/challenge", tokB, nil), http.StatusOK)
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

func TestUnknownAPIPathIs404JSON(t *testing.T) {
	h := newHarness(t)
	w := h.req("GET", "/api/v1/nope", h.session(h.user("u")), nil)
	wantStatus(t, w, http.StatusNotFound)
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type %q, want application/json", ct)
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("404 body is not JSON: %s", w.Body.String())
	}
}

func TestUnknownPathOutsideTheAPIIs404JSON(t *testing.T) {
	// The catch-all is the whole of what the root serves: there is no web UI
	// and no console in hasalad (spec 02 §2, F7-1).
	h := newHarness(t)
	for _, path := range []string{"/", "/console", "/console/", "/admin", "/index.html"} {
		w := h.req("GET", path, "", nil)
		wantStatus(t, w, http.StatusNotFound)
		if ct := w.Header().Get("Content-Type"); ct != "application/json" {
			t.Fatalf("%s: content-type %q, want application/json", path, ct)
		}
	}
}

// TestRetiredLedgerdRoutesAreGone is AT-HTTP-1's second half: every route of
// spec 02 §2.4, method and path as the table lists them, answers exactly what
// an unknown path answers, 404 with {"error":"not_found"}, with and without a
// session. Deleted, not disabled: not a 405, not a 401, not a 403.
func TestRetiredLedgerdRoutesAreGone(t *testing.T) {
	h := newHarness(t)
	tok := h.session(h.user("u"))
	retired := []string{
		"POST /api/v1/auth/exchange",
		"PUT /api/v1/keys",
		"POST /api/v1/account/challenge",
		"GET /api/v1/address",
		"POST /api/v1/address/challenge",
		"POST /api/v1/address/rotate",
		"GET /api/v1/quarantine",
		"POST /api/v1/quarantine/confirm",
		"GET /api/v1/quarantine/allowlist",
		"DELETE /api/v1/quarantine/allowlist",
		"GET /api/v1/push/vapid",
		"POST /api/v1/push/subscriptions",
		"GET /api/v1/push/subscriptions",
		"DELETE /api/v1/push/subscriptions",
		"DELETE /api/v1/push/subscriptions/some-handle",
		"GET /api/v1/dictionary",
		"POST /api/v1/dictionary/submissions",
		"GET /api/v1/templates",
		"POST /api/v1/samples/report",
		"POST /api/v1/samples/donate",
		"POST /api/v1/mailbox/oauth/begin",
		"GET /api/v1/mailbox/oauth/callback",
		"POST /api/v1/mailbox/oauth/claim",
		"POST /api/v1/mailbox/token",
		"POST /api/v1/mailbox/revoke",
		"GET /api/v1/mailbox/grant",
		"DELETE /api/v1/mailbox/grant",
		"GET /api/v1/mailbox/senders",
		"POST /api/v1/mailbox/senders",
		"DELETE /api/v1/mailbox/senders",
		"GET /api/v1/relay/addresses",
		"POST /api/v1/relay/deliver",
		// ledgerd's write-once key publication, retired for the AAK-signed
		// bootstrap (spec 02 §2.4).
		"PUT /api/v1/keys",
		// `/` (the SPA fallback) and every /admin/* route, ledgerd's admin
		// listener among them: a sample of what that console served.
		"GET /",
		"GET /index.html",
		"GET /admin",
		"GET /admin/",
		"GET /admin/status",
		"GET /admin/dictionary",
		"POST /admin/dictionary/approve-seed",
		"POST /admin/templates",
		"GET /admin/accounts",
		"POST /admin/accounts/some-id/suspend",
		"POST /admin/waitlist",
		"POST /admin/invites",
		"DELETE /admin/samples/1",
	}
	for _, route := range retired {
		method, path, _ := strings.Cut(route, " ")
		for _, bearer := range []string{"", tok} {
			w := h.req(method, path, bearer, nil)
			if w.Code != http.StatusNotFound {
				t.Errorf("%s (session %v) answered %d, want 404", route, bearer != "", w.Code)
				continue
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("%s: content-type %q, want application/json", route, ct)
			}
			if got := decodeJSON[errorBody](t, w).Error; got != "not_found" {
				t.Errorf("%s: error %q, want not_found", route, got)
			}
		}
	}
}

func TestWrongMethodIsNotSilentlyRouted(t *testing.T) {
	h := newHarness(t)
	tok := h.session(h.user("u"))
	if w := h.req("DELETE", "/api/v1/sync", tok, nil); w.Code == http.StatusOK {
		t.Fatal("DELETE /api/v1/sync was served")
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func mustInt(t *testing.T, s string) int64 {
	t.Helper()
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		t.Fatalf("%q is not a decimal integer: %v", s, err)
	}
	return n
}

func wireToRow(t *testing.T, r Row) oplog.Row {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(r.Blob)
	if err != nil {
		t.Fatal(err)
	}
	bh, err := hex.DecodeString(r.BlobHash)
	if err != nil {
		t.Fatal(err)
	}
	ph, err := hex.DecodeString(r.PrevHash)
	if err != nil {
		t.Fatal(err)
	}
	return oplog.Row{
		Seq:           mustInt(t, r.Seq),
		Stream:        r.Stream,
		WriterID:      r.WriterID,
		WriterCounter: mustInt(t, r.WriterCounter),
		TypeFlag:      r.TypeFlag,
		Blob:          raw,
		SizeBucket:    r.SizeBucket,
		BlobHash:      bh,
		PrevHash:      ph,
	}
}

func TestPullsAreLimitedPerAccountAndToTwoInFlight(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	// Two slots held: the third concurrent pull is refused.
	if !h.srv.pulls.acquire(u, maxConcurrentPulls) || !h.srv.pulls.acquire(u, maxConcurrentPulls) {
		t.Fatal("two slots were not available")
	}
	w := h.req("GET", "/api/v1/sync?stream=hot", tok, nil)
	wantStatus(t, w, http.StatusTooManyRequests)
	wantError(t, w, "rate_limited")
	h.srv.pulls.release(u)
	wantStatus(t, h.req("GET", "/api/v1/sync/hashes?stream=hot", tok, nil), http.StatusOK)
	h.srv.pulls.release(u)
	if n := len(h.srv.pulls.inUse); n != 0 {
		t.Fatalf("%d accounts still hold slots", n)
	}
	// pull-user's own budget.
	h.srv.PullPerUser = NewLimiter(0, 2, 16, time.Now)
	h.h = h.srv.Handler()
	// A pull refused for want of a slot spends no pull-user token.
	if !h.srv.pulls.acquire(u, maxConcurrentPulls) || !h.srv.pulls.acquire(u, maxConcurrentPulls) {
		t.Fatal("two slots were not available")
	}
	wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", tok, nil), http.StatusTooManyRequests)
	h.srv.pulls.release(u)
	h.srv.pulls.release(u)
	for i := 0; i < 2; i++ {
		wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", tok, nil), http.StatusOK)
	}
	wantStatus(t, h.req("GET", "/api/v1/sync?stream=hot", tok, nil), http.StatusTooManyRequests)
	// And a pull the limiter refuses gives its slot back.
	if n := len(h.srv.pulls.inUse); n != 0 {
		t.Fatalf("%d accounts still hold slots after a limiter refusal", n)
	}
}

type heldBody struct {
	once    sync.Once
	started chan struct{}
	release chan struct{}
}

func (b *heldBody) Read([]byte) (int, error) {
	b.once.Do(func() { close(b.started) })
	<-b.release
	return 0, io.EOF
}

func (h *harness) uploadsInFlight(u uuid.UUID) int {
	h.srv.uploads.mu.Lock()
	defer h.srv.uploads.mu.Unlock()
	return h.srv.uploads.inUse[u]
}

func TestUploadsAreLimitedToTwoInFlightPerAccount(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")
	other := h.user("other")
	otherTok := h.session(other)
	h.writer(other, "ios-00000000-0000-4000-8000-00000000000b")

	release := make(chan struct{})
	var wg sync.WaitGroup
	codes := make([]int, maxConcurrentUploads)
	for i := range maxConcurrentUploads {
		body := &heldBody{started: make(chan struct{}), release: release}
		r := httptest.NewRequest("POST", "/api/v1/sync", body)
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+tok)
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			h.h.ServeHTTP(w, r)
			codes[i] = w.Code
		}()
		select {
		case <-body.started:
		case <-time.After(10 * time.Second):
			close(release)
			t.Fatalf("upload %d never reached its body", i)
		}
	}
	if n := h.uploadsInFlight(u); n != maxConcurrentUploads {
		close(release)
		t.Fatalf("%d uploads hold slots, want %d", n, maxConcurrentUploads)
	}

	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-00000000000a", 1, blob.ZeroHash, 1)
	w := h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	})
	wantStatus(t, w, http.StatusTooManyRequests)
	wantError(t, w, "rate_limited")
	if n := countRows(t, h.pool, u); n != 0 {
		close(release)
		t.Fatalf("a refused upload stored %d rows", n)
	}

	otherBlobs, _ := uploadChain(t, other, "ios-00000000-0000-4000-8000-00000000000b", 1, blob.ZeroHash, 1)
	wantStatus(t, h.req("POST", "/api/v1/sync", otherTok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000b", Stream: blob.StreamHot, Blobs: otherBlobs,
	}), http.StatusOK)

	close(release)
	wg.Wait()
	for i, c := range codes {
		if c != http.StatusBadRequest {
			t.Fatalf("held upload %d answered %d, want 400 for its empty body", i, c)
		}
	}
	if n := len(h.srv.uploads.inUse); n != 0 {
		t.Fatalf("%d accounts still hold upload slots", n)
	}

	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	}), http.StatusOK)
	if n := len(h.srv.uploads.inUse); n != 0 {
		t.Fatalf("%d accounts still hold upload slots after a stored upload", n)
	}

	h.srv.SyncPerUser = NewLimiter(0, 1, 16, time.Now)
	h.h = h.srv.Handler()
	h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	})
	wantStatus(t, h.req("POST", "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-00000000000a", Stream: blob.StreamHot, Blobs: blobs,
	}), http.StatusTooManyRequests)
	if n := len(h.srv.uploads.inUse); n != 0 {
		t.Fatalf("%d accounts still hold upload slots after a limiter refusal", n)
	}
}
