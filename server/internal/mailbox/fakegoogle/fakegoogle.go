// Package fakegoogle is an httptest-mountable stand-in for Google's OAuth
// token and revoke endpoints, in internal/authtest's spirit: scriptable
// knobs as struct fields, deliberately obedient rather than trying to
// re-verify what a caller already got right (nothing here checks a PKCE
// verifier against a challenge, or a client secret against a real client —
// that is Google's job in production and go-webauthn's-equivalent job is
// not this package's to redo).
//
// It exists because three different layers need the identical fake rather
// than three approximations of one: internal/mailbox's own tests
// (Google.Exchange/Refresh/Revoke), Task 4's API tests, and Task 16's
// harness (--gmail-fixtures). Exported for exactly those three, and
// production code must never import it.
//
// It is test-only and is imported by no production code.
package fakegoogle

import (
	"encoding/json"
	"net/http"
	"net/url"
	"sync"
)

// Defaults returned by /token when a test has not scripted otherwise.
const (
	DefaultRefreshToken = "fake-refresh-token"
	DefaultAccessToken  = "fake-access-token"
	DefaultIDToken      = "fake-id-token"
	DefaultExpiresIn    = 3600
)

// Server is a scriptable fake of Google's token and revoke endpoints. Every
// exported field may be set before mounting or mutated between requests
// within a test (guarded internally, so concurrent requests from a client
// under test are safe); there is no separate "start" step beyond mounting
// ServeHTTP behind an httptest.Server.
type Server struct {
	// RefreshToken, AccessToken, IDToken, ExpiresIn are what /token returns
	// on success, for both the authorization_code and refresh_token grants.
	// New populates realistic-looking defaults so a test that never touches
	// a knob still gets a token back.
	RefreshToken string
	AccessToken  string
	IDToken      string
	ExpiresIn    int

	// InvalidGrant makes /token AND /revoke answer 400
	// {"error":"invalid_grant"} instead of succeeding, regardless of grant
	// type — D10's simulation of a Testing-status refresh token that has
	// expired or been revoked at Google.
	InvalidGrant bool

	mu sync.Mutex
	// TokenRequests records every form /token received, in the order
	// received, so a test can assert what Exchange or Refresh actually
	// posted (the client secret, the PKCE verifier, the grant type) without
	// a packet capture.
	TokenRequests []url.Values
	// RevokeRequests records every form /revoke received.
	RevokeRequests []url.Values
}

// New returns a Server with realistic-looking defaults.
func New() *Server {
	return &Server{
		RefreshToken: DefaultRefreshToken,
		AccessToken:  DefaultAccessToken,
		IDToken:      DefaultIDToken,
		ExpiresIn:    DefaultExpiresIn,
	}
}

// ServeHTTP implements http.Handler, so a test mounts this directly:
// httptest.NewServer(fakegoogle.New()).
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/token":
		s.serveToken(w, r)
	case "/revoke":
		s.serveRevoke(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) serveToken(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	s.mu.Lock()
	s.TokenRequests = append(s.TokenRequests, cloneValues(r.PostForm))
	invalidGrant := s.InvalidGrant
	refresh, access, id, expires := s.RefreshToken, s.AccessToken, s.IDToken, s.ExpiresIn
	s.mu.Unlock()

	if invalidGrant {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error":             "invalid_grant",
			"error_description": "Token has been expired or revoked.",
		})
		return
	}
	resp := map[string]any{
		"access_token": access,
		"id_token":     id,
		"expires_in":   expires,
		"token_type":   "Bearer",
	}
	// The real refresh grant never echoes refresh_token back — the fake
	// matches that, so Google.Refresh's "echo the input token" behaviour
	// (internal/mailbox/google.go) is exercised against the real wire
	// shape rather than a fake that is more generous than Google is.
	if r.PostForm.Get("grant_type") != "refresh_token" {
		resp["refresh_token"] = refresh
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) serveRevoke(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	s.mu.Lock()
	s.RevokeRequests = append(s.RevokeRequests, cloneValues(r.PostForm))
	invalidGrant := s.InvalidGrant
	s.mu.Unlock()
	if invalidGrant {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant"})
		return
	}
	w.WriteHeader(http.StatusOK)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func cloneValues(v url.Values) url.Values {
	out := make(url.Values, len(v))
	for k, vs := range v {
		cp := make([]string, len(vs))
		copy(cp, vs)
		out[k] = cp
	}
	return out
}
