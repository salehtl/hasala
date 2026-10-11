package api

import (
	"crypto/sha256"
	"net/http"
	"slices"
	"testing"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
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
