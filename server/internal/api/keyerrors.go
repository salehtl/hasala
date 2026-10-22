package api

// keyerrors.go: what the key, writer and step-up routes share — the calling
// session's binding, the writer-bound (WB) check, the step_up object's wire
// form, b64 decoding, and the one mapping from auth's errors to spec 02 §6.3's
// codes. Detail is only ever about the caller's own submission and is empty on
// every 403.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/oplog"
)

// sessionInfo resolves the calling session's binding. requireSession has
// already validated the token, so a failure here is a 401 on a token that
// expired in between, or a 500.
func (s *Server) sessionInfo(w http.ResponseWriter, r *http.Request) (auth.SessionInfo, bool) {
	if info, ok := r.Context().Value(sessionCtxKey{}).(auth.SessionInfo); ok {
		return info, true
	}
	token, ok := bearerToken(r)
	if !ok {
		writeUnauthorized(w)
		return auth.SessionInfo{}, false
	}
	info, err := s.Sessions.Info(r.Context(), token)
	if err != nil {
		if errors.Is(err, auth.ErrSessionInvalid) {
			writeUnauthorized(w)
			return auth.SessionInfo{}, false
		}
		s.logf("api: %s: session binding: %v", route(r), err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return auth.SessionInfo{}, false
	}
	return info, true
}

// requireBound is the WB check (spec 02 §9.4): the session is bound to a writer
// and that writer is live. An unbound session is 403 writer_unbound, a revoked
// writer 403 writer_revoked.
func (s *Server) requireBound(w http.ResponseWriter, r *http.Request, info auth.SessionInfo) bool {
	if info.WriterID == "" {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return false
	}
	var live bool
	err := s.Pool.QueryRow(r.Context(),
		`SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`, info.UserID, info.WriterID).Scan(&live)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return false
	}
	if err != nil {
		s.logf("api: %s: bound writer: %v", route(r), err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return false
	}
	if !live {
		writeErr(w, http.StatusForbidden, "writer_revoked", "")
		return false
	}
	return true
}

// StepUpProofWire is step_up.proof on the wire (spec 02 §7).
type StepUpProofWire struct {
	Kind      string          `json:"kind"`
	Assertion json.RawMessage `json:"assertion,omitempty"`
	WriterID  string          `json:"writer_id,omitempty"`
	Sig       string          `json:"sig,omitempty"`      // b64, 64 bytes P-256 r ‖ s
	Verifier  string          `json:"verifier,omitempty"` // b64, 32 bytes
	Code      string          `json:"code,omitempty"`
}

// StepUpWire is the step_up object of every SU route.
type StepUpWire struct {
	Nonce string          `json:"nonce"` // b64url, from #9
	Proof StepUpProofWire `json:"proof"`
}

// decodeStepUp turns the wire object into auth's; nil in, nil out (a missing
// step-up is the route's 403 step_up_required, decided by auth).
func decodeStepUp(w http.ResponseWriter, su *StepUpWire) (*auth.StepUpObject, bool) {
	if su == nil {
		return nil, true
	}
	nonce, err := base64.RawURLEncoding.DecodeString(su.Nonce)
	if err != nil || len(nonce) != 32 {
		writeErr(w, http.StatusBadRequest, "bad_request", "step_up.nonce is not 32 bytes of b64url")
		return nil, false
	}
	o := &auth.StepUpObject{Nonce: nonce, Proof: auth.StepUpProof{
		Kind: su.Proof.Kind, Assertion: su.Proof.Assertion, WriterID: su.Proof.WriterID, Code: su.Proof.Code,
	}}
	if su.Proof.Sig != "" {
		if o.Proof.Sig, err = base64.StdEncoding.DecodeString(su.Proof.Sig); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "step_up.proof.sig is not base64")
			return nil, false
		}
	}
	if su.Proof.Verifier != "" {
		if o.Proof.Verifier, err = base64.StdEncoding.DecodeString(su.Proof.Verifier); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "step_up.proof.verifier is not base64")
			return nil, false
		}
	}
	return o, true
}

// b64Field decodes one standard-base64 field (spec 02 §6: b64 = RFC 4648 §4
// with padding), or writes a 400 naming it.
func b64Field(w http.ResponseWriter, value, field string) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(value)
	if err != nil || value == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", field+" is not base64")
		return nil, false
	}
	return b, true
}

// b64urlField decodes one b64url field (no padding), or writes a 400.
func b64urlField(w http.ResponseWriter, value, field string) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || value == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", field+" is not b64url")
		return nil, false
	}
	return b, true
}

// b64std decodes standard base64; an error yields nil, which every caller
// treats as a failed proof.
func b64std(v string) ([]byte, error) { return base64.StdEncoding.DecodeString(v) }

