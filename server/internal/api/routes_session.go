package api

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// routes_session.go: sign-out (spec 02 §9.3; security finding F4: a sign-out
// that leaves the session valid on the server is not a sign-out). WS-3 owns
// this file; it adds GET /api/v1/auth/session (#14) and the step-up gate on
// logout-all.

func (s *Server) mountSession(mux *http.ServeMux) {
	// #15. No step-up, and allowed while the account is suspended: signing out
	// must never be the thing an operator's pause takes away.
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleLogout)
	// #16, under step-up `session.logout_all` (spec 02 §8.2). It revokes
	// every session, the caller's own included.
	mux.HandleFunc("POST /api/v1/auth/logout-all", s.requireSession(s.handleLogoutAll))
	mux.HandleFunc("GET /api/v1/auth/session", s.requireSession(s.handleGetSession))
}

// SessionWire is GET /api/v1/auth/session (#14).
type SessionWire struct {
	UserID        string    `json:"user_id"`
	MintedBy      string    `json:"minted_by"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
	IdleExpiresAt time.Time `json:"idle_expires_at"`
	WriterID      *string   `json:"writer_id"`
	CredentialID  *string   `json:"credential_id"` // b64url
	Restricted    bool      `json:"restricted"`
}

func (s *Server) handleGetSession(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	out := SessionWire{UserID: info.UserID.String(), MintedBy: info.MintedBy, CreatedAt: info.CreatedAt.UTC(),
		ExpiresAt: info.ExpiresAt.UTC(), IdleExpiresAt: info.IdleExpires.UTC(), Restricted: info.Restricted}
	if info.WriterID != "" {
		wid := info.WriterID
		out.WriterID = &wid
	}
	if len(info.CredentialID) > 0 {
		c := b64url(info.CredentialID)
		out.CredentialID = &c
	}
	writeJSON(w, http.StatusOK, out)
}

// handleLogout revokes the presented session and deletes the APNs tokens it
// registered, in one transaction (auth.Sessions.Revoke). It is idempotent; the
// client treats 204 and 401 alike, calls it BEFORE deleting its Keychain item,
// and queues a retry when offline (spec 02 §9.3).
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	token, ok := bearerToken(r)
	if !ok {
		writeUnauthorized(w)
		return
	}
	if !decodeEmptyBody(w, r) {
		return
	}
	userID, err := s.Sessions.Resolve(r.Context(), token)
	switch {
	case errors.Is(err, auth.ErrSessionAccountDeleted):
		writeAccountDeleted(w)
		return
	case errors.Is(err, auth.ErrSessionInvalid):
		// Already revoked, expired or unknown: there is nothing left to sign
		// out, and the answer must not say which.
		writeUnauthorized(w)
		return
	case err != nil:
		s.logf("api: logout: resolve session: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if !s.SessionPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many sign-outs; try again shortly")
		return
	}
	if err := s.Sessions.Revoke(r.Context(), token); err != nil {
		s.logf("api: logout for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleLogoutAll revokes every session of the account, the caller's included,
// and deletes every APNs token, in one transaction. Writers are NOT revoked:
// the devices keep their keys and can sign in again (spec 02 §9.3). It needs
// a session.logout_all step-up, records sessions_revoked, and gives every
// other device a security wake through its token, collected before the
// tokens are forgotten (§12.5); they then meet a 401.
func (s *Server) handleLogoutAll(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many sign-outs; try again shortly")
		return
	}
	var req StepUpOnlyRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if su == nil {
		s.writeKeyErr(w, r, auth.ErrStepUpRequired)
		return
	}
	// The caller's own device is not woken. The tokens are collected before
	// the step-up's transaction forgets them; a failed lookup costs the
	// wakes, never the sign-out.
	tokens := s.accountTokens(r.Context(), userID, info.WriterID)
	if err := s.accounts().LogoutAll(r.Context(), info, su); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeTokens(r.Context(), tokens, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

// decodeEmptyBody accepts no body at all or the empty object `{}` — a
// sign-out carries nothing, and a client that sends nothing must not be told
// its sign-out was malformed (it would keep a session alive it meant to end).
func decodeEmptyBody(w http.ResponseWriter, r *http.Request) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxSmallBodyBytes))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "this endpoint takes no body")
		return false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return true
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	var body struct{}
	return decodeBody(w, r, maxSmallBodyBytes, &body)
}
