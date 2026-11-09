package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
)

func (h *harness) freezeAt(t *testing.T, user any, by string, trigger time.Time) {
	t.Helper()
	if _, err := h.pool.Exec(bg, `UPDATE users SET frozen_at = greatest(now(), $2), freeze_trigger_at = $2, frozen_by = $3 WHERE id = $1`,
		user, trigger, by); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) holderCanLift(t *testing.T, token string) *bool {
	t.Helper()
	w := h.req("GET", "/api/v1/account", token, nil)
	wantStatus(t, w, http.StatusOK)
	return decodeJSON[AccountResponse](t, w).HolderCanLift
}

func TestHolderCanLiftFollowsTheFactorsOlderThanTheFreeze(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	if got := h.holderCanLift(t, k.token); got != nil {
		t.Fatalf("an account that is not frozen reports holder_can_lift %v", *got)
	}

	h.freezeAt(t, k.user, "holder", time.Now().Add(time.Hour))
	if got := h.holderCanLift(t, k.token); got == nil || !*got {
		t.Fatalf("a passkey older than the trigger: holder_can_lift %v", got)
	}

	h.freezeAt(t, k.user, "holder", time.Now().Add(-24*time.Hour))
	if got := h.holderCanLift(t, k.token); got == nil || *got {
		t.Fatalf("no factor older than the trigger: holder_can_lift %v", got)
	}

	h.freezeAt(t, k.user, "operator", time.Now().Add(time.Hour))
	if got := h.holderCanLift(t, k.token); got == nil || *got {
		t.Fatalf("an operator freeze: holder_can_lift %v", got)
	}
}

func TestHolderCanLiftWithAnOlderDeviceAndPassword(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")

	h.freezeAt(t, a.user, "holder", time.Now().Add(time.Hour))
	if got := h.holderCanLift(t, a.token); got == nil || !*got {
		t.Fatalf("a device and a password older than the trigger: holder_can_lift %v", got)
	}

	if _, err := h.pool.Exec(bg, `UPDATE users SET password_set_at = now() + interval '2 hours' WHERE id = $1`, a.user); err != nil {
		t.Fatal(err)
	}
	if got := h.holderCanLift(t, a.token); got == nil || *got {
		t.Fatalf("a password newer than the trigger: holder_can_lift %v", got)
	}

	if _, err := h.pool.Exec(bg, `UPDATE users SET password_set_at = now() - interval '1 day' WHERE id = $1`, a.user); err != nil {
		t.Fatal(err)
	}
	h.freezeAt(t, a.user, "holder", time.Now().Add(-time.Minute))
	if got := h.holderCanLift(t, a.token); got == nil || *got {
		t.Fatalf("a device newer than the trigger: holder_can_lift %v", got)
	}
}

func TestHolderCanLiftAsksAboutThisSessionsOwnDevice(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")

	user := uuid.MustParse(a.user)
	time.Sleep(5 * time.Millisecond)
	trigger := time.Now()
	time.Sleep(5 * time.Millisecond)
	newer := "ios-71111111-1111-4111-8111-111111111111"
	h.writer(user, newer)
	onNewer := h.session(user)
	h.bind(onNewer, newer)
	unbound := h.session(user)

	h.freezeAt(t, user, "holder", trigger)
	if got := h.holderCanLift(t, a.token); got == nil || !*got {
		t.Fatalf("a session on a device older than the trigger: holder_can_lift %v", got)
	}
	if got := h.holderCanLift(t, onNewer); got == nil || *got {
		t.Fatalf("a session on a device newer than the trigger: holder_can_lift %v", got)
	}
	if got := h.holderCanLift(t, unbound); got == nil || *got {
		t.Fatalf("a session with no device: holder_can_lift %v", got)
	}

	older := h.sessionWriter(t, a.token)
	if _, err := h.pool.Exec(bg, `UPDATE writers SET revoked_at = now() WHERE user_id = $1 AND writer_id = $2`, a.user, older); err != nil {
		t.Fatal(err)
	}
	if got := h.holderCanLift(t, a.token); got == nil || *got {
		t.Fatalf("a session on a revoked device: holder_can_lift %v", got)
	}
}

func (h *harness) sessionWriter(t *testing.T, token string) string {
	t.Helper()
	var id string
	if err := h.pool.QueryRow(bg, `SELECT writer_id FROM sessions WHERE token_hash = $1`, auth.SessionHash(token)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}