var (
	b64    = base64.StdEncoding.EncodeToString
	b64url = base64.RawURLEncoding.EncodeToString
)

// writeKeyErr maps auth's key, writer and step-up errors (and oplog's upload
// ones) to spec 02 §6.3. The reason goes to the operator log.
func (s *Server) writeKeyErr(w http.ResponseWriter, r *http.Request, err error) {
	s.logf("api: %s: %v", route(r), err)
	type m struct {
		target error
		status int
		code   string
	}
	for _, x := range []m{
		{auth.ErrStepUpRequired, http.StatusForbidden, "step_up_required"},
		{auth.ErrStepUpFailed, http.StatusForbidden, "step_up_failed"},
		{auth.ErrStepUpBadRequest, http.StatusBadRequest, "bad_request"},
		{auth.ErrWriterUnbound, http.StatusForbidden, "writer_unbound"},
		{auth.ErrKeysRequired, http.StatusForbidden, "keys_required"},
		{oplog.ErrKeysRequired, http.StatusForbidden, "keys_required"},
		{auth.ErrBadWriterID, http.StatusBadRequest, "bad_writer_id"},
		{auth.ErrWriterMalformed, http.StatusBadRequest, "bad_request"},
		{auth.ErrKeysMalformed, http.StatusBadRequest, "bad_request"},
		{auth.ErrBadSignature, http.StatusBadRequest, "bad_signature"},
		{oplog.ErrHeadSignature, http.StatusBadRequest, "bad_signature"},
		{auth.ErrTooManyDevices, http.StatusConflict, "too_many_devices"},
		{auth.ErrHeadMoved, http.StatusConflict, "head_moved"},
		{auth.ErrNoSuchWriter, http.StatusNotFound, "not_found"},
		{auth.ErrNotYours, http.StatusNotFound, "not_found"},
		{auth.ErrWriterRevoked, http.StatusForbidden, "writer_revoked"},
		{oplog.ErrWriterRevoked, http.StatusForbidden, "writer_revoked"},
		{oplog.ErrUnknownWriter, http.StatusForbidden, "writer_unbound"},
		{auth.ErrSessionBound, http.StatusConflict, "session_bound"},
		{auth.ErrKeysExist, http.StatusConflict, "keys_exist"},
		{auth.ErrNoKeys, http.StatusNotFound, "no_keys"},
		{auth.ErrPhraseUnseen, http.StatusConflict, "phrase_unseen"},
		{auth.ErrBadAuthorityKey, http.StatusBadRequest, "bad_request"},
		// The account ceremonies (spec 02 §6.3).
		{auth.ErrCodeRejected, http.StatusForbidden, "code_rejected"},
		{auth.ErrRateLimited, http.StatusTooManyRequests, "rate_limited"},
		{auth.ErrEmailInUse, http.StatusConflict, "email_in_use"},
		{auth.ErrNotInvited, http.StatusForbidden, "not_invited"},
		{auth.ErrPasswordRejected, http.StatusForbidden, "password_rejected"},
		{auth.ErrRecoveryRefused, http.StatusForbidden, "recovery_refused"},
		{auth.ErrResetRefused, http.StatusForbidden, "reset_refused"},
		{auth.ErrNotApproved, http.StatusConflict, "not_approved"},
		{auth.ErrFreezeRefused, http.StatusForbidden, "freeze_refused"},
		{auth.ErrAccountFrozen, http.StatusForbidden, "account_frozen"},
		{auth.ErrConflict, http.StatusConflict, "conflict"},
		{auth.ErrLastAuthenticator, http.StatusConflict, "last_authenticator"},
		{auth.ErrLastPasskey, http.StatusConflict, "last_authenticator"},
		{auth.ErrBadEmail, http.StatusBadRequest, "bad_email"},
		{auth.ErrBadRequest, http.StatusBadRequest, "bad_request"},
		{auth.ErrNoSuchAccount, http.StatusNotFound, "not_found"},
		{auth.ErrPasskeyRejected, http.StatusForbidden, "passkey_rejected"},
	} {
		if errors.Is(err, x.target) {
			if x.status == http.StatusTooManyRequests {
				w.Header().Set("Retry-After", "60")
			}
			writeErr(w, x.status, x.code, "")
			return
		}
	}
	switch {
	case errors.Is(err, auth.ErrBadName):
		detail := "display_name: characters"
		if errors.Is(err, auth.ErrBadNameLength) {
			detail = "display_name: length"
		}
		writeErr(w, http.StatusBadRequest, "bad_name", detail)
		return
	case errors.Is(err, auth.ErrUnavailable):
		w.Header().Set("Retry-After", "2")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	writeErr(w, http.StatusInternalServerError, "internal", "")
}
