package api

// routes_waitlist.go: spec 07's website routes P1–P3 and P5 (spec 02 §7
// #71–#73, #75): the waitlist submit, the confirm and leave links, and CORS
// for https://hasala.app only. Every valid submission gets the same answer
// whether the address is new, pending, confirmed, invited or already an
// account; the difference is only which email the worker sends later.

import (
	"context"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync/atomic"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/turnstile"
	"github.com/salehtl/hasala/server/internal/waitlist"
)

// Spec 07 §5.9's limiters.
const (
	waitlistIPRate      = 6.0 / 3600
	waitlistIPBurst     = 3
	waitlistGlobalRate  = 120.0 / 3600
	waitlistGlobalBurst = 30
	linkIPRate          = 30.0 / 3600
	linkIPBurst         = 10
	bankIPRate          = 10.0 / 3600
	bankIPBurst         = 5
	bankGlobalRate      = 300.0 / 3600
	bankGlobalBurst     = 60
	bankUserRate        = 10.0 / 86400
	bankUserBurst       = 5
	preflightRate       = 1.0
	preflightBurst      = 30
	publicMaxKeys       = 4096
	publicMaxBody       = 4 << 10
)

// WebOptions configures spec 07's public routes. A nil *WebOptions leaves them
// unmounted (404), which is how a server without an auth key runs.
type WebOptions struct {
	Waitlist *waitlist.Service
	// Origins is HASALA_WEB_ORIGINS; empty turns CORS off (a request with an
	// Origin is then refused).
	Origins []string
	// DoneURL is HASALA_WEB_WAITLIST_DONE_URL, the 303 target of a script-free
	// form post.
	DoneURL string

	WaitlistIP, WaitlistGlobal, LinkIP, BankIP, BankGlobal, BankUser, PreflightIP *Limiter

	Turnstile         TokenVerifier
	TurnstileRequired bool

	// Outcomes counts waitlist_submit's outcome words and the honeypot.
	Honeypot, Submitted atomic.Int64
}

type TokenVerifier interface {
	Verify(ctx context.Context, token, action string) error
}

func (s *Server) turnstileOK(r *http.Request, token, action string) bool {
	o := s.Web
	if o.Turnstile == nil {
		return !o.TurnstileRequired
	}
	if token == "" && !o.TurnstileRequired {
		return true
	}
	err := o.Turnstile.Verify(r.Context(), token, action)
	if err != nil && !errors.Is(err, turnstile.ErrRefused) {
		s.logf("api: turnstile: %v", err)
	}
	return err == nil
}

func (s *Server) mountWaitlist(mux *http.ServeMux) {
	if s.Web == nil {
		return
	}
	o := s.Web
	s.ensureLimiter(&o.WaitlistIP, waitlistIPRate, waitlistIPBurst, publicMaxKeys)
	s.ensureLimiter(&o.WaitlistGlobal, waitlistGlobalRate, waitlistGlobalBurst, 1)
	s.ensureLimiter(&o.LinkIP, linkIPRate, linkIPBurst, publicMaxKeys)
	s.ensureLimiter(&o.BankIP, bankIPRate, bankIPBurst, publicMaxKeys)
	s.ensureLimiter(&o.BankGlobal, bankGlobalRate, bankGlobalBurst, 1)
	s.ensureLimiter(&o.BankUser, bankUserRate, bankUserBurst, publicMaxKeys)
	s.ensureLimiter(&o.PreflightIP, preflightRate, preflightBurst, publicMaxKeys)
	mux.HandleFunc("/api/v1/waitlist", s.publicRoute(s.handleWaitlistSubmit))
	mux.HandleFunc("/api/v1/waitlist/confirm", s.publicRoute(s.handleWaitlistConfirm))
	mux.HandleFunc("/api/v1/waitlist/leave", s.publicRoute(s.handleWaitlistLeave))
	mux.HandleFunc("/api/v1/waitlist/unsubscribe", s.handleWaitlistUnsubscribe)
}

// publicRoute is spec 07 §5.1–§5.2 and §5.7 around one POST handler: the
// method gate (405 with Allow), the CORS origin check, and the preflight.
func (s *Server) publicRoute(post http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodOptions:
			s.handlePreflight(w, r)
			return
		case http.MethodPost:
		default:
			w.Header().Set("Allow", "POST, OPTIONS")
			writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
			return
		}
		if !s.corsAllowed(w, r) {
			return
		}
		post(w, r)
	}
}

