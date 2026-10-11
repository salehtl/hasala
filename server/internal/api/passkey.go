package api

// The passkey routes, kept from ledgerd as hasala's passkey door until WS-3
// lands spec 02 §8's sign-in surface (passwords, Google, Apple). ledgerd's
// ID-token exchange is retired (spec 02 §2).
//
//	POST /api/v1/auth/passkey/register/begin   {invite_code}            -> {ceremony_id, options}
//	POST /api/v1/auth/passkey/register/finish  {ceremony_id, credential} -> {session_token, user_id}
//	POST /api/v1/auth/passkey/login/begin      {}                       -> {ceremony_id, options}
//	POST /api/v1/auth/passkey/login/finish     {ceremony_id, credential} -> {session_token, user_id}
//	POST /api/v1/auth/passkey/add/begin        {step_up}   (S + WB)      -> {ceremony_id, options}
//	POST /api/v1/auth/passkey/add/finish       {ceremony_id, credential, prf_wrap, dwk_sig} (S + WB) -> 201 {credential_id}
//
// Adding a passkey is spec 02 #10/#11 (§10.5): add/begin consumes step-up
// passkey.add and the ceremony keeps its nonce; add/finish needs the session
// writer's DWK over PasskeyAddMessage (R-01). See auth/passkey_guarded.go.
//
// `options` is go-webauthn's own protocol.CredentialCreation /
// CredentialAssertion, marshalled as-is and passed to the browser untouched.
// That is deliberate: the browser's `navigator.credentials` consumes exactly this
// shape, and any reshaping here would be a second encoder to keep in step with a
// specification neither side owns.
//
// # What these endpoints answer
//
// Everything collapses to the package's ONE 401, with a single exception:
// `403 {"error":"not_invited"}`
// when account creation was required and no unredeemed code authorized it. That
// is a fact about this deployment's policy rather than about the credential, and
// it is the one thing the person holding the phone needs to know.
//
// A rejected ceremony never says WHY. auth returns distinct sentinels — expired,
// replayed, unknown credential, cloned authenticator — and every one of them is a
// useful log line and an oracle in a response.
//
// # Why all six are rate limited
//
// Four of them are unauthenticated, and every begin MINTS A ROW. An endpoint that
// writes server-side state for anyone holding a socket is a memory- and
// disk-growth target, and the sweep that removes expired ceremonies runs on a
// timer, so the table's steady-state size is set by the mint rate. The two `add`
// routes are session-authenticated and limited on the same budget, because the
// limiter runs BEFORE the session is resolved — see requirePasskeySession and
// passkeyLimited for the ordering argument.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// Rate-limit budget. The shape of the legitimate traffic is a person signing in:
// a couple of ceremonies, occasionally retried when a browser prompt is
// dismissed, and then nothing for hours. The burst is therefore generous enough
// to survive a user who cancels the system dialog three times, and the sustained
// rate is mean.
//
// It is deliberately looser than the challenge budgets (1/minute), because a
// person dismissing a system prompt is a retry, not an attack.
const (
	passkeyPerIPRate   = 0.2 // 12/minute sustained
	passkeyPerIPBurst  = 12
	passkeyMaxKeys     = 4096
	passkeyGlobalRate  = 20
	passkeyGlobalBurst = 100
)

// PasskeyRegisterBeginRequest starts a sign-up. authority_pubkey (b64, the
// AAK the device just generated) is bound into the ceremony's challenge:
// C_reg = SHA256("hasala/v1/register" ‖ 00 ‖ nonce ‖ authority_pubkey) (spec
// 01 §10.3, D01; spec 02 #3).
//
// invite_link_key is optional: the 43-character b64url fragment of the invite
// link (spec 02 §14.1, `07` §4.4). An addressed invite is refused without it.
type PasskeyRegisterBeginRequest struct {
	InviteCode      string `json:"invite_code"`
	InviteLinkKey   string `json:"invite_link_key,omitempty"`
	AuthorityPubkey string `json:"authority_pubkey"`
}

// PasskeyRegisterBeginResponse adds the register nonce, so the client can
// recompute C_reg and refuse options whose challenge differs (spec 01 §10.3
// step 6).
type PasskeyRegisterBeginResponse struct {
	CeremonyID string          `json:"ceremony_id"`
	Nonce      string          `json:"nonce"` // b64
	Options    json.RawMessage `json:"options"`
}

// PasskeyBeginResponse is what all three begin steps answer with. Options is
// go-webauthn's own structure, embedded verbatim.
type PasskeyBeginResponse struct {
	CeremonyID string          `json:"ceremony_id"`
	Options    json.RawMessage `json:"options"`
}

