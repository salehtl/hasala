package api

import (
	"net/http"
	"testing"
)

func TestLinkingAgainForgetsTheLastWake(t *testing.T) {
	h := newHarness(t).passkeys()
	withPushAndGmail(h)
	k := h.onboard(true)
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	if _, err := h.pool.Exec(bg, `UPDATE mailbox_links SET last_wake_hour = date_trunc('hour', now()) WHERE user_id = $1`,
		k.user); err != nil {
		t.Fatal(err)
	}
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.LastWakeHour == nil {
		t.Fatal("the first link reports no wake")
	}
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.LastWakeHour != nil {
		t.Fatalf("the new link reports the old link's wake: %v", st.LastWakeHour)
	}
}
