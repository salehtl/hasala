package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/blob"
)

func TestAnUploadPastTheGateIsRefusedByAFreezeThatCommitsFirst(t *testing.T) {
	h := newHarness(t)
	u := h.user("freeze-race")
	tok := h.session(u)
	const writer = "ios-00000000-0000-4000-8000-000000000303"
	h.writer(u, writer)
	blobs, _ := uploadChain(t, u, writer, 1, blob.ZeroHash, 1)
	h.srv.SyncPerUser = NewLimiter(0, 1000, 16, h.srv.now)
	h.srv.SyncUploadBytes = NewLimiter(0, float64(blobs[0].SizeBucket), 16, h.srv.now)
	h.h = h.srv.Handler()
	upload := func() *httptest.ResponseRecorder {
		return h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{WriterID: writer, Stream: blob.StreamHot, Blobs: blobs})
	}

	freeze, err := h.pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = freeze.Rollback(bg) }()
	if _, err := freeze.Exec(bg, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, u); err != nil {
		t.Fatal(err)
	}

	answered := make(chan *httptest.ResponseRecorder, 1)
	go func() { answered <- upload() }()

	deadline := time.Now().Add(30 * time.Second)
	for {
		var waiting int
		if err := h.pool.QueryRow(bg,
			`SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the upload never reached the account row")
		}
		time.Sleep(5 * time.Millisecond)
	}

	if _, err := freeze.Exec(bg,
		`UPDATE users SET frozen_at = now(), freeze_trigger_at = now(), frozen_by = 'holder' WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := freeze.Commit(bg); err != nil {
		t.Fatal(err)
	}

	w := <-answered
	wantStatus(t, w, http.StatusForbidden)
	wantError(t, w, "account_frozen")
	if n := countRows(t, h.pool, u); n != 0 {
		t.Fatalf("%d rows landed after the freeze committed", n)
	}

	if _, err := h.pool.Exec(bg,
		`UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	wantStatus(t, upload(), http.StatusOK)
}
