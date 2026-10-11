package api

import (
	"net/http"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
)

// routes_password.go: password sign-in, set, change, remove, C8 and the salt
// route (spec 02 §10.8, §10.10, routes #46, #47, #55–#59). Owner: WS-3.
func (s *Server) mountPassword(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/password/login/begin", s.limited(s.handlePasswordLoginBegin, s.PasskeyPerIP, s.PasskeyGlobal))
	mux.HandleFunc("POST /api/v1/auth/password/login/finish", s.limited(s.handlePasswordLoginFinish, s.PasskeyPerIP))
	mux.HandleFunc("POST /api/v1/account/password/reset", s.requireSession(s.userLimited(s.handlePasswordResetC8)))
	mux.HandleFunc("POST /api/v1/account/password", s.requireSession(s.userLimited(s.handlePasswordSet)))
	mux.HandleFunc("PUT /api/v1/account/password", s.requireSession(s.userLimited(s.handlePasswordChange)))
	mux.HandleFunc("DELETE /api/v1/account/password", s.requireSession(s.userLimited(s.handlePasswordRemove)))
	mux.HandleFunc("POST /api/v1/account/password/salt", s.requireSession(s.userLimited(s.handlePasswordSalt)))
}

// EmailRequest is a body that carries one address.
type EmailRequest struct {
	Email string `json:"email"`
}

// PasswordLoginBeginResponse is #46's answer, identical in shape for every
// valid address.
type PasswordLoginBeginResponse struct {
	CeremonyID string `json:"ceremony_id"`
	Salt       string `json:"salt"`  // b64
	Nonce      string `json:"nonce"` // b64
}

func (s *Server) handlePasswordLoginBegin(w http.ResponseWriter, r *http.Request) {
	var req EmailRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	out, err := s.Accounts.PasswordLoginBegin(r.Context(), req.Email)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, PasswordLoginBeginResponse{CeremonyID: out.CeremonyID, Salt: b64(out.Salt), Nonce: b64(out.Nonce)})
}

// PasswordLoginFinishRequest is #47's body.
type PasswordLoginFinishRequest struct {
	CeremonyID string      `json:"ceremony_id"`
	Verifier   string      `json:"verifier"` // b64, 32 bytes
	Device     *DeviceWire `json:"device"`
}

func (s *Server) handlePasswordLoginFinish(w http.ResponseWriter, r *http.Request) {
	var req PasswordLoginFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	v, ok := b64Field(w, req.Verifier, "verifier")
	if !ok {
		return
	}
	device, ok := decodeDevice(w, req.Device)
	if !ok {
		return
	}
	out, err := s.Accounts.PasswordLoginFinish(r.Context(), req.CeremonyID, v, device)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, signInResponse(out))
}

// VerifierStepUpRequest is the body of #55–#57.
type VerifierStepUpRequest struct {
	Verifier string      `json:"verifier"` // b64, 32 bytes: S_new
	StepUp   *StepUpWire `json:"step_up"`
}

// StepUpOnlyRequest is the body of the routes that carry only a step-up.
type StepUpOnlyRequest struct {
	StepUp *StepUpWire `json:"step_up"`
}

func (s *Server) verifierRoute(w http.ResponseWriter, r *http.Request,
	do func(info auth.SessionInfo, v []byte, su *auth.StepUpObject) error) {
	var req VerifierStepUpRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	v, ok := b64Field(w, req.Verifier, "verifier")
	if !ok {
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
	if err := do(info, v, su); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePasswordResetC8(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	s.verifierRoute(w, r, func(info auth.SessionInfo, v []byte, su *auth.StepUpObject) error {
		return s.Accounts.ResetPasswordWithCode(r.Context(), info, v, su)
	})
}

func (s *Server) handlePasswordSet(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	s.verifierRoute(w, r, func(info auth.SessionInfo, v []byte, su *auth.StepUpObject) error {
		return s.Accounts.SetPassword(r.Context(), info, v, su)
	})
}

func (s *Server) handlePasswordChange(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	s.verifierRoute(w, r, func(info auth.SessionInfo, v []byte, su *auth.StepUpObject) error {
		return s.Accounts.ChangePassword(r.Context(), info, v, su)
	})
}

func (s *Server) handlePasswordRemove(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
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
	if err := s.Accounts.RemovePassword(r.Context(), info, su); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// SaltResponse carries s_srv.
type SaltResponse struct {
	Salt string `json:"salt"` // b64
}

func (s *Server) handlePasswordSalt(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	var req EmailRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	salt, err := s.Accounts.PasswordSalt(req.Email)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, SaltResponse{Salt: b64(salt)})
}
