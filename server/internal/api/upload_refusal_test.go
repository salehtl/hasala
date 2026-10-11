package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
)

// The upload half of security finding F1: a blob that does not look like a
// sealed frame v3 is refused with 400 plaintext_refused naming the failed
// check, before anything is stored (spec 02 §11.1 step 5, spec 01 §8).

func errorDetail(t *testing.T, body []byte) (code, detail string) {
	t.Helper()
	var out struct {
		Error  string `json:"error"`
		Detail string `json:"detail"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("refusal body is not JSON: %s", body)
	}
	return out.Error, out.Detail
}

func TestUploadRefusesEveryFrameThePredicateRefuses(t *testing.T) {
	h := newHarness(t)
	h.srv.SyncPerUser = NewLimiter(0, 1000, 16, h.srv.now)
	h.h = h.srv.Handler()
	u := h.user("u")
	tok := h.session(u)
	h.writer(u, "dev-a")

	tried := 0
	for _, c := range blobtest.LooksSealedCases() {
		if !blob.IsBucket(len(c.Frame)) {
			continue // a size the bucket check answers first, as bad_bucket
		}
		b, _ := wireBlob(1, blob.ZeroHash, c.Frame)
		w := h.req("POST", "/api/v1/sync", tok, UploadRequest{WriterID: "dev-a", Blobs: []UploadBlob{b}})
		wantStatus(t, w, http.StatusBadRequest)
		code, detail := errorDetail(t, w.Body.Bytes())
		if c.Want == "" {
			// The predicate accepts it; it is then refused for the position
			// its (random) AAD does not name — never stored either way.
			if code != "aad_mismatch" {
				t.Fatalf("%s: answered %s (%s), want aad_mismatch", c.Name, code, detail)
			}
			continue
		}
		tried++
		if code != "plaintext_refused" || detail != "blobs[0]: "+c.Want {
			t.Fatalf("%s: answered %s %q, want plaintext_refused naming %q", c.Name, code, detail, c.Want)
		}
	}
	if tried < 10 {
		t.Fatalf("only %d refused cases reached the upload path; the table did not take", tried)
	}
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d refused frames were stored", n)
	}
}

func TestUploadRefusesALedgerdV1PlaintextFrame(t *testing.T) {
	// The frame ledgerd's clients upload today: honest position, honest chain
	// arithmetic, readable by anyone holding the database.
	h := newHarness(t)
	u := h.user("u")
	h.writer(u, "dev-a")
	s, err := blobtest.PlaintextSealer{}.Seal(blobtest.Envelope{
		UserID: u, Stream: blob.StreamHot, WriterID: "dev-a", WriterCounter: 1,
	}, []byte(`{"merchant":"plaintext"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := wireBlob(1, blob.ZeroHash, s.Bytes)
	w := h.req("POST", "/api/v1/sync", h.session(u), UploadRequest{WriterID: "dev-a", Blobs: []UploadBlob{b}})
	wantStatus(t, w, http.StatusBadRequest)
	if code, detail := errorDetail(t, w.Body.Bytes()); code != "plaintext_refused" || detail != "blobs[0]: "+blob.CheckVersion {
		t.Fatalf("a v1 frame answered %s %q, want plaintext_refused naming the version check", code, detail)
	}
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d plaintext rows were stored", n)
	}
}

func TestARefusedFrameRefusesTheWholeBatch(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	h.writer(u, "dev-a")
	good, prev := uploadChain(t, u, "dev-a", 1, blob.ZeroHash, 2)
	f := blobtest.Honest(1024, 50, 1)
	for i := 57; i < 69; i++ {
		f[i] = 0 // zero nonce (AT-P2)
	}
	bad, _ := wireBlob(3, prev, f)
	w := h.req("POST", "/api/v1/sync", h.session(u), UploadRequest{
		WriterID: "dev-a", Blobs: append(good, bad),
	})
	wantStatus(t, w, http.StatusBadRequest)
	if code, detail := errorDetail(t, w.Body.Bytes()); code != "plaintext_refused" || detail != "blobs[2]: "+blob.CheckNonce {
		t.Fatalf("answered %s %q, want plaintext_refused naming blobs[2] and the nonce check", code, detail)
	}
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows of a refused batch were stored", n)
	}
}

func TestUploadRefusesAFrameSealedForAnotherAccount(t *testing.T) {
	h := newHarness(t)
	a, b := h.user("a"), h.user("b")
	h.writer(a, "dev-a")
	// Sealed honestly for b's dev-a at counter 1 and replayed into a's log.
	stolen, _ := sealUpload(t, b, "dev-a", 1, blob.ZeroHash, `{"op":1}`)
	w := h.req("POST", "/api/v1/sync", h.session(a), UploadRequest{WriterID: "dev-a", Blobs: []UploadBlob{stolen}})
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "aad_mismatch")
	if n := countRows(t, h.pool, a); n != 0 {
		t.Fatalf("%d rows sealed for another account were stored", n)
	}
}

func TestUploadNamesABucketMismatch(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	h.writer(u, "dev-a")
	good, _ := sealUpload(t, u, "dev-a", 1, blob.ZeroHash, `{"op":1}`)
	good.SizeBucket *= 2
	w := h.req("POST", "/api/v1/sync", h.session(u), UploadRequest{WriterID: "dev-a", Blobs: []UploadBlob{good}})
	wantStatus(t, w, http.StatusBadRequest)
	wantError(t, w, "bad_bucket")
}
