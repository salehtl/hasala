package api

import (
	"encoding/json"
	"net/http"

	"github.com/salehtl/hasala/server/internal/auth"
)

// routes_recover.go: access recovery with an email code and the phrase (C4,
// spec 02 §10.4, routes #7, #48, #8). Owner: WS-3.
func (s *Server) mountRecover(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/recover/begin", s.limited(s.handleRecoverBegin, s.RecoverPerIP, s.PasskeyGlobal))
	mux.HandleFunc("POST /api/v1/auth/recover/verify", s.limited(s.handleRecoverVerify, s.RecoverPerIP, s.CodePerIP))
	mux.HandleFunc("POST /api/v1/auth/recover/finish", s.limited(s.handleRecoverFinish, s.RecoverPerIP, s.PasskeyGlobal))
}

// RecoverBeginRequest is #7's body.
type RecoverBeginRequest struct {
	RecoveryPubkey string `json:"recovery_pubkey"` // b64, 32 bytes
}

// RecoverBeginResponse is #7's answer.
type RecoverBeginResponse struct {
	CeremonyID string `json:"ceremony_id"`
	EmailHint  string `json:"email_hint"`
}

func (s *Server) handleRecoverBegin(w http.ResponseWriter, r *http.Request) {
	var req RecoverBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	rk, ok := b64Field(w, req.RecoveryPubkey, "recovery_pubkey")
	if !ok {
		return
	}
	out, err := s.Accounts.RecoverBegin(r.Context(), rk)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, RecoverBeginResponse{CeremonyID: out.CeremonyID, EmailHint: out.EmailHint})
}

// RecoverVerifyRequest is #48's body.
type RecoverVerifyRequest struct {
	CeremonyID string `json:"ceremony_id"`
	Code       string `json:"code"`
	Kind       string `json:"kind"` // passkey | password
}

// RecoverVerifyResponse is #48's answer.
type RecoverVerifyResponse struct {
	Nonce           string          `json:"nonce"`
	UserID          string          `json:"user_id"`
	AMKCommitment   string          `json:"amk_commitment"`
	AuthorityPubkey string          `json:"authority_pubkey"`
	RecoveryWrap    string          `json:"recovery_wrap"`
	CurrentEpoch    int             `json:"current_epoch"`
	Options         json.RawMessage `json:"options,omitempty"`
	Salt            string          `json:"salt,omitempty"`
}

func (s *Server) handleRecoverVerify(w http.ResponseWriter, r *http.Request) {
	var req RecoverVerifyRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	out, err := s.Accounts.RecoverVerify(r.Context(), req.CeremonyID, req.Code, req.Kind)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	resp := RecoverVerifyResponse{Nonce: b64(out.Nonce), UserID: out.UserID.String(), AMKCommitment: b64(out.AMKCommitment),
		AuthorityPubkey: b64(out.AuthorityPubkey), RecoveryWrap: b64(out.RecoveryWrap), CurrentEpoch: out.CurrentEpoch}
	if out.Options != nil {
		raw, err := json.Marshal(out.Options)
		if err != nil {
			s.writeKeyErr(w, r, err)
			return
		}
		resp.Options = raw
	} else {
		resp.Salt = b64(out.Salt)
	}
	writeJSON(w, http.StatusOK, resp)
}

// RecoverWriterWire is the writer #8 registers.
type RecoverWriterWire struct {
	WriterID        string `json:"writer_id"`
	Alg             string `json:"alg"`
	PubKey          string `json:"pubkey"`           // b64, 32
	DAKPubkey       string `json:"dak_pubkey"`       // b64, 65
	RegistrationSig string `json:"registration_sig"` // b64, 64: the AAK over RegistrationMessage(recover nonce, …)
}

// RecoverFinishRequest is #8's body (either kind).
type RecoverFinishRequest struct {
	CeremonyID string            `json:"ceremony_id"`
	Kind       string            `json:"kind"`
	Credential json.RawMessage   `json:"credential,omitempty"`
	PRFWrap    *BootstrapPRFWrap `json:"prf_wrap,omitempty"`
	Verifier   string            `json:"verifier,omitempty"`
	RKSig      string            `json:"rk_sig"`
	Writer     RecoverWriterWire `json:"writer"`
}

func (s *Server) handleRecoverFinish(w http.ResponseWriter, r *http.Request) {
	var req RecoverFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	in := auth.RecoverFinishRequest{CeremonyID: req.CeremonyID, Kind: req.Kind, Credential: req.Credential}
	var ok bool
	if in.RKSig, ok = b64Field(w, req.RKSig, "rk_sig"); !ok {
		return
	}
	switch req.Kind {
	case auth.MethodPasskey:
		if len(req.Credential) == 0 || req.Verifier != "" {
			writeErr(w, http.StatusBadRequest, "bad_request", "a passkey recovery carries a credential and no verifier")
			return
		}
		if req.PRFWrap != nil {
			if in.PRFCredentialID, ok = b64urlField(w, req.PRFWrap.CredentialID, "prf_wrap.credential_id"); !ok {
				return
			}
			if in.PRFWrap, ok = b64Field(w, req.PRFWrap.Wrap, "prf_wrap.wrap"); !ok {
				return
			}
			in.PRFWrapVersion = req.PRFWrap.WrapVersion
		}
	case auth.MethodPassword:
		if len(req.Credential) != 0 || req.PRFWrap != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "a password recovery carries a verifier and no credential")
			return
		}
		if in.Verifier, ok = b64Field(w, req.Verifier, "verifier"); !ok {
			return
		}
	default:
		writeErr(w, http.StatusBadRequest, "bad_request", "kind is passkey or password")
		return
	}
	in.Writer = auth.Registration{WriterID: req.Writer.WriterID, Alg: req.Writer.Alg}
	if in.Writer.PubKey, ok = b64Field(w, req.Writer.PubKey, "writer.pubkey"); !ok {
		return
	}
	if in.Writer.DAKPubkey, ok = b64Field(w, req.Writer.DAKPubkey, "writer.dak_pubkey"); !ok {
		return
	}
	if in.Writer.Sig, ok = b64Field(w, req.Writer.RegistrationSig, "writer.registration_sig"); !ok {
		return
	}
	out, err := s.Accounts.RecoverFinish(r.Context(), in)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, WriterSessionResponse{SessionToken: out.Session.Token, UserID: out.UserID.String(),
		ExpiresAt: out.Session.ExpiresAt.UTC(), WriterID: out.WriterID})
}
