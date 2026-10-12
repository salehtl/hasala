package api

// routes_mailboxlink.go: the Gmail mailbox link (spec 02 §7 #34–#38, §13.2),
// mounted when the [gmail] link part is configured, with or without the
// Pub/Sub push (GmailOptions.Push). The link proves,
// with a Google ID token carrying a nonce this server issued to this session,
// that the device holding the session can read the mailbox; the server keeps
// only an HMAC of the address under the route key and which writer is the
// holder (the one device that fetches mail and is woken by the hook).

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// mailbox-user (spec 02 §16.2): 1/min per account, burst 10.
const (
	mailboxRate    = 1.0 / 60.0
	mailboxBurst   = 10
	mailboxMaxKeys = 4096

	linkChallengeTTL = 15 * time.Minute
	maxWatchAhead    = 8 * 24 * time.Hour
	idTokenMaxAge    = 10 * time.Minute
	idTokenMaxSkew   = 5 * time.Minute
	maxIDTokenBytes  = 16 << 10
)

// IDTokenVerifier verifies a Google ID token (googlejwt.Verifier in
// production).
type IDTokenVerifier interface {
	Verify(ctx context.Context, token string) (googlejwt.Claims, error)
}

// GmailOptions configures the mailbox link (#34–#38) and, through Push, the
// Pub/Sub hook (#39). A nil *GmailOptions leaves #34–#39 unmounted.
type GmailOptions struct {
	RouteKey gmailpush.RouteKey
	// Link verifies the app's ID token (audience = the iOS client id).
	Link IDTokenVerifier
	// IOSClientID is the audience Link checks, and what azp must equal.
	IOSClientID    string
	MailboxPerUser *Limiter
	// Push is the Pub/Sub half. Nil is a link with no wakes: the hook is not
	// mounted, /meta's gmail_watch_topic is null, #36 answers 409
	// no_watch_topic and #37 reports no watch.
	Push                *GmailPush
	DisableHeadroomFuse bool // tests only
}

// GmailPush configures POST /hooks/gmail/pubsub (#39) and the watch topic.
type GmailPush struct {
	// Topic is the Pub/Sub topic the app watches its mailbox on; /meta reports
	// it as gmail_watch_topic.
	Topic string
	// Hook verifies Pub/Sub's OIDC token (audience = the push URL).
	Hook           IDTokenVerifier
	Subscription   string
	ServiceAccount string
	Counters       gmailpush.Counters
	HookPerIP      *Limiter
	HookGlobal     *Limiter
	HookLink       *Limiter
}

// gmailPush is the configured Pub/Sub half, or nil.
func (s *Server) gmailPush() *GmailPush {
	if s.Gmail == nil {
		return nil
	}
	return s.Gmail.Push
}

func (s *Server) mountMailboxLink(mux *http.ServeMux) {
	if s.Gmail == nil {
		return
	}
	if s.Gmail.MailboxPerUser == nil {
		s.Gmail.MailboxPerUser = NewLimiter(mailboxRate, mailboxBurst, mailboxMaxKeys, s.now)
	}
	mux.HandleFunc("POST /api/v1/mailbox/link/challenge", s.requireSession(s.handleLinkChallenge))
	mux.HandleFunc("PUT /api/v1/mailbox/link", s.requireSession(s.handleLink))
	mux.HandleFunc("PUT /api/v1/mailbox/link/watch", s.requireSession(s.handleLinkWatch))
	mux.HandleFunc("GET /api/v1/mailbox/link", s.requireSession(s.handleGetLink))
	mux.HandleFunc("DELETE /api/v1/mailbox/link", s.requireSession(s.handleUnlink))
}

// LinkChallengeResponse is #34's answer.
type LinkChallengeResponse struct {
	Nonce     string    `json:"nonce"`
	ExpiresAt time.Time `json:"expires_at"`
}

// LinkRequest is #35's body.
type LinkRequest struct {
	IDToken string      `json:"id_token"`
	StepUp  *StepUpWire `json:"step_up"`
}

// LinkHolder names the holder writer.
type LinkHolder struct {
	WriterID     string `json:"writer_id"`
	IsThisDevice bool   `json:"is_this_device"`
}

// LinkResponse is #35's answer.
type LinkResponse struct {
	Provider  string     `json:"provider"`
	Holder    LinkHolder `json:"holder"`
	CreatedAt time.Time  `json:"created_at"`
}

// LinkStatusResponse is #37's answer.
type LinkStatusResponse struct {
	Provider       string     `json:"provider"`
	Holder         LinkHolder `json:"holder"`
	WatchExpiresAt *time.Time `json:"watch_expires_at"`
	LastWakeHour   *time.Time `json:"last_wake_hour"`
	CreatedAt      time.Time  `json:"created_at"`
}

// LinkWatchRequest is #36's body.
type LinkWatchRequest struct {
	ExpiresAt time.Time `json:"expires_at"`
}

