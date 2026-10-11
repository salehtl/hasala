package api

// keywraps.go serves the account's PRF wraps (spec 02 #19–#21, §10.5; spec 01
// §5.3, §10.7): the same 65-byte body the recovery wrap seals, sealed again
// under a key derived from one passkey's PRF output, so Face ID can unlock the
// account's data instead of twelve typed words.
//
// A wrap is exactly 127 bytes with header 01 02 (spec 01 §5.1) and is bound by
// its AD to the account and the credential, so it cannot be replayed into
// another account or under another credential's row. Putting one needs step-up
// keys.wrap.put with a passkey proof by THAT credential (its PRF output built
// the wrap) and the session writer's DWK over WrapPutMessage, so a terminator
// that swaps in a garbage wrap has no DWK to sign it with (N-11). Deleting one
// needs step-up keys.wrap.delete; losing a wrap costs nothing, because the
// phrase still opens the account.

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// KeyWrap is one credential's wrap, as GET returns it.
type KeyWrap struct {
	CredentialID string    `json:"credential_id"` // b64url
	Wrap         string    `json:"wrap"`          // b64, 127 bytes
	WrapVersion  int       `json:"wrap_version"`
	CreatedAt    time.Time `json:"created_at"`
}

// KeyWrapsResponse answers GET /api/v1/keys/wraps: an empty list, not a 404,
// for an account with none.
type KeyWrapsResponse struct {
	Wraps []KeyWrap `json:"wraps"`
}

// PutKeyWrapRequest is #20.
type PutKeyWrapRequest struct {
	CredentialID string      `json:"credential_id"` // b64url
	Wrap         string      `json:"wrap"`          // b64
	WrapVersion  int         `json:"wrap_version"`
	DWKSig       string      `json:"dwk_sig"` // b64
	StepUp       *StepUpWire `json:"step_up"`
}

// DeleteKeyWrapRequest is #21.
type DeleteKeyWrapRequest struct {
	CredentialID string      `json:"credential_id"` // b64url
	StepUp       *StepUpWire `json:"step_up"`
}

func (s *Server) handleGetKeyWraps(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	wraps, err := s.AccountKeys.Wraps(r.Context(), userID)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out := KeyWrapsResponse{Wraps: make([]KeyWrap, 0, len(wraps))}
	for _, x := range wraps {
		out.Wraps = append(out.Wraps, KeyWrap{CredentialID: b64url(x.CredentialID), Wrap: b64(x.Wrap),
			WrapVersion: x.WrapVersion, CreatedAt: x.CreatedAt})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handlePutKeyWrap(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PutKeyWrapRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	cred, ok := b64urlField(w, req.CredentialID, "credential_id")
	if !ok {
		return
	}
	wrap, ok := b64Field(w, req.Wrap, "wrap")
	if !ok {
		return
	}
	sig, ok := b64Field(w, req.DWKSig, "dwk_sig")
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
	if !s.requireBound(w, r, info) {
		return
	}
	if err := s.AccountKeys.PutWrap(r.Context(), info, auth.WrapPut{
		CredentialID: cred, Wrap: wrap, WrapVersion: req.WrapVersion, DWKSig: sig, StepUp: su,
	}); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// A step-up action: the other devices hear of it (spec 02 §8.1 step 6).
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteKeyWrap(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req DeleteKeyWrapRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	cred, ok := b64urlField(w, req.CredentialID, "credential_id")
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
	if err := s.AccountKeys.DeleteWrap(r.Context(), info, cred, su); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}
