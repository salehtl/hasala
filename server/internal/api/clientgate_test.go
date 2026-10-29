package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClientGateRefusesOlderIOSBuilds(t *testing.T) {
	h := newHarness(t)
	h.srv.Meta = Meta{RPID: "hasala.app", MinIOSBuild: 26102911530}

	send := func(method, path, client string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if client != "" {
			r.Header.Set("Hasala-Client", client)
		}
		w := httptest.NewRecorder()
		h.h.ServeHTTP(w, r)
		return w
	}

	for _, c := range []struct {
		method, path, client string
		want                 int
	}{
		{http.MethodGet, "/api/v1/sync", "ios/0.3.0/261028.12359", http.StatusUpgradeRequired},
		{http.MethodPost, "/api/v1/auth/passkey/login/begin", "ios/0.3.0/261028.12359", http.StatusUpgradeRequired},
		{http.MethodGet, "/api/v1/sync", "ios/0.1.0/1", http.StatusUpgradeRequired},
		{http.MethodGet, "/api/v1/sync", "ios/0.3.1/261029.11530", http.StatusUnauthorized},
		{http.MethodGet, "/api/v1/sync", "ios/0.3.1/261101.10900", http.StatusUnauthorized},
		{http.MethodGet, "/api/v1/sync", "", http.StatusUnauthorized},
		{http.MethodGet, "/api/v1/sync", "web/1/2", http.StatusUnauthorized},
		{http.MethodGet, "/api/v1/sync", "ios/0.3.0/abc", http.StatusUnauthorized},
		{http.MethodGet, "/api/v1/meta", "ios/0.3.0/261028.12359", http.StatusOK},
		{http.MethodGet, "/api/v1/healthz", "ios/0.3.0/261028.12359", http.StatusOK},
	} {
		w := send(c.method, c.path, c.client)
		if w.Code != c.want {
			t.Errorf("%s %s with %q = %d, want %d: %s", c.method, c.path, c.client, w.Code, c.want, w.Body.String())
		}
		if c.want == http.StatusUpgradeRequired {
			if e := decodeJSON[errorBody](t, w); e.Error != "upgrade_required" {
				t.Errorf("%s %s: error = %q", c.method, c.path, e.Error)
			}
		}
	}

	h.srv.Meta.MinIOSBuild = 0
	if w := send(http.MethodGet, "/api/v1/sync", "ios/0.1.0/1"); w.Code != http.StatusUnauthorized {
		t.Fatalf("with no minimum, an old build got %d", w.Code)
	}
}