// UnlinkRequest is #38's body.
type UnlinkRequest struct {
	StepUp *StepUpWire `json:"step_up"`
}

func (s *Server) mailboxLimited(w http.ResponseWriter, userID uuid.UUID) bool {
	if !s.Gmail.MailboxPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many mailbox requests; try again shortly")
		return true
	}
	return false
}

func (s *Server) handleLinkChallenge(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) || !decodeEmptyBody(w, r) {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	n := make([]byte, 32)
	if _, err := rand.Read(n); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	sum := sha256.Sum256(n)
	now := s.now()
	exp := now.Add(linkChallengeTTL)
	if _, err := s.Pool.Exec(r.Context(),
		`INSERT INTO mailbox_link_challenges (nonce_hash, user_id, session_hash, issued_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5)`, sum[:], userID, info.Hash, now, exp); err != nil {
		s.logf("api: link challenge for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	_, _ = s.Pool.Exec(r.Context(), `DELETE FROM mailbox_link_challenges WHERE expires_at < $1`, now.Add(-24*time.Hour))
	writeJSON(w, http.StatusOK, LinkChallengeResponse{Nonce: base64.RawURLEncoding.EncodeToString(n), ExpiresAt: exp})
}

// errLinkRejected is every ID-token failure of #35: one answer, the reason in
// the operator log.
var errLinkRejected = errors.New("api: mailbox link rejected")

func (s *Server) writeLinkRejected(w http.ResponseWriter, r *http.Request, reason string) {
	s.logf("api: %s %s: mailbox link rejected: %s", r.Method, r.URL.Path, reason)
	writeErr(w, http.StatusForbidden, "link_rejected", "")
}

func (s *Server) handleLink(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) {
		return
	}
	var req LinkRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if req.IDToken == "" || len(req.IDToken) > maxIDTokenBytes {
		writeErr(w, http.StatusBadRequest, "bad_request", "id_token is required")
		return
	}
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	tokenHash := sha256.Sum256([]byte(req.IDToken))
	ph, err := keyproto.ParamsHash(keyproto.ActionMailboxLink, tokenHash[:])
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	// The step-up is checked before the ID token is: a request without one
	// costs no JWKS work.
	if su == nil {
		writeErr(w, http.StatusForbidden, "step_up_required", "")
		return
	}
	claims, err := s.Gmail.Link.Verify(r.Context(), req.IDToken)
	if errors.Is(err, googlejwt.ErrKeySetUnavailable) {
		s.logf("api: mailbox link: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if err != nil {
		s.writeLinkRejected(w, r, err.Error())
		return
	}
	now := s.now()
	switch {
	case claims.Azp != "" && claims.Azp != s.Gmail.IOSClientID:
		s.writeLinkRejected(w, r, "azp")
		return
	case claims.Iat.IsZero() || claims.Iat.Before(now.Add(-idTokenMaxAge)) || claims.Iat.After(now.Add(idTokenMaxSkew)):
		s.writeLinkRejected(w, r, "iat")
		return
	case !claims.EmailVerified || claims.Email == "" || len(claims.Email) > 320:
		s.writeLinkRejected(w, r, "email")
		return
	}
	nonce, err := base64.RawURLEncoding.DecodeString(claims.Nonce)
	if err != nil || len(nonce) != 32 {
		s.writeLinkRejected(w, r, "nonce shape")
		return
	}
	nonceHash := sha256.Sum256(nonce)
	address := claims.Email
	claims = googlejwt.Claims{}
	addrHMAC := s.Gmail.RouteKey.AddressHMAC(address)
	address = ""

	var (
		created   time.Time
		oldHolder string
	)
	err = s.StepUp.Run(r.Context(), auth.Guarded{
		UserID: userID, SessionHash: info.Hash, BoundWriter: info.WriterID,
		Action: keyproto.ActionMailboxLink, ParamsHash: ph, StepUp: su,
	}, func(ctx context.Context, tx pgx.Tx, p auth.Proven) error {
		tag, err := tx.Exec(ctx,
			`UPDATE mailbox_link_challenges SET used_at = $4
			  WHERE nonce_hash = $1 AND user_id = $2 AND session_hash = $3 AND used_at IS NULL AND expires_at > $4`,
			nonceHash[:], userID, info.Hash, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return errLinkRejected
		}
		var prev *string
		if err := tx.QueryRow(ctx,
			`SELECT holder_writer_id FROM mailbox_links WHERE user_id = $1 AND provider = 'gmail' FOR UPDATE`,
			userID).Scan(&prev); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if prev != nil {
			oldHolder = *prev
		}
		if err := auth.RecordQuietEventTx(ctx, tx, userID, auth.AuthEvent{Kind: auth.EventMailboxLinked,
			WriterID: info.WriterID, CredentialID: p.CredentialID}, now); err != nil {
			return err
		}
		return tx.QueryRow(ctx,
			`INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
			 VALUES ($1, 'gmail', $2, $3, $4, $5, $5)
			 ON CONFLICT (user_id, provider) DO UPDATE
			   SET address_hmac = EXCLUDED.address_hmac, route_key_id = EXCLUDED.route_key_id,
			       holder_writer_id = EXCLUDED.holder_writer_id, watch_expires_at = NULL, last_nudge_at = NULL,
			       created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at
			 RETURNING created_at`,
			userID, addrHMAC, s.Gmail.RouteKey.KeyID(), info.WriterID, now).Scan(&created)
	})
	if errors.Is(err, errLinkRejected) {
		s.writeLinkRejected(w, r, "nonce not issued to this session, used or expired")
		return
	}
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// Every other device hears of the link (a security wake), the old holder
	// included, so it stops fetching (spec 02 §12.5, AT-GM-9).
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	_ = oldHolder
	writeJSON(w, http.StatusOK, LinkResponse{Provider: "gmail",
		Holder: LinkHolder{WriterID: info.WriterID, IsThisDevice: true}, CreatedAt: created})
}

func (s *Server) handleLinkWatch(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) {
		return
	}
	// Without the Pub/Sub push there is no topic to watch (/meta's
	// gmail_watch_topic is null) and no watch to record. The app skips
	// users.watch without a topic, so it never sends this; one that read a
	// topic before the push was turned off stops its watch, forgets the topic
	// and reads /meta again. It is checked before the body, the binding and
	// the holder on purpose (spec 02 route 36): the answer depends only on this
	// server's configuration, which /meta already makes public, so a
	// non-holder learns nothing from no_watch_topic, and nothing is written.
	if s.Gmail.Push == nil {
		writeErr(w, http.StatusConflict, "no_watch_topic", "this server relays no Gmail wakes")
		return
	}
	var req LinkWatchRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	now := s.now()
	if !req.ExpiresAt.After(now) || req.ExpiresAt.After(now.Add(maxWatchAhead)) {
		writeErr(w, http.StatusBadRequest, "bad_request", "expires_at must be in the next 8 days")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	var holder string
	err := s.Pool.QueryRow(r.Context(),
		`SELECT holder_writer_id FROM mailbox_links WHERE user_id = $1 AND provider = 'gmail'`, userID).Scan(&holder)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "no_link", "")
		return
	}
	if err != nil {
		s.logf("api: link watch for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if holder != info.WriterID {
		writeErr(w, http.StatusConflict, "not_holder", "")
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE mailbox_links SET watch_expires_at = $3, updated_at = $4
		  WHERE user_id = $1 AND provider = 'gmail' AND holder_writer_id = $2`,
		userID, info.WriterID, req.ExpiresAt, now); err != nil {
		s.logf("api: link watch for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetLink(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	var out LinkStatusResponse
	err := s.Pool.QueryRow(r.Context(),
		`SELECT holder_writer_id, watch_expires_at, last_wake_hour, created_at
		   FROM mailbox_links WHERE user_id = $1 AND provider = 'gmail'`, userID).
		Scan(&out.Holder.WriterID, &out.WatchExpiresAt, &out.LastWakeHour, &out.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "no_link", "")
		return
	}
	if err != nil {
		s.logf("api: get link for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out.Provider = "gmail"
	out.Holder.IsThisDevice = info.WriterID != "" && out.Holder.WriterID == info.WriterID
	if s.Gmail.Push == nil {
		// A watch reported while the push was on is relayed by nobody now, and
		// the app would take this field for a live one.
		out.WatchExpiresAt = nil
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleUnlink(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) {
		return
	}
	var req UnlinkRequest
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
	ph, err := keyproto.ParamsHash(keyproto.ActionMailboxUnlink)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	var holder string
	err = s.StepUp.Run(r.Context(), auth.Guarded{
		UserID: userID, SessionHash: info.Hash, BoundWriter: info.WriterID,
		Action: keyproto.ActionMailboxUnlink, ParamsHash: ph, StepUp: su,
	}, func(ctx context.Context, tx pgx.Tx, p auth.Proven) error {
		err := tx.QueryRow(ctx,
			`DELETE FROM mailbox_links WHERE user_id = $1 AND provider = 'gmail' RETURNING holder_writer_id`,
			userID).Scan(&holder)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNoLink
		}
		if err != nil {
			return err
		}
		return auth.RecordQuietEventTx(ctx, tx, userID, auth.AuthEvent{Kind: auth.EventMailboxUnlinked,
			WriterID: info.WriterID, CredentialID: p.CredentialID}, s.now())
	})
	if errors.Is(err, errNoLink) {
		writeErr(w, http.StatusNotFound, "no_link", "")
		return
	}
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// The holder stops fetching and revokes its own refresh token on its next
	// wake (spec 02 §13.2); every other device hears of the change too.
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

var errNoLink = errors.New("api: no mailbox link")
