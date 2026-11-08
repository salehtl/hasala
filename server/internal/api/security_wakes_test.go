package api

import (
	"crypto/ed25519"
	"crypto/sha256"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// wantSecurityWake checks a committed authenticator change's wakes (spec 02
// §9.3, §12.5): every device but the caller's writer, then exactly the
// signed-out sessions' tokens, collected before their rows went away.
func wantSecurityWake(t *testing.T, k *keyed, ws []wakeRec, except string, revoked ...string) {
	t.Helper()
	if len(ws) != 2 || !ws[0].others || ws[0].user != k.user || ws[0].writer != except || ws[0].r != pushv2.ReasonSecurity ||
		ws[1].r != pushv2.ReasonSecurity {
		t.Fatalf("wakes %+v, want the other devices and then the signed-out tokens", ws)
	}
	got := slices.Clone(ws[1].tokens)
	slices.Sort(got)
	slices.Sort(revoked)
	if !slices.Equal(got, revoked) {
		t.Fatalf("woke the tokens %v, want %v", got, revoked)
	}
}

// A password change signs every other session out and wakes those devices
// through their collected tokens; an in-app freeze does the same and also
// ends the caller's own session without waking it (review: no device signed
// out by an authenticator change was ever told).
func TestAuthenticatorChangesWakeTheSignedOutDevices(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	h.accounts()
	k := h.onboard(true)
	d2, d3 := authtest.NewDevice(t), authtest.NewDevice(t)
	tok2, tok3 := k.enrol(d2), k.enrol(d3)
	putToken(h, k.token, 1)
	t2, t3 := putToken(h, tok2, 2), putToken(h, tok3, 3)
	wk.take()

	// A refused change wakes nobody.
	s := authtest.RandBytesTB(t, 32)
	sh := sha256.Sum256(s)
	wantStatus(t, h.req("POST", "/api/v1/account/password", k.token, VerifierStepUpRequest{Verifier: b64(s)}),
		http.StatusForbidden)
	if ws := wk.take(); len(ws) != 0 {
		t.Fatalf("a refused password set woke %+v", ws)
	}
	// #56: the other two iPhones are signed out and woken; the caller is not.
	wantStatus(t, h.req("POST", "/api/v1/account/password", k.token, VerifierStepUpRequest{Verifier: b64(s),
		StepUp: k.stepUp(k.token, keyproto.ActionPasswordSet, sh[:])}), http.StatusNoContent)
	wantSecurityWake(t, k, wk.take(), k.device.WriterID, t2, t3)
	for _, tok := range []string{tok2, tok3} {
		wantStatus(t, h.req("GET", "/api/v1/account", tok, nil), http.StatusUnauthorized)
	}
	if h.countAPNs(k.user) != 1 {
		t.Fatal("the signed-out sessions kept their tokens")
	}

	// #65: every session ends, the caller's too, but only the others are woken.
	tok2 = h.session(k.user)
	h.bind(tok2, d2.WriterID)
	t2 = putToken(h, tok2, 4)
	wk.take()
	wantStatus(t, h.req("POST", "/api/v1/account/freeze/now", k.token,
		StepUpOnlyRequest{StepUp: k.stepUp(k.token, keyproto.ActionAccountFreeze)}), http.StatusNoContent)
	wantSecurityWake(t, k, wk.take(), k.device.WriterID, t2)
	for _, tok := range []string{k.token, tok2} {
		wantStatus(t, h.req("GET", "/api/v1/account", tok, nil), http.StatusUnauthorized)
	}
	if h.countAPNs(k.user) != 0 {
		t.Fatal("a freeze left APNs tokens")
	}
	var reasons []string
	rows, err := h.pool.Query(bg, `SELECT DISTINCT revoked_reason FROM sessions WHERE user_id = $1`, k.user)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var r string
		if err := rows.Scan(&r); err != nil {
			t.Fatal(err)
		}
		reasons = append(reasons, r)
	}
	rows.Close()
	if !slices.Equal(reasons, []string{"others"}) {
		t.Fatalf("revocation reasons %v, want only 'others' (spec 02 §9.3)", reasons)
	}
}

func TestALogoutAllWakesATokenRegisteredAfterTheRequestBegan(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	putToken(h, k.token, 1)
	wk.take()

	su := k.stepUp(k.token, keyproto.ActionSessionLogoutAll)
	var late string
	h.srv.StepUp.Now = func() time.Time {
		if late == "" {
			late = tokenHexFor(2)
			putToken(h, tok2, 2)
		}
		return time.Now()
	}
	wantStatus(t, h.req("POST", "/api/v1/auth/logout-all", k.token, StepUpOnlyRequest{StepUp: su}), http.StatusNoContent)
	if h.countAPNs(k.user) != 0 {
		t.Fatal("logout-all left tokens")
	}
	ws := wk.take()
	if len(ws) != 1 || !slices.Equal(ws[0].tokens, []string{late}) || ws[0].r != pushv2.ReasonSecurity {
		t.Fatalf("logout-all wakes %+v, want the token registered during the request", ws)
	}
}

