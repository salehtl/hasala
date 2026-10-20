package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/salehtl/hasala/server/internal/auth"
)

func TestABoundWriterCheckThatCannotReadTheRosterIsNotAnUnbind(t *testing.T) {
	h := newHarness(t)
	u := h.user("bound-check")
	h.writer(u, "ios-00000000-0000-4000-8000-00000000000a")
	info := auth.SessionInfo{UserID: u, WriterID: "ios-00000000-0000-4000-8000-00000000000a"}

	w := httptest.NewRecorder()
	if !h.srv.requireBound(w, httptest.NewRequest("POST", "/api/v1/sync", nil), info) {
		t.Fatalf("a live writer: %d %s", w.Code, w.Body)
	}

	gone := auth.SessionInfo{UserID: u, WriterID: "ios-00000000-0000-4000-8000-0000000000ff"}
	w = httptest.NewRecorder()
	if h.srv.requireBound(w, httptest.NewRequest("POST", "/api/v1/sync", nil), gone) {
		t.Fatal("a writer that is not on the roster passed")
	}
	wantError(t, w, "writer_unbound")

	ctx, cancel := context.WithCancel(bg)
	cancel()
	w = httptest.NewRecorder()
	if h.srv.requireBound(w, httptest.NewRequest("POST", "/api/v1/sync", nil).WithContext(ctx), info) {
		t.Fatal("a failed roster read passed")
	}
	wantStatus(t, w, http.StatusInternalServerError)
}