// PasskeyFinishRequest carries the browser's response to a ceremony.
//
// Credential is the raw PublicKeyCredential JSON, forwarded to go-webauthn's own
// parser without being decoded here. This package therefore never has to agree
// with the library about the shape of an attestation object, which is the sort of
// disagreement that produces a verifier that accepts something it should not.
type PasskeyFinishRequest struct {
	CeremonyID string          `json:"ceremony_id"`
	Credential json.RawMessage `json:"credential"`
}

// PasskeyAddBeginRequest is #10: the passkey.add step-up (T = ()).
type PasskeyAddBeginRequest struct {
	StepUp *StepUpWire `json:"step_up"`
}

// PasskeyAddFinishRequest is #11. PRFWrap is null when the device had no
// account body to wrap (spec 01 §10.7 step 1); DWKSig is the session writer's
// DWK over PasskeyAddMessage.
type PasskeyAddFinishRequest struct {
	CeremonyID string            `json:"ceremony_id"`
	Credential json.RawMessage   `json:"credential"`
	PRFWrap    *BootstrapPRFWrap `json:"prf_wrap"`
	DWKSig     string            `json:"dwk_sig"` // b64
}

// PasskeyAddResponse names the credential that was enrolled, b64url (spec 02
// #11).
type PasskeyAddResponse struct {
	CredentialID string `json:"credential_id"`
}

// passkeyLimited wraps a handler in the two limiters, in the order that matters:
// per-IP first, and a global token is spent only by a request that already passed
// it. The other order lets one host drain the shared budget
// with requests the per-IP limiter was about to refuse anyway, and hold every
// other client at 429 indefinitely.
func (s *Server) passkeyLimited(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.PasskeyPerIP.Allow(clientKey(r)) || !s.PasskeyGlobal.Allow("") {
			writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many passkey attempts")
			return
		}
		h(w, r)
	}
}

// passkeyLimitedSession is passkeyLimited for the two authenticated routes. The
// limiter runs BEFORE requireSession, so a caller with no session at all still
// spends a token: otherwise the cheapest way to bypass the limit would be to omit
// the credential.
func (s *Server) passkeyLimitedSession(h authedHandler) http.HandlerFunc {
	return s.passkeyLimited(s.requireSession(h))
}

func (s *Server) handlePasskeyRegisterBegin(w http.ResponseWriter, r *http.Request) {
	var req PasskeyRegisterBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	authority, err := base64.StdEncoding.DecodeString(req.AuthorityPubkey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "authority_pubkey is not base64")
		return
	}
	var linkKey []byte
	if req.InviteLinkKey != "" {
		linkKey, err = base64.RawURLEncoding.DecodeString(req.InviteLinkKey)
		if err != nil || len(req.InviteLinkKey) != 43 || len(linkKey) != invites.LinkKeyBytes {
			writeErr(w, http.StatusBadRequest, "bad_request", "invite_link_key must be 43 b64url characters")
			return
		}
	}
	id, opts, nonce, err := s.Passkeys.BeginRegistrationLinked(r.Context(), req.InviteCode, linkKey, authority)
	if err != nil {
		if errors.Is(err, auth.ErrBadAuthorityKey) {
			writeErr(w, http.StatusBadRequest, "bad_request", "authority_pubkey is not a usable Ed25519 public key")
			return
		}
		s.writePasskeyError(w, r, "register/begin", err)
		return
	}
	raw, err := json.Marshal(opts)
	if err != nil {
		s.logf("api: passkey register/begin: marshal options: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, PasskeyRegisterBeginResponse{CeremonyID: id, Nonce: b64(nonce), Options: raw})
}

func (s *Server) handlePasskeyRegisterFinish(w http.ResponseWriter, r *http.Request) {
	var req PasskeyFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	userID, credID, err := s.Passkeys.FinishRegistration(r.Context(), req.CeremonyID, req.Credential)
	if err != nil {
		s.writePasskeyError(w, r, "register/finish", err)
		return
	}
	s.writeSession(w, r, userID, credID)
}

func (s *Server) handlePasskeyLoginBegin(w http.ResponseWriter, r *http.Request) {
	// No body is read: a discoverable login carries nothing at all. Anything the
	// caller sent is ignored rather than refused, because a client that posts
	// `{}` and a client that posts nothing are both correct here.
	id, opts, err := s.Passkeys.BeginLogin(r.Context())
	if err != nil {
		s.writePasskeyError(w, r, "login/begin", err)
		return
	}
	s.writeBegin(w, r, id, opts)
}

func (s *Server) handlePasskeyLoginFinish(w http.ResponseWriter, r *http.Request) {
	var req PasskeyFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	userID, credID, err := s.Passkeys.FinishLogin(r.Context(), req.CeremonyID, req.Credential)
	if err != nil {
		s.writePasskeyError(w, r, "login/finish", err)
		return
	}
	s.writeSession(w, r, userID, credID)
}

func (s *Server) handlePasskeyAddBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PasskeyAddBeginRequest
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
	if !s.requireBound(w, r, info) {
		return
	}
	id, opts, err := s.Passkeys.AddBegin(r.Context(), info, su)
	if err != nil {
		s.writePasskeyAddErr(w, r, "add/begin", err)
		return
	}
	s.writeBegin(w, r, id, opts)
}

