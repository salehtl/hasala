package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/cryptoref/vectors"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// TestTamperUploadsGetTheirVerdict posts every upload of conformance/crypto-v3/
// tamper.json (spec 01 §15.3) to the real handler and requires the verdict the
// file states. The file is Go-written and Swift-read; this is where the server
// half of each verdict is held to it. Each case runs in a fresh account under
// the anchor user id (the frames' AAD names it): writer W with the anchor DWK,
// bound to the session, and the anchor frame A09 already stored at counter 1.
func TestTamperUploadsGetTheirVerdict(t *testing.T) {
	raw, err := os.ReadFile("../../../conformance/crypto-v3/tamper.json")
	if err != nil {
		t.Fatal(err)
	}
	var file vectors.TamperFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	pool, owner := pgtest.NewWithOwner(t)
	srv := &Server{
		Pool:     pool,
		Sessions: &auth.Sessions{Pool: pool, TTL: time.Hour},
		Writers:  &auth.Writers{Pool: pool},
		Appender: &oplog.Appender{Pool: pool},
		Logf:     func(string, ...any) {},
		// Every case uploads as the same user: the limiters are not the subject.
		SyncPerUser:     NewLimiter(0, 1e6, 16, time.Now),
		SyncUploadBytes: NewLimiter(0, 1e12, 16, time.Now),
	}
	h := &harness{t: t, pool: pool, srv: srv, h: srv.Handler()}
	signHeads = false
	defer func() { signHeads = true }()

	dwk := ed25519.NewKeyFromSeed(file.DWKSeed)
	ran := 0
	for _, c := range file.Cases {
		if c.Upload == nil {
			continue
		}
		ran++
		u := file.UserID
		if _, err := owner.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(bg, `INSERT INTO users (id, user_handle, created_at, email_norm, email_verified_at, display_name) VALUES ($1, $2, now(), 'u-' || gen_random_uuid() || '@example.test', now(), 'Test User')`,
			u, oplogtest.Opaque(32)); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(bg, `INSERT INTO oplog_seq (user_id) VALUES ($1)`, u); err != nil {
			t.Fatal(err)
		}
		oplogtest.AddKeys(t, pool, u)
		if _, err := pool.Exec(bg,
			`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1, $2, 'ed25519', $3, $4, now())`,
			u, file.WriterID, []byte(dwk.Public().(ed25519.PublicKey)), oplogtest.DAK(t)); err != nil {
			t.Fatal(err)
		}
		frame1 := oplog.Row{WriterCounter: 1, Blob: file.Frame1, SizeBucket: len(file.Frame1),
			BlobHash: file.Frame1Hash, PrevHash: make([]byte, 32)}
		if _, err := h.srv.Appender.AppendClient(bg, u, file.WriterID, blob.StreamHot, []oplog.Row{frame1}, file.Frame1Sig); err != nil {
			t.Fatalf("%s: storing the anchor frame at counter 1: %v", c.ID, err)
		}
		// The epoch rose after counter 1 was written (T07's server epoch 2).
		if c.Upload.ServerEpoch != 1 {
			if _, err := pool.Exec(bg, `UPDATE account_keys SET current_epoch = $2 WHERE user_id = $1`, u, c.Upload.ServerEpoch); err != nil {
				t.Fatal(err)
			}
		}
		tok := h.session(u)
		h.bind(tok, file.WriterID)
		if c.Upload.WriterRevoked {
			if _, err := pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`, u, file.WriterID); err != nil {
				t.Fatal(err)
			}
		}
		up := c.Upload
		body := UploadRequest{WriterID: up.WriterID, Stream: up.Stream, Blobs: []UploadBlob{{
			WriterCounter: strconv.FormatInt(up.Row.Counter, 10),
			PrevHash:      hex.EncodeToString(up.Row.PrevHash),
			BlobHash:      hex.EncodeToString(up.Row.BlobHash),
			TypeFlag:      oplog.TypeFlagEdit,
			SizeBucket:    up.Row.SizeBucket,
			Blob:          base64.StdEncoding.EncodeToString(up.Row.Blob),
		}}}
		if up.HeadSig != nil {
			body.HeadSig = base64.StdEncoding.EncodeToString(up.HeadSig)
		}
		w := h.req("POST", "/api/v1/sync", tok, body)
		if w.Code != up.Verdict.Status {
			t.Errorf("%s %s: status %d, the vector says %d (body %s)", c.ID, c.Name, w.Code, up.Verdict.Status, w.Body)
			continue
		}
		if up.Verdict.Status == http.StatusOK {
			continue
		}
		e := decodeJSON[errorBody](t, w)
		if e.Error != up.Verdict.Error {
			t.Errorf("%s %s: error %q, the vector says %q", c.ID, c.Name, e.Error, up.Verdict.Error)
		}
		if up.Verdict.Check != "" && !strings.HasSuffix(e.Detail, ": "+up.Verdict.Check) {
			t.Errorf("%s %s: detail %q does not name check %q", c.ID, c.Name, e.Detail, up.Verdict.Check)
		}
	}
	if ran < 100 {
		t.Fatalf("only %d tamper uploads ran", ran)
	}
}
