package api

import (
	"net/http"
	"time"

	"github.com/salehtl/hasala/server/internal/auth"
)

// routes_signup.go: signup begin and verify and password signup (spec 02
// §10.7, routes #43–#45). Owner: WS-3. Mounted only with the account
// ceremonies enabled (EnableAccounts): they need the server's key files.
func (s *Server) mountSignup(mux *http.ServeMux) {
	if s.Accounts == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/signup/begin", s.limited(s.handleSignupBegin, s.PasskeyPerIP, s.PasskeyGlobal))
	mux.HandleFunc("POST /api/v1/auth/signup/verify", s.limited(s.handleSignupVerify, s.PasskeyPerIP, s.CodePerIP))
	mux.HandleFunc("POST /api/v1/auth/password/register", s.limited(s.handlePasswordRegister, s.PasskeyPerIP, s.PasskeyGlobal))
}

// SignupBeginRequest is #43's body.
type SignupBeginRequest struct {
	InviteCode    string `json:"invite_code"`
	Email         string `json:"email"`
	DisplayName   string `json:"display_name"`
	InviteLinkKey string `json:"invite_link_key,omitempty"` // 43 b64url, only from the invite link's fragment
}

// SignupBeginResponse is #43's answer.
type SignupBeginResponse struct {
	SignupID    string    `json:"signup_id"`
	UserID      string    `json:"user_id"`
	EmailProven bool      `json:"email_proven"`
	Salt        string    `json:"salt"`  // b64
	Nonce       string    `json:"nonce"` // b64
	ExpiresAt   time.Time `json:"expires_at"`
}

func (s *Server) handleSignupBegin(w http.ResponseWriter, r *http.Request) {
	var req SignupBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	out, err := s.Accounts.SignupBegin(r.Context(), auth.SignupBeginRequest{InviteCode: req.InviteCode,
		Email: req.Email, DisplayName: req.DisplayName, InviteLinkKey: req.InviteLinkKey})
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, SignupBeginResponse{SignupID: out.SignupID, UserID: out.UserID.String(),
		EmailProven: out.EmailProven, Salt: b64(out.Salt), Nonce: b64(out.Nonce), ExpiresAt: out.ExpiresAt.UTC()})
}

// SignupVerifyRequest is #44's body.
type SignupVerifyRequest struct {
	SignupID string `json:"signup_id"`
	Code     string `json:"code"`
}

func (s *Server) handleSignupVerify(w http.ResponseWriter, r *http.Request) {
	var req SignupVerifyRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if err := s.Accounts.SignupVerify(r.Context(), req.SignupID, req.Code); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// PasswordRegisterRequest is #45's body: the signup, S, and the §10.1 fields
// with auth_kind 2, auth_hash = SHA256(S) and nonce = the signup nonce.
type PasswordRegisterRequest struct {
	SignupID  string           `json:"signup_id"`
	Verifier  string           `json:"verifier"` // b64, 32 bytes
	Bootstrap BootstrapRequest `json:"bootstrap"`
}

// SessionMintResponse is #4's and #54's answer.
type SessionMintResponse struct {
	SessionToken string    `json:"session_token"`
	UserID       string    `json:"user_id"`
	ExpiresAt    time.Time `json:"expires_at"`
}

// WriterSessionResponse is #8's and #45's answer: the session is bound to the
// writer the same request registered.
type WriterSessionResponse struct {
	SessionToken string    `json:"session_token"`
	UserID       string    `json:"user_id"`
	ExpiresAt    time.Time `json:"expires_at"`
	WriterID     string    `json:"writer_id"`
}

// SignInResponse is #6's and #47's answer.
type SignInResponse struct {
	SessionToken string    `json:"session_token"`
	UserID       string    `json:"user_id"`
	ExpiresAt    time.Time `json:"expires_at"`
	WriterID     *string   `json:"writer_id"`
	HasKeys      bool      `json:"has_keys"`
	Restricted   bool      `json:"restricted"`
}

func signInResponse(in auth.SignedIn) SignInResponse {
	out := SignInResponse{SessionToken: in.Session.Token, UserID: in.UserID.String(),
		ExpiresAt: in.Session.ExpiresAt.UTC(), HasKeys: in.HasKeys, Restricted: in.Restricted}
	if in.WriterID != "" {
		w := in.WriterID
		out.WriterID = &w
	}
	return out
}

func (s *Server) handlePasswordRegister(w http.ResponseWriter, r *http.Request) {
	var req PasswordRegisterRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if req.Bootstrap.StepUp != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "a password signup carries no step_up")
		return
	}
	v, ok := b64Field(w, req.Verifier, "verifier")
	if !ok {
		return
	}
	b, ok := decodeBootstrap(w, req.Bootstrap)
	if !ok {
		return
	}
	out, err := s.Accounts.PasswordSignup(r.Context(), req.SignupID, v, b)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, WriterSessionResponse{SessionToken: out.Session.Token, UserID: out.UserID.String(),
		ExpiresAt: out.Session.ExpiresAt.UTC(), WriterID: out.WriterID})
}