func holdAPNsToken(h *harness, tokenHex string) (release func()) {
	h.t.Helper()
	tx, err := pgtx.BeginReadCommitted(bg, h.pool)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { pgtx.Rollback(bg, tx) })
	if _, err := tx.Exec(bg, `SELECT 1 FROM apns_tokens WHERE token_hex = $1 FOR UPDATE`, tokenHex); err != nil {
		h.t.Fatal(err)
	}
	return func() {
		if err := tx.Commit(bg); err != nil {
			h.t.Fatal(err)
		}
	}
}

func waitForALockedRequest(h *harness) {
	h.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := h.pool.QueryRow(bg,
			`SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()`).Scan(&n); err != nil {
			h.t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.t.Fatal("the request never waited on the held token")
}

func logoutAllInBackground(h *harness, k *keyed) <-chan *httptest.ResponseRecorder {
	h.t.Helper()
	su := k.stepUp(k.token, keyproto.ActionSessionLogoutAll)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- h.req("POST", "/api/v1/auth/logout-all", k.token, StepUpOnlyRequest{StepUp: su}) }()
	return done
}

func TestALogoutAllWakesATokenRegisteredWhileItsDeletesRun(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	own := putToken(h, k.token, 1)
	wk.take()

	release := holdAPNsToken(h, own)
	done := logoutAllInBackground(h, k)
	waitForALockedRequest(h)
	late := putToken(h, tok2, 2)
	release()
	wantStatus(t, <-done, http.StatusNoContent)

	if n := h.countAPNs(k.user); n != 0 {
		t.Fatalf("logout-all left %d tokens", n)
	}
	ws := wk.take()
	if len(ws) != 1 || !slices.Equal(ws[0].tokens, []string{late}) || ws[0].r != pushv2.ReasonSecurity {
		t.Fatalf("logout-all wakes %+v, want only the token registered while it ran", ws)
	}
}

func TestALogoutAllNeverWakesItsOwnDeviceRegisteringWhileItRuns(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	other := putToken(h, tok2, 2)
	wk.take()

	release := holdAPNsToken(h, other)
	done := logoutAllInBackground(h, k)
	waitForALockedRequest(h)
	putToken(h, k.token, 1)
	release()
	wantStatus(t, <-done, http.StatusNoContent)

	if n := h.countAPNs(k.user); n != 0 {
		t.Fatalf("logout-all left %d tokens", n)
	}
	ws := wk.take()
	if len(ws) != 1 || !slices.Equal(ws[0].tokens, []string{other}) {
		t.Fatalf("logout-all wakes %+v, want the other device only", ws)
	}
}

func TestRevokingADeviceWakesATokenRegisteredAfterTheRequestBegan(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	d2 := authtest.NewDevice(t)
	tok2 := k.enrol(d2)
	putToken(h, k.token, 1)
	wk.take()

	su := k.stepUp(k.token, keyproto.ActionWriterRevoke, []byte(d2.WriterID))
	n := k.nonce(k.token)
	rm, _ := keyproto.RevocationMessage(n, d2.WriterID, 0, make([]byte, 32))
	var late string
	h.srv.Writers.Now = func() time.Time {
		if late == "" {
			late = tokenHexFor(2)
			putToken(h, tok2, 2)
		}
		return time.Now()
	}
	wantStatus(t, h.req("POST", "/api/v1/writers/revoke", k.token, RevokeRequest{WriterID: d2.WriterID,
		SignerWriterID: k.device.WriterID, Nonce: b64(n), FinalCounter: "0", FinalHead: b64(make([]byte, 32)),
		Sig: b64(ed25519.Sign(k.device.DWK, rm)), StepUp: su}), http.StatusNoContent)
	if h.countAPNs(k.user) != 1 {
		t.Fatal("the revoked writer's token survived")
	}
	ws := wk.take()
	if len(ws) != 2 || !ws[0].others || ws[0].writer != k.device.WriterID || !slices.Equal(ws[1].tokens, []string{late}) {
		t.Fatalf("revoke wakes %+v, want the others and the token registered during the request", ws)
	}
}

func TestRemovingThisDeviceDoesNotWakeItsOwnToken(t *testing.T) {
	h := newHarness(t).passkeys()
	wk, _ := withPushAndGmail(h)
	k := h.onboard(true)
	putToken(h, k.token, 1)
	wk.take()

	su := k.stepUp(k.token, keyproto.ActionWriterRevoke, []byte(k.device.WriterID))
	n := k.nonce(k.token)
	rm, _ := keyproto.RevocationMessage(n, k.device.WriterID, 0, make([]byte, 32))
	wantStatus(t, h.req("POST", "/api/v1/writers/revoke", k.token, RevokeRequest{WriterID: k.device.WriterID,
		SignerWriterID: k.device.WriterID, Nonce: b64(n), FinalCounter: "0", FinalHead: b64(make([]byte, 32)),
		Sig: b64(ed25519.Sign(k.device.DWK, rm)), StepUp: su}), http.StatusNoContent)
	ws := wk.take()
	if len(ws) != 1 || !ws[0].others || ws[0].writer != k.device.WriterID {
		t.Fatalf("removing this device wakes %+v, want only the others", ws)
	}
}
