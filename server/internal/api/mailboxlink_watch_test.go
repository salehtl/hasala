package api

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
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

func watchReportBehind(t *testing.T, h *harness, k *keyed, sql string, args ...any) *httptest.ResponseRecorder {
	t.Helper()
	tx, err := h.pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(bg) }()
	if _, err := tx.Exec(bg, sql, args...); err != nil {
		t.Fatal(err)
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: time.Now().Add(3 * 24 * time.Hour)})
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting int
		if err := h.pool.QueryRow(bg, `SELECT count(*) FROM pg_stat_activity
		    WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE 'UPDATE mailbox_links SET watch_expires_at%'`).
			Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the watch report never reached the row")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	select {
	case w := <-done:
		return w
	case <-time.After(10 * time.Second):
		t.Fatal("the watch report did not finish")
		return nil
	}
}

func wantNoLinkAnswer(t *testing.T, w *httptest.ResponseRecorder) {
	t.Helper()
	if w.Code != http.StatusNotFound || decodeJSON[errorBody](t, w).Error != "no_link" {
		t.Fatalf("watch report: %d %s, want 404 no_link", w.Code, w.Body)
	}
}

func TestAWatchReportCaughtByAnUnlinkIsNotAcknowledged(t *testing.T) {
	h := newHarness(t).passkeys()
	withPushAndGmail(h)
	k := h.onboard(true)
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	wantNoLinkAnswer(t, watchReportBehind(t, h, k, `DELETE FROM mailbox_links WHERE user_id = $1`, k.user))
}

func TestAWatchReportDoesNotReachTheLinkThatReplacedItsOwn(t *testing.T) {
	h := newHarness(t).passkeys()
	withPushAndGmail(h)
	k := h.onboard(true)
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	wantNoLinkAnswer(t, watchReportBehind(t, h, k,
		`UPDATE mailbox_links SET address_hmac = $2, created_at = now() + interval '1 second', updated_at = now(),
		        watch_expires_at = NULL, last_nudge_at = NULL WHERE user_id = $1`, k.user, bytes.Repeat([]byte{9}, 32)))
	if st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil)); st.WatchExpiresAt != nil {
		t.Fatalf("the new link took the old link's watch: %v", st.WatchExpiresAt)
	}
}

func TestAWatchReportNeverMovesTheExpiryBack(t *testing.T) {
	h := newHarness(t).passkeys()
	withPushAndGmail(h)
	k := h.onboard(true)
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	base := time.Now().Add(time.Hour).Truncate(time.Second)
	report := func(at time.Time) {
		t.Helper()
		wantStatus(t, h.req("PUT", "/api/v1/mailbox/link/watch", k.token, LinkWatchRequest{ExpiresAt: at}), http.StatusNoContent)
	}
	wantWatch := func(at time.Time) {
		t.Helper()
		st := decodeJSON[LinkStatusResponse](t, h.req("GET", "/api/v1/mailbox/link", k.token, nil))
		if st.WatchExpiresAt == nil || !st.WatchExpiresAt.Equal(at) {
			t.Fatalf("watch %v, want %v", st.WatchExpiresAt, at)
		}
	}
	later, earlier, latest := base.Add(5*24*time.Hour), base.Add(2*24*time.Hour), base.Add(6*24*time.Hour)
	report(later)
	report(earlier)
	wantWatch(later)
	report(latest)
	wantWatch(latest)
	wantStatus(t, link(k, k.token, fakeToken(goodClaims(linkChallenge(h, k.token)))), http.StatusOK)
	report(earlier)
	wantWatch(earlier)
}
