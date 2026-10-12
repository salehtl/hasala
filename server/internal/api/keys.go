package api

// keys.go serves the account's key material (spec 02 #17, #18; spec 01 §4–§5,
// §10.3): GET /api/v1/keys and the atomic bootstrap. ledgerd's write-once
// PUT /api/v1/keys is retired (spec 02 §2.4): keys arrive only through the
// bootstrap, signed by the authority key the account-creating ceremony bound.
//
// What the server stores is opaque: the AMK commitment and the authority and
// recovery public keys (published so every device can check what it
// unwrapped), the 127-byte recovery wrap and the 45-byte phrase box, which only
// the phrase.view step-up ever returns (it is never in GET /keys). It holds no
// key that opens any of them.

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
)

// KeysResponse answers GET /api/v1/keys (#17). Never the phrase box.
type KeysResponse struct {
	FormatVersion   int       `json:"format_version"`
	AMKCommitment   string    `json:"amk_commitment"`   // b64
	AuthorityPubkey string    `json:"authority_pubkey"` // b64
	RecoveryPubkey  string    `json:"recovery_pubkey"`  // b64
	RecoveryWrap    string    `json:"recovery_wrap"`    // b64, 127 bytes
	CurrentEpoch    int       `json:"current_epoch"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

func (s *Server) handleGetKeys(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	k, err := s.AccountKeys.Read(r.Context(), userID)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, KeysResponse{
		FormatVersion: k.FormatVersion, AMKCommitment: b64(k.AMKCommitment), AuthorityPubkey: b64(k.AuthorityPubkey),
		RecoveryPubkey: b64(k.RecoveryPubkey), RecoveryWrap: b64(k.RecoveryWrap), CurrentEpoch: k.CurrentEpoch,
		CreatedAt: k.CreatedAt, UpdatedAt: k.UpdatedAt,
	})
}

// BootstrapPRFWrap is the optional PRF wrap of a bootstrap.
type BootstrapPRFWrap struct {
	CredentialID string `json:"credential_id"` // b64url
	Wrap         string `json:"wrap"`          // b64, 127 bytes
	WrapVersion  int    `json:"wrap_version"`
}

// BootstrapWriter is the first writer of a bootstrap.
type BootstrapWriter struct {
	WriterID  string `json:"writer_id"`
	Alg       string `json:"alg"`
	PubKey    string `json:"pubkey"`     // b64, 32
	DAKPubkey string `json:"dak_pubkey"` // b64, 65
}

// BootstrapRequest is POST /api/v1/account/bootstrap (spec 02 §10.1).
type BootstrapRequest struct {
	FormatVersion   int               `json:"format_version"`
	AMKCommitment   string            `json:"amk_commitment"`
	AuthorityPubkey string            `json:"authority_pubkey"`
	RecoveryPubkey  string            `json:"recovery_pubkey"`
	RecoveryWrap    string            `json:"recovery_wrap"`
	PhraseBox       string            `json:"phrase_box"`
	EmailHash       string            `json:"email_hash"`
	AuthKind        int               `json:"auth_kind"`
	AuthHash        string            `json:"auth_hash"`
	PRFWrap         *BootstrapPRFWrap `json:"prf_wrap"`
	Writer          BootstrapWriter   `json:"writer"`
	Nonce           string            `json:"nonce"`
	AuthoritySig    string            `json:"authority_sig"`
	RegistrationSig string            `json:"registration_sig"`
	StepUp          *StepUpWire       `json:"step_up,omitempty"`
}

// BootstrapResponse is #18's 201.
type BootstrapResponse struct {
	WriterID     string `json:"writer_id"`
	CurrentEpoch int    `json:"current_epoch"`
}

func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req BootstrapRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	b, ok := decodeBootstrap(w, req)
	if !ok {
		return
	}
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	b.StepUp = su
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	out, err := s.AccountKeys.Bootstrap(r.Context(), info, b)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, BootstrapResponse{WriterID: out.WriterID, CurrentEpoch: out.CurrentEpoch})
}

// decodeBootstrap decodes the §10.1 fields (everything but step_up).
func decodeBootstrap(w http.ResponseWriter, req BootstrapRequest) (auth.Bootstrap, bool) {
	b := auth.Bootstrap{FormatVersion: req.FormatVersion, AuthKind: req.AuthKind}
	for _, f := range []struct {
		dst   *[]byte
		value string
		name  string
	}{
		{&b.AMKCommitment, req.AMKCommitment, "amk_commitment"},
		{&b.AuthorityPubkey, req.AuthorityPubkey, "authority_pubkey"},
		{&b.RecoveryPubkey, req.RecoveryPubkey, "recovery_pubkey"},
		{&b.RecoveryWrap, req.RecoveryWrap, "recovery_wrap"},
		{&b.PhraseBox, req.PhraseBox, "phrase_box"},
		{&b.EmailHash, req.EmailHash, "email_hash"},
		{&b.AuthHash, req.AuthHash, "auth_hash"},
		{&b.Writer.PubKey, req.Writer.PubKey, "writer.pubkey"},
		{&b.Writer.DAKPubkey, req.Writer.DAKPubkey, "writer.dak_pubkey"},
		{&b.Writer.Nonce, req.Nonce, "nonce"},
		{&b.AuthoritySig, req.AuthoritySig, "authority_sig"},
		{&b.Writer.Sig, req.RegistrationSig, "registration_sig"},
	} {
		v, ok := b64Field(w, f.value, f.name)
		if !ok {
			return auth.Bootstrap{}, false
		}
		*f.dst = v
	}
	b.Writer.WriterID, b.Writer.Alg = req.Writer.WriterID, req.Writer.Alg
	if req.PRFWrap != nil {
		cred, ok := b64urlField(w, req.PRFWrap.CredentialID, "prf_wrap.credential_id")
		if !ok {
			return auth.Bootstrap{}, false
		}
		wrap, ok := b64Field(w, req.PRFWrap.Wrap, "prf_wrap.wrap")
		if !ok {
			return auth.Bootstrap{}, false
		}
		b.PRFCredentialID, b.PRFWrap, b.PRFWrapVersion = cred, wrap, req.PRFWrap.WrapVersion
	}
	return b, true
}
