package api

import (
	"encoding/hex"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// routes_stepup.go: POST /api/v1/auth/step-up/begin (spec 02 #9, §8.1). The
// client computes params_hash for the action it is about to perform and the
// challenge C itself, and refuses to prove a C that differs from the one
// answered here (spec 01 AT-C9); the guarded route recomputes params_hash from
// its own request and spends the nonce in the action's transaction.
func (s *Server) mountStepUp(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/step-up/begin", s.requireSession(s.handleStepUpBegin))
}

// StepUpBeginRequest is #9.
type StepUpBeginRequest struct {
	Action     string `json:"action"`
	ParamsHash string `json:"params_hash"` // hex, 32 bytes
	ProofKind  string `json:"proof_kind"`  // passkey | device | device_code
}

// StepUpBeginResponse is #9's answer; rp_id and allow_credentials only for a
// passkey proof.
type StepUpBeginResponse struct {
	Nonce            string    `json:"nonce"`     // b64url
	Challenge        string    `json:"challenge"` // b64url of C
	ExpiresAt        time.Time `json:"expires_at"`
	RPID             string    `json:"rp_id,omitempty"`
	AllowCredentials []string  `json:"allow_credentials,omitempty"` // b64url
}

func (s *Server) handleStepUpBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.StepUpPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many step-ups; try again shortly")
		return
	}
	var req StepUpBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	ph, err := hex.DecodeString(req.ParamsHash)
	if err != nil || len(ph) != 32 {
		writeErr(w, http.StatusBadRequest, "bad_request", "params_hash is not 64 hex characters")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	b, err := s.StepUp.Begin(r.Context(), userID, info.Hash, info.WriterID,
		keyproto.Action(req.Action), ph, keyproto.ProofKind(req.ProofKind))
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out := StepUpBeginResponse{Nonce: b64url(b.Nonce), Challenge: b64url(b.Challenge[:]), ExpiresAt: b.ExpiresAt}
	if keyproto.ProofKind(req.ProofKind) == keyproto.ProofPasskey {
		if s.Passkeys != nil {
			out.RPID = s.Passkeys.RPID()
		}
		out.AllowCredentials = []string{}
		for _, c := range b.AllowCredentials {
			out.AllowCredentials = append(out.AllowCredentials, b64url(c))
		}
	}
	writeJSON(w, http.StatusOK, out)
}