// corsAllowed applies the origin rule: no Origin is processed normally; a
// listed one is echoed with Vary; any other is 403 with no CORS header.
func (s *Server) corsAllowed(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	if !slices.Contains(s.Web.Origins, origin) {
		writeErr(w, http.StatusForbidden, "origin_refused", "")
		return false
	}
	w.Header().Set("Access-Control-Allow-Origin", origin)
	w.Header().Add("Vary", "Origin")
	return true
}

func (s *Server) handlePreflight(w http.ResponseWriter, r *http.Request) {
	if !s.Web.PreflightIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	origin := r.Header.Get("Origin")
	if origin == "" || !slices.Contains(s.Web.Origins, origin) || r.Header.Get("Access-Control-Request-Method") != "POST" {
		writeErr(w, http.StatusForbidden, "origin_refused", "")
		return
	}
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Access-Control-Allow-Methods", "POST")
	h.Set("Access-Control-Allow-Headers", "Content-Type")
	h.Set("Access-Control-Max-Age", "600")
	h.Add("Vary", "Origin")
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// publicBody is the union of P1's and P4's fields, JSON or form.
type publicBody struct {
	Email          string `json:"email"`
	Bank           string `json:"bank"`
	OtherBank      string `json:"otherBank"`
	Source         string `json:"source"`
	Website        string `json:"website"`
	TurnstileToken string `json:"turnstileToken"`
	Token          string `json:"token"`
}

// formKeys maps a form field to the body field it fills (P1, P4).
var formKeys = map[string]func(*publicBody) *string{
	"email":                 func(b *publicBody) *string { return &b.Email },
	"bank":                  func(b *publicBody) *string { return &b.Bank },
	"otherBank":             func(b *publicBody) *string { return &b.OtherBank },
	"source":                func(b *publicBody) *string { return &b.Source },
	"website":               func(b *publicBody) *string { return &b.Website },
	"cf-turnstile-response": func(b *publicBody) *string { return &b.TurnstileToken },
}

// decodePublic reads a JSON (application/json or text/plain) or, where
// allowed, a form body of at most 4 KiB, strictly. It reports whether the body
// was a form and whether it already answered.
func decodePublic(w http.ResponseWriter, r *http.Request, allowForm bool, jsonDst any, form *publicBody) (isForm, ok bool) {
	ct, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	switch {
	case ct == "application/json" || ct == "text/plain":
		return false, decodeBody(w, r, publicMaxBody, jsonDst)
	case ct == "application/x-www-form-urlencoded" && allowForm:
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, publicMaxBody))
		if err != nil {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "")
			return true, false
		}
		vals, err := url.ParseQuery(string(raw))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "body is not a form")
			return true, false
		}
		for k, v := range vals {
			f, known := formKeys[k]
			if !known || len(v) != 1 {
				writeErr(w, http.StatusBadRequest, "bad_request", "unknown or repeated form field")
				return true, false
			}
			*f(form) = v[0]
		}
		return true, true
	}
	writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "")
	return false, false
}

// wantsRedirect: a browser navigating without script posts a form and accepts
// HTML; it gets a 303 to the website's done page instead of JSON.
func wantsRedirect(r *http.Request, isForm bool) bool {
	return isForm && strings.Contains(r.Header.Get("Accept"), "text/html")
}

func (s *Server) answerPublic(w http.ResponseWriter, r *http.Request, isForm bool, status int, body any, errCode, form string) {
	if wantsRedirect(r, isForm) && s.Web.DoneURL != "" {
		q := url.Values{}
		if errCode != "" {
			q.Set("error", errCode)
		}
		if form != "" {
			q.Set("form", form)
		}
		target := s.Web.DoneURL
		if len(q) > 0 {
			target += "?" + q.Encode()
		}
		w.Header().Set("Cache-Control", "no-store")
		http.Redirect(w, r, target, http.StatusSeeOther)
		return
	}
	if errCode != "" {
		writeErr(w, status, errCode, "")
		return
	}
	writeJSON(w, status, body)
}

// StatusResponse is the public routes' success body.
type StatusResponse struct {
	Status string `json:"status"`
}

type waitlistJSON struct {
	Email          string `json:"email"`
	Bank           string `json:"bank"`
	OtherBank      string `json:"otherBank"`
	Source         string `json:"source"`
	Website        string `json:"website"`
	TurnstileToken string `json:"turnstileToken"`
}

