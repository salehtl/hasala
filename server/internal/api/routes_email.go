package api

import (
	"net/http"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/pushv2"
)

// routes_email.go: email change and re-verification (spec 02 §10.12, routes
// #60–#63). Owner: WS-3.
func (s *Server) mountEmail(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/account/email/begin", s.requireSession(s.userLimited(s.handleEmailChangeBegin)))
	mux.HandleFunc("POST /api/v1/account/email/finish", s.requireSession(s.userLimited(s.codeLimited(s.handleEmailChangeFinish))))
	mux.HandleFunc("POST /api/v1/account/email/verify/begin", s.requireSession(s.userLimited(s.handleEmailVerifyBegin)))
	mux.HandleFunc("POST /api/v1/account/email/verify/finish", s.requireSession(s.userLimited(s.codeLimited(s.handleEmailVerifyFinish))))
}

// codeLimited is code-ip on a session route.
func (s *Server) codeLimited(h authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
		if !s.CodePerIP.Allow(clientKey(r)) {
			writeTooManyAttempts(w)
			return
		}
		h(w, r, userID)
	}
}

// EmailChangeBeginRequest is #60's body.
type EmailChangeBeginRequest struct {
	NewEmail    string      `json:"new_email"`
	VerifierNew *string     `json:"verifier_new"` // b64 S' for the new address, or null
	StepUp      *StepUpWire `json:"step_up"`
}

// EmailChangeBeginResponse is #60's answer, identical whether or not the new
// address is in use.
type EmailChangeBeginResponse struct {
	ChangeID string `json:"change_id"`
	Nonce    string `json:"nonce"` // b64
}

func (s *Server) handleEmailChangeBegin(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	var req EmailChangeBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	var v []byte
	if req.VerifierNew != nil {
		var ok bool
		if v, ok = b64Field(w, *req.VerifierNew, "verifier_new"); !ok {
			return
		}
	}
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	out, err := s.Accounts.EmailChangeBegin(r.Context(), info, req.NewEmail, v, su)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, EmailChangeBeginResponse{ChangeID: out.ChangeID.String(), Nonce: b64(out.Nonce)})
}

// EmailChangeFinishRequest is #61's body.
type EmailChangeFinishRequest struct {
	ChangeID string  `json:"change_id"`
	CodeNew  string  `json:"code_new"`
	CodeOld  *string `json:"code_old"`
	RKSig    *string `json:"rk_sig"` // b64, the RK over EmailChangeMessage
}

func (s *Server) handleEmailChangeFinish(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	var req EmailChangeFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	id, err := uuid.Parse(req.ChangeID)
	if err != nil {
		writeErr(w, http.StatusForbidden, "code_rejected", "")
		return
	}
	var rk []byte
	if req.RKSig != nil {
		var ok bool
		if rk, ok = b64Field(w, *req.RKSig, "rk_sig"); !ok {
			return
		}
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if err := s.Accounts.EmailChangeFinish(r.Context(), info, id, req.CodeNew, req.CodeOld, rk); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// Every other device hears of the new address (spec 02 §12.5).
	s.wakeOthers(r.Context(), info.UserID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleEmailVerifyBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !decodeEmptyBody(w, r) {
		return
	}
	if err := s.Accounts.EmailVerifyBegin(r.Context(), userID); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// CodeOnlyRequest is #63's body.
type CodeOnlyRequest struct {
	Code string `json:"code"`
}

func (s *Server) handleEmailVerifyFinish(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	var req CodeOnlyRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if err := s.Accounts.EmailVerifyFinish(r.Context(), userID, req.Code); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
