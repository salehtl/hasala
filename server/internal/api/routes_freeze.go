package api

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// routes_freeze.go: freeze by link, freeze in app, unfreeze, and the
// session-free device freeze (spec 02 §10.13, routes #64–#66, #77, #78).
// Owner: WS-3.
func (s *Server) mountFreeze(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/account/freeze", s.freezeOrigin(s.limited(s.handleFreezeLink, s.FreezePerIP)))
	mux.HandleFunc("POST /api/v1/account/freeze/now", s.requireSession(s.userLimited(s.handleFreezeNow)))
	mux.HandleFunc("POST /api/v1/account/unfreeze", s.requireSessionFrozenOK(s.userLimited(s.handleUnfreeze)))
	mux.HandleFunc("POST /api/v1/auth/device-freeze/challenge", s.handleDeviceFreezeChallenge)
	mux.HandleFunc("POST /api/v1/auth/device-freeze", s.handleDeviceFreeze)
}

// freezeLinkMax is how much of #64's body is read.
const freezeLinkMax = 256

func (s *Server) freezeOrigin(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" && s.Web != nil && slices.Contains(s.Web.Origins, origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		}
		w.Header().Add("Vary", "Origin")
		h(w, r)
	}
}

// handleFreezeLink is #64: the static freeze page posts {"token"} as a
// text/plain request. The answer is 204 with an empty body for any token,
// known or not (D-13); a live token that could not be tried, or a lookup
// that failed, is a 503. Only a live token spends freeze-global.
func (s *Server) handleFreezeLink(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(io.LimitReader(r.Body, freezeLinkMax+1))
	var body struct {
		Token string `json:"token"`
	}
	if len(raw) <= freezeLinkMax && json.Unmarshal(raw, &body) == nil && auth.WellFormedFreezeToken(body.Token) {
		if k, ok := prefixKey(clientKey(r)); ok && !s.FreezePerPrefix.Allow(k) {
			writeFreezeRetry(w)
			return
		}
		live, err := s.Accounts.FreezeTokenLive(r.Context(), body.Token)
		if err != nil {
			s.logf("api: freeze link: %v", err)
			writeFreezeRetry(w)
			return
		}
		if !live {
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if !s.FreezeGlobal.Allow("") {
			writeFreezeRetry(w)
			return
		}
		wake, err := s.Accounts.FreezeByLink(r.Context(), body.Token)
		if err != nil {
			s.logf("api: freeze link: %v", err)
			writeFreezeRetry(w)
			return
		}
		s.securityWake(r.Context(), wake)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

func writeFreezeRetry(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Retry-After", "60")
	w.WriteHeader(http.StatusServiceUnavailable)
}

func (s *Server) handleFreezeNow(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	s.stepUpRoute(w, r, s.Accounts.FreezeNow)
}

func (s *Server) handleUnfreeze(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	s.stepUpRoute(w, r, s.Accounts.Unfreeze)
}

// devFreezeLimited runs devfreeze-ip, then (for a well-formed writer id only)
// devfreeze-global. It reports whether it answered.
func (s *Server) devFreezeLimited(w http.ResponseWriter, r *http.Request, writerID string) bool {
	if !s.DevFreezeIP.Allow(clientKey(r)) || (keyproto.ValidWriterID(writerID) && !s.globalAllow(r, s.DevFreezePerPrefix, s.DevFreezeGlobal)) {
		writeTooManyAttempts(w)
		return true
	}
	return false
}

// DeviceFreezeChallengeRequest is #77's body.
type DeviceFreezeChallengeRequest struct {
	WriterID string `json:"writer_id"`
}

// DeviceFreezeChallengeResponse is #77's answer, the same for every
// well-formed writer id.
type DeviceFreezeChallengeResponse struct {
	Nonce     string    `json:"nonce"` // b64
	ExpiresAt time.Time `json:"expires_at"`
}

func (s *Server) handleDeviceFreezeChallenge(w http.ResponseWriter, r *http.Request) {
	var req DeviceFreezeChallengeRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if s.devFreezeLimited(w, r, req.WriterID) {
		return
	}
	nonce, exp, err := s.Accounts.DeviceFreezeChallenge(r.Context(), req.WriterID)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, DeviceFreezeChallengeResponse{Nonce: b64(nonce), ExpiresAt: exp.UTC()})
}

// DeviceFreezeRequest is #78's body.
type DeviceFreezeRequest struct {
	WriterID string `json:"writer_id"`
	Nonce    string `json:"nonce"` // b64
	Sig      string `json:"sig"`   // b64, 64 bytes: the DAK over DeviceFreezeMessage
}

func (s *Server) handleDeviceFreeze(w http.ResponseWriter, r *http.Request) {
	var req DeviceFreezeRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if s.devFreezeLimited(w, r, req.WriterID) {
		return
	}
	nonce, _ := base64.StdEncoding.DecodeString(req.Nonce)
	sig, _ := base64.StdEncoding.DecodeString(req.Sig)
	wake, err := s.Accounts.DeviceFreeze(r.Context(), req.WriterID, nonce, sig, func(user uuid.UUID) bool {
		return s.DevFreezeWriter.Allow(user.String() + "/" + req.WriterID)
	})
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.securityWake(r.Context(), wake)
	w.WriteHeader(http.StatusNoContent)
}
