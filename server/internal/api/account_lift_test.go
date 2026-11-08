package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/authtest"
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

func TestHolderCanLiftAnswersForTheCallingDevice(t *testing.T) {
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")

	newer := authtest.NewDevice(t)
	if _, err := h.pool.Exec(bg, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
	        VALUES ($1, $2, 'ed25519', $3, $4, now() + interval '2 hours')`, a.user, newer.WriterID, newer.DWKPub(), newer.DAKPub()); err != nil {
		t.Fatal(err)
	}
	newerToken := h.session(mustUUID(t, a.user))
	h.bind(newerToken, newer.WriterID)
	unbound := h.session(mustUUID(t, a.user))

	h.freezeAt(t, a.user, "holder", time.Now().Add(time.Hour))
	if got := h.holderCanLift(t, a.token); got == nil || !*got {
		t.Fatalf("the device older than the trigger: holder_can_lift %v", got)
	}
	if got := h.holderCanLift(t, newerToken); got == nil || *got {
		t.Fatalf("a device newer than the trigger, with an older device on the account: holder_can_lift %v", got)
	}
	if got := h.holderCanLift(t, unbound); got == nil || *got {
		t.Fatalf("a session with no device on a password-only account: holder_can_lift %v", got)
	}
}
