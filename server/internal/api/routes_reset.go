package api

import (
	"net/http"
	"time"

	"github.com/google/uuid"
)

// routes_reset.go: password reset on a new iPhone approved by a signed-in
// iPhone (C9, spec 02 §10.9, routes #49–#54). Owner: WS-3.
func (s *Server) mountReset(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/password/reset/begin", s.limited(s.handleResetBegin, s.PasskeyPerIP, s.PasskeyGlobal))
	mux.HandleFunc("POST /api/v1/auth/password/reset/verify", s.limited(s.handleResetVerify, s.PasskeyPerIP, s.CodePerIP))
	mux.HandleFunc("POST /api/v1/auth/password/reset/request", s.limited(s.handleResetRequest, s.ResetPerIP))
	mux.HandleFunc("GET /api/v1/auth/password/reset/pending", s.requireSession(s.userLimited(s.handleResetPending)))
	mux.HandleFunc("POST /api/v1/auth/password/reset/approve", s.requireSession(s.userLimited(s.handleResetApprove)))
	mux.HandleFunc("POST /api/v1/auth/password/reset/finish", s.limited(s.handleResetFinish, s.ResetPerIP))
}

// ResetBeginResponse is #49's answer, identical for every valid address.
type ResetBeginResponse struct {
	ResetID string `json:"reset_id"`
}

func (s *Server) handleResetBegin(w http.ResponseWriter, r *http.Request) {
	var req EmailRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	id, err := s.Accounts.ResetBegin(r.Context(), req.Email)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, ResetBeginResponse{ResetID: id})
}

// ResetCodeRequest is #50's body.
type ResetCodeRequest struct {
	ResetID string `json:"reset_id"`
	Code    string `json:"code"`
}

// ResetVerifyResponse is #50's answer.
type ResetVerifyResponse struct {
	Nonce     string `json:"nonce"` // b64
	Salt      string `json:"salt"`  // b64
	Approvers bool   `json:"approvers"`
}

func (s *Server) handleResetVerify(w http.ResponseWriter, r *http.Request) {
	var req ResetCodeRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	out, err := s.Accounts.ResetVerify(r.Context(), req.ResetID, req.Code)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, ResetVerifyResponse{Nonce: b64(out.Nonce), Salt: b64(out.Salt), Approvers: out.Approvers})
}

// ResetRequestBody is #51's body.
type ResetRequestBody struct {
	ResetID string `json:"reset_id"`
	EKPub   string `json:"ek_pub"` // b64, 32 bytes
}

func (s *Server) handleResetRequest(w http.ResponseWriter, r *http.Request) {
	var req ResetRequestBody
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	ek, ok := b64Field(w, req.EKPub, "ek_pub")
	if !ok {
		return
	}
	wake, err := s.Accounts.ResetRequest(r.Context(), req.ResetID, ek)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.securityWake(r.Context(), wake)
	w.WriteHeader(http.StatusNoContent)
}

// PendingResetWire is one row of #52.
type PendingResetWire struct {
	ResetID   string    `json:"reset_id"`
	Nonce     string    `json:"nonce"`  // b64
	EKPub     string    `json:"ek_pub"` // b64
	CreatedAt time.Time `json:"created_at"`
}

// ResetPendingResponse is #52's answer.
type ResetPendingResponse struct {
	Pending []PendingResetWire `json:"pending"`
}

func (s *Server) handleResetPending(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	rows, err := s.Accounts.ResetPending(r.Context(), userID)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out := ResetPendingResponse{Pending: []PendingResetWire{}}
	for _, p := range rows {
		out.Pending = append(out.Pending, PendingResetWire{ResetID: p.ResetID, Nonce: b64(p.Nonce), EKPub: b64(p.EKPub),
			CreatedAt: p.CreatedAt.UTC()})
	}
	writeJSON(w, http.StatusOK, out)
}

// ResetApproveRequest is #53's body.
type ResetApproveRequest struct {
	ResetID  string `json:"reset_id"`
	WriterID string `json:"writer_id"`
	Sig      string `json:"sig"` // b64, 64 bytes: the DAK over ResetApproveMessage
}

func (s *Server) handleResetApprove(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	var req ResetApproveRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	sig, ok := b64Field(w, req.Sig, "sig")
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	if err := s.Accounts.ResetApprove(r.Context(), info, req.ResetID, req.WriterID, sig); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ResetFinishRequest is #54's body.
type ResetFinishRequest struct {
	ResetID  string `json:"reset_id"`
	Verifier string `json:"verifier"` // b64, 32 bytes: S_new
	EKSig    string `json:"ek_sig"`   // b64, 64 bytes
}

func (s *Server) handleResetFinish(w http.ResponseWriter, r *http.Request) {
	var req ResetFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	v, ok := b64Field(w, req.Verifier, "verifier")
	if !ok {
		return
	}
	sig, ok := b64Field(w, req.EKSig, "ek_sig")
	if !ok {
		return
	}
	out, err := s.Accounts.ResetFinish(r.Context(), req.ResetID, v, sig)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.securityWake(r.Context(), out.Wake)
	writeJSON(w, http.StatusCreated, SessionMintResponse{SessionToken: out.Session.Token, UserID: out.UserID.String(),
		ExpiresAt: out.Session.ExpiresAt.UTC()})
}
