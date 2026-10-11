package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
)

// Security finding F4: a sign-out that leaves the session valid on the server
// is not a sign-out (spec 02 §9.3).

// apnsToken registers an APNs token for the writer under the session, as
// WS-4's PUT /api/v1/push/apns will.
func (h *harness) apnsToken(u uuid.UUID, writerID, session string) {
	h.t.Helper()
	sum := sha256.Sum256([]byte(session + writerID))
	if _, err := h.pool.Exec(bg, `INSERT INTO apns_tokens
		(user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 'sandbox', now(), now())`,
		u, writerID, auth.SessionHash(session), hex.EncodeToString(sum[:])); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) countAPNs(u uuid.UUID) int {
	h.t.Helper()
	var n int
	if err := h.pool.QueryRow(bg, `SELECT count(*) FROM apns_tokens WHERE user_id = $1`, u).Scan(&n); err != nil {
		h.t.Fatal(err)
	}
	return n
}

func TestLogoutRevokesThePresentedSessionOnTheServer(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	phone, laptop := h.session(u), h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-000000000301")
	oplogtest.NewWriter(t, h.pool, u, "ios-00000000-0000-4000-8000-000000000302")
	h.apnsToken(u, "ios-00000000-0000-4000-8000-000000000301", phone)
	h.apnsToken(u, "ios-00000000-0000-4000-8000-000000000302", laptop)

	wantStatus(t, h.req("POST", "/api/v1/auth/logout", phone, nil), http.StatusNoContent)

	// The token is dead everywhere, not just forgotten by the client.
	wantStatus(t, h.req("GET", "/api/v1/writers", phone, nil), http.StatusUnauthorized)
	// The other session, and its device's notifications, are untouched.
	wantStatus(t, h.req("GET", "/api/v1/writers", laptop, nil), http.StatusOK)
	if n := h.countAPNs(u); n != 1 {
		t.Fatalf("%d APNs tokens after one device signed out, want the other device's 1", n)
	}
	// Idempotent from the client's side: a second call is a 401, which the
	// client treats exactly like the 204.
	wantStatus(t, h.req("POST", "/api/v1/auth/logout", phone, nil), http.StatusUnauthorized)
}

func TestLogoutTakesNoBodyOrAnEmptyObject(t *testing.T) {
	h := newHarness(t)
	u := h.user("u")
	wantStatus(t, h.req("POST", "/api/v1/auth/logout", h.session(u), nil), http.StatusNoContent)
	wantStatus(t, h.req("POST", "/api/v1/auth/logout", h.session(u), map[string]any{}), http.StatusNoContent)
	wantStatus(t, h.req("POST", "/api/v1/auth/logout", h.session(u), map[string]any{"user_id": "x"}), http.StatusBadRequest)
}

func TestLogoutWithoutAValidSessionIsTheOne401(t *testing.T) {
	h := newHarness(t)
	for _, tok := range []string{"", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"} {
		w := h.req("POST", "/api/v1/auth/logout", tok, nil)
		wantStatus(t, w, http.StatusUnauthorized)
		if got := w.Body.String(); got != `{"error":"unauthorized"}` {
			t.Fatalf("body = %s, want the one 401 this package emits", got)
		}
	}
}

func TestLogoutAllRevokesEverySessionAndEveryPushTokenButNoWriter(t *testing.T) {
	h := newHarness(t)
	u, other := h.user("u"), h.user("other")
	a, b, c := h.session(u), h.session(u), h.session(u)
	otherTok := h.session(other)
	h.writer(u, "ios-00000000-0000-4000-8000-000000000301")
	oplogtest.NewWriter(t, h.pool, u, "ios-00000000-0000-4000-8000-000000000302")
	h.writer(other, "ios-00000000-0000-4000-8000-000000000303")
	h.apnsToken(u, "ios-00000000-0000-4000-8000-000000000301", a)
	h.apnsToken(u, "ios-00000000-0000-4000-8000-000000000302", b)
	h.apnsToken(other, "ios-00000000-0000-4000-8000-000000000303", otherTok)

	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", c, nil), http.StatusNoContent)

	for i, tok := range []string{a, b, c} {
		if w := h.req("GET", "/api/v1/writers", tok, nil); w.Code != http.StatusUnauthorized {
			t.Fatalf("session %d survived sign-out-everywhere: %d", i, w.Code)
		}
	}
	if n := h.countAPNs(u); n != 0 {
		t.Fatalf("%d APNs tokens survived sign-out-everywhere", n)
	}
	// The devices keep their keys: they sign in again and keep writing.
	roster, err := h.srv.Writers.Roster(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range roster {
		if !w.Live() {
			t.Fatalf("writer %s was revoked by a sign-out", w.WriterID)
		}
	}
	// Another account is untouched.
	wantStatus(t, h.req("GET", "/api/v1/writers", otherTok, nil), http.StatusOK)
	if n := h.countAPNs(other); n != 1 {
		t.Fatalf("another account lost its push token: %d", n)
	}
}

func TestLogoutAllNeedsASession(t *testing.T) {
	h := newHarness(t)
	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", "", nil), http.StatusUnauthorized)
}
