package api

// routes_push.go: the APNs device-token routes (spec 02 §7 #31–#33, §12).
// They are always mounted, so a device registers its token even while
// apns.enabled is false and is found when sending is switched on.

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/pushv2"
)

// push-user (spec 02 §16.2): 1/min per account, burst 20.
const (
	pushRate    = 1.0 / 60.0
	pushBurst   = 20
	pushMaxKeys = 4096
)

// PushOptions configures the token routes and the wakes the API sends.
type PushOptions struct {
	// Waker sends the wakes; nil is pushv2.NopWaker.
	Waker pushv2.Waker
	// Environments a token may claim (apns.allowed_environments); empty means
	// both.
	Environments []string
	// PerUser is push-user; nil is the default.
	PerUser *Limiter
}

// waker returns the configured Waker, never nil.
func (s *Server) waker() pushv2.Waker {
	if s.Push.Waker == nil {
		return pushv2.NopWaker{}
	}
	return s.Push.Waker
}

// wakeOthers sends a wake to every device of userID but except. It never
// blocks: the Waker enqueues.
func (s *Server) wakeOthers(ctx context.Context, userID uuid.UUID, except string, r pushv2.Reason) {
	s.waker().WakeOthers(context.WithoutCancel(ctx), userID, except, r)
}

func (s *Server) mountPush(mux *http.ServeMux) {
	if s.Push.PerUser == nil {
		s.Push.PerUser = NewLimiter(pushRate, pushBurst, pushMaxKeys, s.now)
	}
	mux.HandleFunc("PUT /api/v1/push/apns", s.requireSession(s.handlePutAPNs))
	mux.HandleFunc("GET /api/v1/push/apns", s.requireSession(s.handleGetAPNs))
	mux.HandleFunc("DELETE /api/v1/push/apns", s.requireSession(s.handleDeleteAPNs))
}

// PutAPNsRequest is #31's body.
type PutAPNsRequest struct {
	TokenHex    string `json:"token_hex"`
	Environment string `json:"environment"`
}

// APNsDevice is one row of #32.
type APNsDevice struct {
	WriterID    string    `json:"writer_id"`
	Environment string    `json:"environment"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	Current     bool      `json:"current"`
}

// APNsDevicesResponse is #32's answer.
type APNsDevicesResponse struct {
	Devices []APNsDevice `json:"devices"`
}

func (s *Server) environmentAllowed(env string) bool {
	if env != pushv2.EnvProduction && env != pushv2.EnvSandbox {
		return false
	}
	return len(s.Push.Environments) == 0 || slices.Contains(s.Push.Environments, env)
}

// handlePutAPNs registers (or moves) this device's token. One token per
// writer; a token registered elsewhere — another writer, another account — is
// moved here, so one row remains (AT-APNS-7). The row is bound to the calling
// session, so logging that session out silences the device.
func (s *Server) handlePutAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.Push.PerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many push registrations; try again shortly")
		return
	}
	var req PutAPNsRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	token := strings.ToLower(req.TokenHex)
	if !pushv2.ValidTokenHex(token) {
		writeErr(w, http.StatusBadRequest, "bad_request", "token_hex must be 32 to 100 bytes of hex")
		return
	}
	if !s.environmentAllowed(req.Environment) {
		writeErr(w, http.StatusBadRequest, "bad_request", "environment must be one this server accepts")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		s.logf("api: put apns for %s: begin: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(r.Context())) }()
	if _, err := tx.Exec(r.Context(),
		`DELETE FROM apns_tokens WHERE token_hex = $1 AND NOT (user_id = $2 AND writer_id = $3)`,
		token, userID, info.WriterID); err != nil {
		s.logf("api: put apns for %s: move: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if _, err := tx.Exec(r.Context(),
		`INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $6)
		 ON CONFLICT (user_id, writer_id) DO UPDATE
		   SET session_hash = EXCLUDED.session_hash, token_hex = EXCLUDED.token_hex,
		       environment = EXCLUDED.environment, updated_at = EXCLUDED.updated_at`,
		userID, info.WriterID, info.Hash, token, req.Environment, s.now()); err != nil {
		s.logf("api: put apns for %s: upsert: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		s.logf("api: put apns for %s: commit: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(),
		`SELECT writer_id, environment, created_at, updated_at FROM apns_tokens WHERE user_id = $1 ORDER BY created_at, writer_id`,
		userID)
	if err != nil {
		s.logf("api: get apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	defer rows.Close()
	out := APNsDevicesResponse{Devices: []APNsDevice{}}
	for rows.Next() {
		var d APNsDevice
		if err := rows.Scan(&d.WriterID, &d.Environment, &d.CreatedAt, &d.UpdatedAt); err != nil {
			s.logf("api: get apns for %s: %v", userID, err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		d.Current = d.WriterID == info.WriterID && info.WriterID != ""
		out.Devices = append(out.Devices, d)
	}
	if err := rows.Err(); err != nil {
		s.logf("api: get apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeleteAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.Push.PerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many push registrations; try again shortly")
		return
	}
	if !decodeEmptyBody(w, r) {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`DELETE FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, userID, info.WriterID); err != nil {
		s.logf("api: delete apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
