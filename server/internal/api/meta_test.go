package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// Spec 02 §7 #2: unauthenticated, exactly the seven fields, gmail_watch_topic
// null unless the Pub/Sub push is configured and the Outlook URLs null unless
// the Graph push is (a mailbox link alone is not enough), log_generation 1
// when no file says otherwise.
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
		"rp_id":                    `"hasala.app"`,
		"min_ios_build":            `50`,
		"op_version_ceiling":       `4`,
		"gmail_watch_topic":        `null`,
		"outlook_notification_url": `null`,
		"outlook_lifecycle_url":    `null`,
		"log_generation":           `1`,
		"server_time":              `"2026-10-11T05:30:15Z"`,
	}
	if len(got) != len(want) {
		t.Fatalf("meta has %d fields, want %d: %s", len(got), len(want), w.Body.String())
	}
	for k, v := range want {
		if string(got[k]) != v {
			t.Errorf("%s = %s, want %s", k, got[k], v)
		}
	}

	// The mailbox link without the push: still no topic.
	h.srv.Gmail = &GmailOptions{IOSClientID: testClientID}
	if m := decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil)); m.GmailWatchTopic != nil {
		t.Fatalf("a link without the push offered the topic %q", *m.GmailWatchTopic)
	}
	h.srv.Meta = Meta{RPID: "hasala.app", LogGeneration: 3}
	h.srv.Gmail.Push = &GmailPush{Topic: "projects/p/topics/t"}
	m := decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil))
	if m.GmailWatchTopic == nil || *m.GmailWatchTopic != "projects/p/topics/t" || m.LogGeneration != 3 {
		t.Fatalf("meta = %+v", m)
	}
	if m.OutlookNotificationURL != nil || m.OutlookLifecycleURL != nil {
		t.Fatalf("meta offers Outlook URLs without the Graph push: %+v", m)
	}

	// The Outlook link without its push: no URLs; with it, both.
	h.srv.Outlook = &OutlookOptions{ClientID: testOutlookClient}
	if m := decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil)); m.OutlookNotificationURL != nil ||
		m.OutlookLifecycleURL != nil {
		t.Fatalf("an Outlook link without the push offered URLs: %+v", m)
	}
	h.srv.Outlook.Push = &OutlookPush{NotificationURL: testOutlookNotify, LifecycleURL: testOutlookLife}
	m = decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil))
	if m.OutlookNotificationURL == nil || *m.OutlookNotificationURL != testOutlookNotify ||
		m.OutlookLifecycleURL == nil || *m.OutlookLifecycleURL != testOutlookLife || m.GmailWatchTopic == nil {
		t.Fatalf("meta = %+v", m)
	}
	h.srv.Gmail = nil
	if m := decodeJSON[MetaResponse](t, h.req(http.MethodGet, "/api/v1/meta", "", nil)); m.GmailWatchTopic != nil ||
		m.OutlookNotificationURL == nil {
		t.Fatalf("Outlook alone: meta = %+v", m)
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
