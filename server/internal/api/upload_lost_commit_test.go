package api

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type lostAnswers struct {
	mu    sync.Mutex
	query []byte
}

func (l *lostAnswers) loseNext(statement string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.query = []byte(statement + "\x00")
}

func (l *lostAnswers) take(p []byte) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.query == nil || len(p) < 5 || p[0] != 'Q' || !bytes.Equal(p[5:], l.query) {
		return false
	}
	l.query = nil
	return true
}

type answerLosingConn struct {
	net.Conn
	lost    *lostAnswers
	dropped atomic.Bool
}

func (c *answerLosingConn) Write(p []byte) (int, error) {
	if c.lost.take(p) {
		c.dropped.Store(true)
	}
	return c.Conn.Write(p)
}

func (c *answerLosingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if err == nil && c.dropped.Load() {
		_ = c.Conn.Close()
		return 0, io.ErrUnexpectedEOF
	}
	return n, err
}

func answerLosingAppender(t *testing.T, h *harness) (*oplog.Appender, *lostAnswers) {
	t.Helper()
	cfg := h.pool.Config()
	lost := &lostAnswers{}
	cfg.ConnConfig.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := (&net.Dialer{}).DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		return &answerLosingConn{Conn: conn, lost: lost}, nil
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return &oplog.Appender{Pool: pool}, lost
}

type lostCommitFixture struct {
	h      *harness
	waker  *recWaker
	lost   *lostAnswers
	first  []UploadBlob
	second []UploadBlob
	third  []UploadBlob
	upload func(blobs []UploadBlob) *httptest.ResponseRecorder
	rows   func() int
}

func newLostCommitFixture(t *testing.T) *lostCommitFixture {
	t.Helper()
	h := newHarness(t)
	waker, _ := withPushAndGmail(h)
	u := h.user("lost-commit")
	tok := h.session(u)
	const writer = "ios-00000000-0000-4000-8000-000000000302"
	h.writer(u, writer)

	first, head := uploadChain(t, u, writer, 1, blob.ZeroHash, 1)
	second, head2 := uploadChain(t, u, writer, 2, head, 1)
	third, _ := uploadChain(t, u, writer, 3, head2, 1)
	size := first[0].SizeBucket
	if second[0].SizeBucket != size || third[0].SizeBucket != size {
		t.Fatalf("blob sizes differ: %d, %d, %d", size, second[0].SizeBucket, third[0].SizeBucket)
	}

	appender, lost := answerLosingAppender(t, h)
	h.srv.Appender = appender
	h.srv.SyncPerUser = NewLimiter(0, 1000, 16, h.srv.now)
	h.srv.SyncUploadBytes = NewLimiter(0, float64(2*size), 16, h.srv.now)
	h.h = h.srv.Handler()
	return &lostCommitFixture{
		h: h, waker: waker, lost: lost, first: first, second: second, third: third,
		upload: func(blobs []UploadBlob) *httptest.ResponseRecorder {
			return h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{WriterID: writer, Stream: blob.StreamHot, Blobs: blobs})
		},
		rows: func() int { return countRows(t, h.pool, u) },
	}
}

func TestAnUploadWhoseCommitAnswerIsLostStaysCharged(t *testing.T) {
	f := newLostCommitFixture(t)

	f.lost.loseNext("commit")
	wantStatus(t, f.upload(f.first), http.StatusInternalServerError)
	if n := f.rows(); n != 1 {
		t.Fatalf("%d rows after the lost answer, want the committed row", n)
	}
	if got := f.waker.take(); len(got) != 0 {
		t.Fatalf("wakes %+v after a failed answer, want none", got)
	}

	wantStatus(t, f.upload(f.first), http.StatusOK)
	if n := f.rows(); n != 1 {
		t.Fatalf("%d rows after the retry, want 1", n)
	}
	if got := f.waker.take(); len(got) != 1 || !got[0].others || got[0].r != pushv2.ReasonSync {
		t.Fatalf("wakes %+v after the retry, want the one sync wake those rows ever get", got)
	}

	wantStatus(t, f.upload(f.second), http.StatusOK)
	w := f.upload(f.third)
	wantStatus(t, w, http.StatusTooManyRequests)
	wantError(t, w, "upload_bytes")
	if n := f.rows(); n != 2 {
		t.Fatalf("%d rows stored, want 2", n)
	}
}

func TestAnUploadLostBeforeItsCommitCostsNoByteBudget(t *testing.T) {
	f := newLostCommitFixture(t)

	f.lost.loseNext("begin isolation level read committed")
	wantStatus(t, f.upload(f.first), http.StatusInternalServerError)
	if n := f.rows(); n != 0 {
		t.Fatalf("%d rows after a lost begin, want 0", n)
	}

	wantStatus(t, f.upload(f.first), http.StatusOK)
	wantStatus(t, f.upload(f.second), http.StatusOK)
	w := f.upload(f.third)
	wantStatus(t, w, http.StatusTooManyRequests)
	wantError(t, w, "upload_bytes")
}