func (s *Server) handlePasskeyAddFinish(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PasskeyAddFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	sig, ok := b64Field(w, req.DWKSig, "dwk_sig")
	if !ok {
		return
	}
	add := auth.PasskeyAdd{CeremonyID: req.CeremonyID, Credential: req.Credential, DWKSig: sig}
	if req.PRFWrap != nil {
		if add.PRFCredentialID, ok = b64urlField(w, req.PRFWrap.CredentialID, "prf_wrap.credential_id"); !ok {
			return
		}
		if add.PRFWrap, ok = b64Field(w, req.PRFWrap.Wrap, "prf_wrap.wrap"); !ok {
			return
		}
		add.PRFWrapVersion = req.PRFWrap.WrapVersion
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if !s.requireBound(w, r, info) {
		return
	}
	credID, err := s.Passkeys.AddFinish(r.Context(), info, add)
	if err != nil {
		s.writePasskeyAddErr(w, r, "add/finish", err)
		return
	}
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	writeJSON(w, http.StatusCreated, PasskeyAddResponse{CredentialID: b64url(credID)})
}

// writePasskeyAddErr answers the add routes: a ceremony rejection is the
// package's one 401 (writePasskeyError), and everything else (step-up, writer
// binding, a bad signature, a malformed wrap) is spec 02 §6.3's code.
func (s *Server) writePasskeyAddErr(w http.ResponseWriter, r *http.Request, step string, err error) {
	if errors.Is(err, auth.ErrPasskeyRejected) {
		s.writePasskeyError(w, r, step, err)
		return
	}
	s.writeKeyErr(w, r, err)
}

// writeBegin marshals go-webauthn's options into the envelope. The options are
// re-marshalled rather than streamed so that a marshalling failure produces a 500
// instead of a half-written 200.
func (s *Server) writeBegin(w http.ResponseWriter, r *http.Request, ceremonyID string, opts any) {
	raw, err := json.Marshal(opts)
	if err != nil {
		s.logf("api: %s %s: marshal ceremony options: %v", r.Method, r.URL.Path, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, PasskeyBeginResponse{CeremonyID: ceremonyID, Options: raw})
}

// SessionResponse carries a session token, returned exactly once, at the end
// of a passkey ceremony.
type SessionResponse struct {
	SessionToken string `json:"session_token"`
	UserID       string `json:"user_id"`
}

// writeSession issues the session a completed sign-in earns, ATTRIBUTED to the
// credential that just finished the ceremony (sessions.credential_id). Both
// callers — register/finish and login/finish — genuinely know it, because
// go-webauthn returns the credential it verified and auth returns it upward.
func (s *Server) writeSession(w http.ResponseWriter, r *http.Request, userID uuid.UUID, credID []byte) {
	token, err := s.Sessions.IssueForCredential(r.Context(), userID, credID)
	if err != nil {
		s.logf("api: %s %s: issue session: %v", r.Method, r.URL.Path, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, SessionResponse{SessionToken: token, UserID: userID.String()})
}

// writePasskeyError is the single translation point, so no handler can invent a
// status of its own.
//
// Two answers only. `not_invited` is the deployment-policy fact, and everything
// else — expired ceremony, replayed ceremony, unknown credential, a signature
// that did not verify, a cloned authenticator — is the one 401. A failure that is
// not a rejection (the database is unreachable) is a 500, on the same reasoning
// requireSession applies: reporting infrastructure trouble as "your credential is
// invalid" sends a user off to re-authenticate for no reason.
func (s *Server) writePasskeyError(w http.ResponseWriter, r *http.Request, step string, err error) {
	switch {
	case errors.Is(err, auth.ErrNotInvited):
		s.logf("api: passkey %s: not invited", step)
		writeErr(w, http.StatusForbidden, "not_invited", "")
	case errors.Is(err, auth.ErrPasskeyRejected):
		// The reason is logged, never returned.
		s.logf("api: passkey %s: rejected: %v", step, err)
		writeUnauthorized(w)
	default:
		s.logf("api: passkey %s: %v", step, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	}
}
