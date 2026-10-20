package api

// routes_push.go: the APNs device-token routes (spec 02 §7 #31–#33, §12).
// They are always mounted, so a device registers its token even while
// apns.enabled is false and is found when sending is switched on.

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/auth"
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

// writerTokens and accountTokens read the tokens a deletion is about to take
// with it (spec 02 §12.5: "collected before deletion"), so they can still be
// woken once it commits. accountTokens skips except ("" = none). A failed read
// costs only the wake, never the request.
func (s *Server) writerTokens(ctx context.Context, userID uuid.UUID, writerID string) []pushv2.Target {
	return s.tokensOrLog(userID, func(q pushv2.Querier) ([]pushv2.Target, error) {
		return pushv2.WriterTokens(ctx, q, userID, writerID)
	})
}

func (s *Server) accountTokens(ctx context.Context, userID uuid.UUID, except string) []pushv2.Target {
	return s.tokensOrLog(userID, func(q pushv2.Querier) ([]pushv2.Target, error) {
		return pushv2.CollectTokens(ctx, q, userID, except)
	})
}

func (s *Server) tokensOrLog(userID uuid.UUID, read func(pushv2.Querier) ([]pushv2.Target, error)) []pushv2.Target {
	if s.Pool == nil {
		return nil
	}
	t, err := read(s.Pool)
	if err != nil {
		s.logf("api: collect push tokens for %s: %v", userID, err)
		return nil
	}
	return t
}

// wakeTokens wakes tokens collected before their rows went away.
func (s *Server) wakeTokens(ctx context.Context, t []pushv2.Target, r pushv2.Reason) {
	s.waker().WakeTokens(context.WithoutCancel(ctx), t, r)
}

// securityWake sends a committed security action's wake (spec 02 §12.5): the
// account's other devices, then the tokens of the sessions it signed out,
// which nothing else can find any more. A zero Wake sends nothing.
func (s *Server) securityWake(ctx context.Context, w auth.Wake) {
	if w.UserID == uuid.Nil {
		return
	}
	s.wakeOthers(ctx, w.UserID, w.Except, pushv2.ReasonSecurity)
	if len(w.Revoked) > 0 {
		s.wakeTokens(ctx, w.Revoked, pushv2.ReasonSecurity)
	}
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
// writer, one row per token (AT-APNS-7). A token another writer of this
// account holds is moved here. A token another account holds is moved only
// when that row is dead: its session revoked, expired or idle, or its writer
// revoked; while it is live the answer is 409 token_in_use and nothing
// changes, so knowing a device's token is not enough to silence it. A phone
// that switches accounts signs the first one out, which deletes its row. The
// row is bound to the calling session, so logging that session out silences
// the device.
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
	now := s.now()
	if _, err := tx.Exec(r.Context(),
		`DELETE FROM apns_tokens a
		  WHERE a.token_hex = $1 AND NOT (a.user_id = $2 AND a.writer_id = $3)
		    AND (a.user_id = $2
		         OR NOT EXISTS (SELECT 1 FROM sessions s WHERE s.token_hash = a.session_hash
		              AND s.revoked_at IS NULL AND s.expires_at > $4 AND s.last_used_at > $5)
		         OR EXISTS (SELECT 1 FROM writers w WHERE w.user_id = a.user_id AND w.writer_id = a.writer_id
		              AND w.revoked_at IS NOT NULL))`,
		token, userID, info.WriterID, now, now.Add(-s.Sessions.TTL)); err != nil {
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
		userID, info.WriterID, info.Hash, token, req.Environment, now); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "apns_tokens_token_uniq" {
			writeErr(w, http.StatusConflict, "token_in_use", "this device token is registered to another account")
			return
		}
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
