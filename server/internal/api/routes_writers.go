package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
)

// routes_writers.go: the writer challenge, registration and roster (spec 02
// §4.2; WS-3 owns it and replaces registration with spec 01 §10.5's
// AAK-certified enrolment and adds POST /api/v1/writers/revoke).

func (s *Server) mountWriters(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/writers/challenge", s.requireSession(s.handleChallenge))
	mux.HandleFunc("POST /api/v1/writers/register", s.requireSession(s.handleRegister))
	mux.HandleFunc("GET /api/v1/writers", s.requireSession(s.handleRoster))
}

// ChallengeResponse carries a single-use registration nonce (base64).
type ChallengeResponse struct {
	Nonce string `json:"nonce"`
}

// RegisterRequest is POST /api/v1/writers/register. The signature is over
// auth.RegistrationMessage(nonce, writer_id, pubkey).
type RegisterRequest struct {
	WriterID string `json:"writer_id"`
	PubKey   string `json:"pubkey"` // base64
	Nonce    string `json:"nonce"`  // base64
	Sig      string `json:"sig"`    // base64
}

// WriterEntry is one roster row. RevokedAt is null while the writer is live.
type WriterEntry struct {
	WriterID     string     `json:"writer_id"`
	Kind         string     `json:"kind"`
	PubKey       string     `json:"pubkey"` // base64
	RegisteredAt time.Time  `json:"registered_at"`
	RevokedAt    *time.Time `json:"revoked_at"`
}

// WritersResponse answers GET /api/v1/writers. Revoked writers are INCLUDED: a
// peer auditing a chain needs "this writer was retired" and "this writer was
// never here" to be different answers.
type WritersResponse struct {
	Writers []WriterEntry `json:"writers"`
}

// handleChallenge mints a single-use registration nonce.
//
// The per-user cap is the point of the rate limit here: minting is exactly what
// a session token authorizes, so without a cap one session can fill
// writer_challenges as fast as it can issue requests. The challenge is
// worthless without a signature from an enrolled key, so the cap protects
// storage rather than the capability.
func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.ChallengePerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many challenges; try again shortly")
		return
	}
	nonce, err := s.Writers.Challenge(r.Context(), userID)
	if err != nil {
		s.logf("api: challenge for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, ChallengeResponse{Nonce: base64.StdEncoding.EncodeToString(nonce)})
}

// handleRegister enrolls a writer.
//
// The session identifies the ACCOUNT and authorizes nothing else: the
// enrollment is authorized by the Ed25519 signature, which auth.Writers.Register
// checks against an already-enrolled key (or, exactly once per account, against
// the key being enrolled — the TOFU bootstrap).
//
// Every rejection is the same 403 with the same body. auth returns distinct
// sentinels — ErrWriterExists, ErrKeyAlreadyEnrolled, ErrNotAuthorized,
// ErrChallengeUsed, … — and each of them, surfaced, tells a caller who could
// not prove key possession whether a writer id is taken or a public key is
// already enrolled. Neither is theirs to learn.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	// Capping challenge minting bounds SUCCESSFUL registrations, and nothing
	// else: a failed attempt consumes no challenge budget — a replayed nonce is
	// refused by consumeChallenge, which costs two database round trips before
	// any signature work — so attempts need their own cap. It is per user
	// rather than per address so one account cannot spend another's.
	if !s.RegisterPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many registration attempts; try again shortly")
		return
	}
	var req RegisterRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.PubKey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "pubkey is not base64")
		return
	}
	nonce, err := base64.StdEncoding.DecodeString(req.Nonce)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "nonce is not base64")
		return
	}
	sig, err := base64.StdEncoding.DecodeString(req.Sig)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "sig is not base64")
		return
	}
	err = s.Writers.Register(r.Context(), userID, req.WriterID, ed25519.PublicKey(pub), nonce, sig)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, auth.ErrRegistrationRejected):
		s.logf("api: register writer for %s: %v", userID, err)
		writeErr(w, http.StatusForbidden, "registration_rejected", "")
	default:
		s.logf("api: register writer for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	}
}

// handleRoster returns the caller's writers, revoked ones included.
func (s *Server) handleRoster(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	roster, err := s.Writers.Roster(r.Context(), userID)
	if err != nil {
		s.logf("api: roster for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := WritersResponse{Writers: make([]WriterEntry, 0, len(roster))}
	for _, wr := range roster {
		e := WriterEntry{
			WriterID:     wr.WriterID,
			Kind:         wr.Kind,
			RegisteredAt: wr.RegisteredAt,
		}
		if wr.PubKey != nil {
			e.PubKey = base64.StdEncoding.EncodeToString(wr.PubKey)
		}
		if !wr.RevokedAt.IsZero() {
			t := wr.RevokedAt
			e.RevokedAt = &t
		}
		out.Writers = append(out.Writers, e)
	}
	writeJSON(w, http.StatusOK, out)
}
