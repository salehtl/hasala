package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// routes_writers.go: the writer challenge, AAK-only registration, revocation
// with a pinned final head, and the roster (spec 02 #23–#26, §9.5, §10.2;
// spec 01 §10.5, §10.6).

func (s *Server) mountWriters(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/writers/challenge", s.requireSession(s.handleChallenge))
	mux.HandleFunc("POST /api/v1/writers/register", s.requireSession(s.handleRegister))
	mux.HandleFunc("POST /api/v1/writers/revoke", s.requireSession(s.handleRevoke))
	mux.HandleFunc("GET /api/v1/writers", s.requireSession(s.handleRoster))
}

// ChallengeResponse carries a single-use writer-challenge nonce (#23).
type ChallengeResponse struct {
	Nonce     string    `json:"nonce"` // b64
	ExpiresAt time.Time `json:"expires_at"`
}

// RegisterRequest is #24 (spec 02 §10.2): AAK-only, so there is no
// authorizer and no step_up (unknown fields are a 400).
type RegisterRequest struct {
	WriterID  string `json:"writer_id"`
	Alg       string `json:"alg"`
	PubKey    string `json:"pubkey"`     // b64, 32
	DAKPubkey string `json:"dak_pubkey"` // b64, 65
	Nonce     string `json:"nonce"`      // b64, 32
	Sig       string `json:"sig"`        // b64, AAK over RegistrationMessage
}

// RegisterResponse is #24's 201.
type RegisterResponse struct {
	WriterID string `json:"writer_id"`
}

// RevokeRequest is #25 (spec 02 §9.5).
type RevokeRequest struct {
	WriterID       string      `json:"writer_id"`
	SignerWriterID string      `json:"signer_writer_id"`
	Nonce          string      `json:"nonce"`         // b64
	FinalCounter   string      `json:"final_counter"` // decimal
	FinalHead      string      `json:"final_head"`    // b64, 32
	Sig            string      `json:"sig"`           // b64, DWK of the signer over RevocationMessage
	StepUp         *StepUpWire `json:"step_up"`
}

// WriterEntry is one roster row (#26). RevokedAt is null while live; Current
// marks the calling session's own writer.
type WriterEntry struct {
	WriterID     string     `json:"writer_id"`
	Alg          string     `json:"alg"`
	PubKey       string     `json:"pubkey"`     // b64
	DAKPubkey    string     `json:"dak_pubkey"` // b64
	RegisteredAt time.Time  `json:"registered_at"`
	RevokedAt    *time.Time `json:"revoked_at"`
	Current      bool       `json:"current"`
}

// WritersResponse answers GET /api/v1/writers, revoked writers included.
type WritersResponse struct {
	Writers []WriterEntry `json:"writers"`
}

func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.ChallengePerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many challenges; try again shortly")
		return
	}
	if !decodeEmptyBody(w, r) {
		return
	}
	nonce, exp, err := s.Writers.Challenge(r.Context(), userID)
	if err != nil {
		s.logf("api: challenge for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, ChallengeResponse{Nonce: b64(nonce), ExpiresAt: exp})
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.RegisterPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many registration attempts; try again shortly")
		return
	}
	var req RegisterRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	pub, ok := b64Field(w, req.PubKey, "pubkey")
	if !ok {
		return
	}
	dak, ok := b64Field(w, req.DAKPubkey, "dak_pubkey")
	if !ok {
		return
	}
	nonce, ok := b64Field(w, req.Nonce, "nonce")
	if !ok {
		return
	}
	sig, ok := b64Field(w, req.Sig, "sig")
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	err := s.Writers.Register(r.Context(), userID, info.Hash, auth.Registration{
		WriterID: req.WriterID, Alg: req.Alg, PubKey: pub, DAKPubkey: dak, Nonce: nonce, Sig: sig,
	})
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// A new device is a security event for every other one (spec 02 §12.5).
	s.wakeOthers(r.Context(), userID, req.WriterID, pushv2.ReasonSecurity)
	writeJSON(w, http.StatusCreated, RegisterResponse{WriterID: req.WriterID})
}

func (s *Server) handleRevoke(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.RegisterPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many writer requests; try again shortly")
		return
	}
	var req RevokeRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	nonce, ok := b64Field(w, req.Nonce, "nonce")
	if !ok {
		return
	}
	head, ok := b64Field(w, req.FinalHead, "final_head")
	if !ok {
		return
	}
	sig, ok := b64Field(w, req.Sig, "sig")
	if !ok {
		return
	}
	counter, err := strconv.ParseInt(req.FinalCounter, 10, 64)
	if err != nil || counter < 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "final_counter must be a non-negative decimal integer")
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
	// The revoked writer's token goes with it (spec 02 §9.5), so it is read
	// first: the revoked device is woken too (§12.5) and learns it is out.
	revoked := s.writerTokens(r.Context(), userID, req.WriterID)
	if err := s.Writers.Revoke(r.Context(), userID, info, auth.Revocation{
		WriterID: req.WriterID, SignerWriterID: req.SignerWriterID, Nonce: nonce,
		FinalCounter: counter, FinalHead: head, Sig: sig, StepUp: su,
	}); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// Every other device hears of the revocation, and so does the revoked one
	// through the token collected above.
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	if req.WriterID != info.WriterID {
		s.wakeTokens(r.Context(), revoked, pushv2.ReasonSecurity)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRoster(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	roster, err := s.Writers.Roster(r.Context(), userID)
	if err != nil {
		s.logf("api: roster for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := WritersResponse{Writers: make([]WriterEntry, 0, len(roster))}
	for _, wr := range roster {
		e := WriterEntry{
			WriterID: wr.WriterID, Alg: wr.Alg, PubKey: b64(wr.PubKey), DAKPubkey: b64(wr.DAKPubkey),
			RegisteredAt: wr.RegisteredAt, Current: wr.WriterID == info.WriterID,
		}
		if !wr.RevokedAt.IsZero() {
			t := wr.RevokedAt
			e.RevokedAt = &t
		}
		out.Writers = append(out.Writers, e)
	}
	writeJSON(w, http.StatusOK, out)
}
