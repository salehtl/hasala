package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// Spec 02 §7 #2: unauthenticated, exactly the five fields, gmail_watch_topic
// null while the mailbox-link routes are not mounted, log_generation 1 when
// no file says otherwise.
func TestMetaReportsTheServersPublicFacts(t *testing.T) {
	h := newHarness(t)
	h.srv.Now = func() time.Time { return time.Date(2026, 10, 11, 9, 30, 15, 999, time.FixedZone("GST", 4*3600)) }
	h.srv.Meta = Meta{RPID: "hasala.app", MinIOSBuild: 50}

	w := h.req(http.MethodGet, "/api/v1/meta", "", nil)
	wantStatus(t, w, http.StatusOK)
	var got map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"rp_id":             `"hasala.app"`,
		"min_ios_build":     `50`,
		"gmail_watch_topic": `null`,
		"log_generation":    `1`,
		"server_time":       `"2026-10-11T05:30:15Z"`,
	}
	if len(got) != len(want) {
		t.Fatalf("meta has %d fields, want %d: %s", len(got), len(want), w.Body.String())
	}
	for k, v := range want {
		if string(got[k]) != v {
			t.Errorf("%s = %s, want %s", k, got[k], v)
		}
	}

	h.srv.Meta = Meta{RPID: "hasala.app", GmailWatchTopic: "projects/p/topics/t", LogGeneration: 3}
	m := decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil))
	if m.GmailWatchTopic == nil || *m.GmailWatchTopic != "projects/p/topics/t" || m.LogGeneration != 3 {
		t.Fatalf("meta = %+v", m)
	}
	if w := h.req(http.MethodPost, "/api/v1/meta", "", nil); w.Code == http.StatusOK {
		t.Fatal("POST /api/v1/meta was served")
	}
}

// meta-ip: 1/s per client, burst 20.
func TestMetaIsRateLimitedPerClient(t *testing.T) {
	h := newHarness(t)
	h.srv.MetaPerIP = NewLimiter(0, 2, metaMaxKeys, h.srv.now)
	for i := 0; i < 2; i++ {
		wantStatus(t, h.req(http.MethodGet, "/api/v1/meta", "", nil), http.StatusOK)
	}
	w := h.req(http.MethodGet, "/api/v1/meta", "", nil)
	wantStatus(t, w, http.StatusTooManyRequests)
	if got := decodeJSON[errorBody](t, w).Error; got != "rate_limited" {
		t.Fatalf("error = %q, want rate_limited", got)
	}
}