func (s *Server) handleWaitlistSubmit(w http.ResponseWriter, r *http.Request) {
	o := s.Web
	if !o.WaitlistIP.Allow(clientKey(r)) || !o.WaitlistGlobal.Allow("") {
		w.Header().Set("Retry-After", "600")
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var (
		js   waitlistJSON
		form publicBody
	)
	isForm, ok := decodePublic(w, r, true, &js, &form)
	if !ok {
		return
	}
	if !isForm {
		form = publicBody{Email: js.Email, Bank: js.Bank, OtherBank: js.OtherBank, Source: js.Source,
			Website: js.Website, TurnstileToken: js.TurnstileToken}
	}
	accepted := StatusResponse{Status: "check_email"}
	if form.Website != "" {
		o.Honeypot.Add(1)
		s.answerPublic(w, r, isForm, http.StatusAccepted, accepted, "", "")
		return
	}
	email, choice, err := o.Waitlist.Validate(r.Context(), waitlist.Submission{Email: form.Email, Bank: form.Bank,
		OtherBank: strings.TrimSpace(form.OtherBank), Source: form.Source})
	if code := publicErrCode(err); code != "" {
		s.answerPublic(w, r, isForm, http.StatusBadRequest, nil, code, "")
		return
	}
	if err != nil {
		s.logf("api: waitlist validate: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if !s.turnstileOK(r, form.TurnstileToken, "waitlist") {
		s.answerPublic(w, r, isForm, http.StatusForbidden, nil, "turnstile_failed", "")
		return
	}
	if _, err := o.Waitlist.Submit(r.Context(), email, choice); err != nil {
		if errors.Is(err, waitlist.ErrFull) {
			s.answerPublic(w, r, isForm, http.StatusTooManyRequests, nil, "waitlist_full", "")
			return
		}
		s.logf("api: waitlist submit: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	o.Submitted.Add(1)
	s.answerPublic(w, r, isForm, http.StatusAccepted, accepted, "", "")
}

// publicErrCode maps validation errors to spec 07 §5.8's codes.
func publicErrCode(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, waitlist.ErrBadEmail):
		return "bad_email"
	case errors.Is(err, banks.ErrBadBank):
		return "bad_bank"
	case errors.Is(err, waitlist.ErrBadRequest):
		return "bad_request"
	}
	return ""
}

type tokenJSON struct {
	Token string `json:"token"`
}

func (s *Server) handleWaitlistConfirm(w http.ResponseWriter, r *http.Request) {
	if !s.Web.LinkIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var body tokenJSON
	if _, ok := decodePublic(w, r, false, &body, nil); !ok {
		return
	}
	status, err := s.Web.Waitlist.Confirm(r.Context(), body.Token)
	switch {
	case errors.Is(err, waitlist.ErrBadRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", "token must be 43 b64url characters")
	case errors.Is(err, waitlist.ErrLinkExpired):
		writeErr(w, http.StatusGone, "link_expired", "")
	case err != nil:
		s.logf("api: waitlist confirm: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	default:
		writeJSON(w, http.StatusOK, StatusResponse{Status: status})
	}
}

func (s *Server) handleWaitlistUnsubscribe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	if !s.Web.LinkIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := r.ParseMultipartForm(4 << 10); err != nil && !errors.Is(err, http.ErrNotMultipart) {
		writeErr(w, http.StatusBadRequest, "bad_request", "")
		return
	}
	if r.PostForm.Get("List-Unsubscribe") != "One-Click" {
		writeErr(w, http.StatusBadRequest, "bad_request", "the body must be List-Unsubscribe=One-Click")
		return
	}
	err := s.Web.Waitlist.Leave(r.Context(), r.URL.Query().Get("token"))
	switch {
	case errors.Is(err, waitlist.ErrBadRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", "token must be 43 b64url characters")
	case err != nil:
		s.logf("api: waitlist unsubscribe: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	default:
		writeJSON(w, http.StatusOK, StatusResponse{Status: "done"})
	}
}

func (s *Server) handleWaitlistLeave(w http.ResponseWriter, r *http.Request) {
	if !s.Web.LinkIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var body tokenJSON
	if _, ok := decodePublic(w, r, false, &body, nil); !ok {
		return
	}
	err := s.Web.Waitlist.Leave(r.Context(), body.Token)
	switch {
	case errors.Is(err, waitlist.ErrBadRequest):
		writeErr(w, http.StatusBadRequest, "bad_request", "token must be 43 b64url characters")
	case err != nil:
		s.logf("api: waitlist leave: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	default:
		writeJSON(w, http.StatusOK, StatusResponse{Status: "done"})
	}
}
