package api

// routes_mailboxlink.go: the mailbox link (spec 02 §7 #34–#38, §13.2), for
// Gmail and for Outlook (personal Microsoft accounts), mounted when the link
// part of [gmail] or [outlook] is configured, with or without that provider's
// push (GmailOptions.Push, OutlookOptions.Push). The link proves, with the
// provider's ID token carrying a nonce this server issued to this session,
// that the device holding the session can read the mailbox; the server keeps
// only an HMAC of the address under the route key and which writer is the
// holder (the one device that fetches mail and is woken by the hook). An
// account has one link at a time: linking either provider replaces the other.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/msjwt"
	"github.com/salehtl/hasala/server/internal/outlookpush"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// mailbox-user (spec 02 §16.2): 1/min per account, burst 10.
const (
	mailboxRate    = 1.0 / 60.0
	mailboxBurst   = 10
	mailboxMaxKeys = 4096

	linkChallengeTTL = 15 * time.Minute
	maxWatchAhead    = 8 * 24 * time.Hour // Gmail's users.watch lasts 7 days
	// A Graph subscription to messages lasts at most 7 days (10,080 minutes).
	maxOutlookWatchAhead = 7 * 24 * time.Hour
	idTokenMaxAge        = 10 * time.Minute
	idTokenMaxSkew       = 5 * time.Minute
	maxIDTokenBytes      = 16 << 10
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

// OutlookTokenVerifier verifies a Microsoft ID token (msjwt.Verifier in
// production).
type OutlookTokenVerifier interface {
	Verify(ctx context.Context, token string) (msjwt.Claims, error)
}

// OutlookOptions configures the Outlook mailbox link: #35 with provider
// "outlook", and #36–#38 for an Outlook link. A nil *OutlookOptions refuses
// provider "outlook".
type OutlookOptions struct {
	// RouteKey is the same route key as GmailOptions.RouteKey.
	RouteKey gmailpush.RouteKey
	// Link verifies the app's Microsoft ID token (audience = ClientID).
	Link OutlookTokenVerifier
	// ClientID is the Outlook application id: the audience Link checks.
	ClientID string
	// MailboxPerUser is shared with GmailOptions.MailboxPerUser when both
	// are set.
	MailboxPerUser *Limiter
	// Push is the Graph push. Nil is a link with no wakes: #36 answers 409
	// no_watch_topic for an Outlook link and #37 reports no watch.
	Push *OutlookPush
}

// OutlookPush is the Graph push: the public URLs of the hooks the holder's
// subscription names (/meta reports them), and the hooks' counters and
// limiters (routes_hooks.go). HookPerIP and HookGlobal are shared with
// GmailPush's when both pushes are on.
type OutlookPush struct {
	NotificationURL string
	LifecycleURL    string
	Counters        outlookpush.Counters
	HookPerIP       *Limiter
	HookGlobal      *Limiter
	HookLink        *Limiter
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

// outlookPush is the configured Graph push, or nil.
func (s *Server) outlookPush() *OutlookPush {
	if s.Outlook == nil {
		return nil
	}
	return s.Outlook.Push
}

// pushOn reports whether this server relays wakes for provider's mailboxes.
func (s *Server) pushOn(provider string) bool {
	switch provider {
	case gmailpush.ProviderGmail:
		return s.gmailPush() != nil
	case gmailpush.ProviderOutlook:
		return s.outlookPush() != nil
	}
	return false
}

// mailboxPerUser is the one mailbox-user limiter, whichever options hold it.
func (s *Server) mailboxPerUser() *Limiter {
	if s.Gmail != nil {
		return s.Gmail.MailboxPerUser
	}
	return s.Outlook.MailboxPerUser
}

func (s *Server) mountMailboxLink(mux *http.ServeMux) {
	if s.Gmail == nil && s.Outlook == nil {
		return
	}
	// One budget per account across both providers.
	var lim *Limiter
	if s.Gmail != nil {
		lim = s.Gmail.MailboxPerUser
	}
	if lim == nil && s.Outlook != nil {
		lim = s.Outlook.MailboxPerUser
	}
	s.ensureLimiter(&lim, mailboxRate, mailboxBurst, mailboxMaxKeys)
	if s.Gmail != nil {
		s.Gmail.MailboxPerUser = lim
	}
	if s.Outlook != nil {
		s.Outlook.MailboxPerUser = lim
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

// LinkRequest is #35's body. Provider is "gmail" (the default when absent) or
// "outlook"; the ID token is that provider's.
type LinkRequest struct {
	Provider string      `json:"provider,omitempty"`
	IDToken  string      `json:"id_token"`
	StepUp   *StepUpWire `json:"step_up"`
}

// LinkHolder names the holder writer.
type LinkHolder struct {
	WriterID     string `json:"writer_id"`
	IsThisDevice bool   `json:"is_this_device"`
}

// LinkResponse is #35's answer. ClientState is Outlook's only: the base64url
// clientState the holder gives its Graph subscription. The server keeps only
// its SHA-256 and returns it this once.
type LinkResponse struct {
	Provider    string     `json:"provider"`
	Holder      LinkHolder `json:"holder"`
	CreatedAt   time.Time  `json:"created_at"`
	ClientState string     `json:"client_state,omitempty"`
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
	if !s.mailboxPerUser().Allow(userID.String()) {
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

// linkRejection is an ID token that verified but does not prove a link; the
// string is the operator log's reason.
type linkRejection string

func (r linkRejection) Error() string { return string(r) }

// linkIdentity is what a verified ID token proves: the mailbox and the nonce.
type linkIdentity struct{ address, nonce string }

// iatFresh is the link's freshness window, the same for both providers.
func iatFresh(iat, now time.Time) bool {
	return !iat.IsZero() && !iat.Before(now.Add(-idTokenMaxAge)) && !iat.After(now.Add(idTokenMaxSkew))
}

// verifyGmailLink is spec 02 §13.2's Google ID token rules.
func (s *Server) verifyGmailLink(ctx context.Context, token string, now time.Time) (linkIdentity, error) {
	claims, err := s.Gmail.Link.Verify(ctx, token)
	if err != nil {
		return linkIdentity{}, err
	}
	switch {
	case claims.Azp != "" && claims.Azp != s.Gmail.IOSClientID:
		return linkIdentity{}, linkRejection("azp")
	case !iatFresh(claims.Iat, now):
		return linkIdentity{}, linkRejection("iat")
	case !claims.EmailVerified || claims.Email == "" || len(claims.Email) > 320:
		return linkIdentity{}, linkRejection("email")
	}
	return linkIdentity{address: claims.Email, nonce: claims.Nonce}, nil
}

// verifyOutlookLink is the Microsoft ID token rules: the consumers tenant, the
// Outlook application, the same freshness and nonce as Gmail, and an address
// from email or an address-shaped preferred_username. Microsoft's v2.0 tokens
// carry neither email_verified nor azp, so neither is asked for.
func (s *Server) verifyOutlookLink(ctx context.Context, token string, now time.Time) (linkIdentity, error) {
	claims, err := s.Outlook.Link.Verify(ctx, token)
	if err != nil {
		return linkIdentity{}, err
	}
	address := claims.Address()
	switch {
	case !slices.Contains(claims.Aud, s.Outlook.ClientID):
		return linkIdentity{}, linkRejection("aud")
	case claims.Tid != msjwt.ConsumersTenantID:
		return linkIdentity{}, linkRejection("tid")
	case !iatFresh(claims.Iat, now):
		return linkIdentity{}, linkRejection("iat")
	case address == "" || len(address) > 320:
		return linkIdentity{}, linkRejection("email")
	}
	return linkIdentity{address: address, nonce: claims.Nonce}, nil
}

func (s *Server) handleLink(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) {
		return
	}
	var req LinkRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	// The provider is settled before anything else, so an unknown one costs
	// no step-up and no JWKS work.
	provider := req.Provider
	if provider == "" {
		provider = gmailpush.ProviderGmail
	}
	var (
		verify   func(context.Context, string, time.Time) (linkIdentity, error)
		routeKey gmailpush.RouteKey
	)
	switch {
	case provider == gmailpush.ProviderGmail && s.Gmail != nil:
		verify, routeKey = s.verifyGmailLink, s.Gmail.RouteKey
	case provider == gmailpush.ProviderOutlook && s.Outlook != nil:
		verify, routeKey = s.verifyOutlookLink, s.Outlook.RouteKey
	default:
		writeErr(w, http.StatusBadRequest, "unsupported_provider", "this server does not link that provider")
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
	// The provider is not in the params hash: the token's hash binds its
	// issuer, and a token of one provider fails the other's verifier.
	tokenHash := sha256.Sum256([]byte(req.IDToken))
	ph, err := keyproto.ParamsHash(keyproto.ActionMailboxLink, tokenHash[:])
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	// A request without a step-up is refused before the ID token is
	// verified, so it costs no JWKS work. The step-up assertion itself is
	// verified later, inside StepUp.Run, before anything is written.
	if su == nil {
		writeErr(w, http.StatusForbidden, "step_up_required", "")
		return
	}
	now := s.now()
	id, err := verify(r.Context(), req.IDToken, now)
	if errors.Is(err, googlejwt.ErrKeySetUnavailable) || errors.Is(err, msjwt.ErrKeySetUnavailable) {
		s.logf("api: mailbox link: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if err != nil {
		s.writeLinkRejected(w, r, err.Error())
		return
	}
	nonce, err := base64.RawURLEncoding.DecodeString(id.nonce)
	if err != nil || len(nonce) != 32 {
		s.writeLinkRejected(w, r, "nonce shape")
		return
	}
	nonceHash := sha256.Sum256(nonce)
	addrHMAC := routeKey.AddressHMACFor(provider, id.address)
	id = linkIdentity{}

	// Outlook's clientState: minted here, returned once, kept only as a hash,
	// never logged. Graph echoes it on every notification and the hook routes
	// by its hash.
	var clientState string
	var clientStateHash []byte
	if provider == gmailpush.ProviderOutlook {
		cs := make([]byte, 32)
		if _, err := rand.Read(cs); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		clientState = base64.RawURLEncoding.EncodeToString(cs)
		sum := sha256.Sum256([]byte(clientState))
		clientStateHash = sum[:]
	}

	var created time.Time
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
		var taken bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM mailbox_links WHERE address_hmac = $1 AND user_id <> $2)`,
			addrHMAC, userID).Scan(&taken); err != nil {
			return err
		}
		if taken {
			return errMailboxInUse
		}
		if err := auth.RecordQuietEventTx(ctx, tx, userID, auth.AuthEvent{Kind: auth.EventMailboxLinked,
			WriterID: info.WriterID, CredentialID: p.CredentialID}, now); err != nil {
			return err
		}
		// One link per account (mailbox_links_one_per_user): the conflict is
		// on the account, so this replaces the link of either provider, the
		// other provider's included, and two racing links leave the later one.
		err = tx.QueryRow(ctx,
			`INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
			                            client_state_hash, created_at, updated_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
			 ON CONFLICT (user_id) DO UPDATE
			   SET provider = EXCLUDED.provider, address_hmac = EXCLUDED.address_hmac,
			       route_key_id = EXCLUDED.route_key_id, holder_writer_id = EXCLUDED.holder_writer_id,
			       client_state_hash = EXCLUDED.client_state_hash, watch_expires_at = NULL, last_nudge_at = NULL,
			       created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at
			 RETURNING created_at`,
			userID, provider, addrHMAC, routeKey.KeyID(), info.WriterID, clientStateHash, now).Scan(&created)
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "mailbox_links_one_account_per_mailbox" {
			return errMailboxInUse
		}
		return err
	})
	if errors.Is(err, errLinkRejected) {
		s.writeLinkRejected(w, r, "nonce not issued to this session, used or expired")
		return
	}
	if errors.Is(err, errMailboxInUse) {
		writeErr(w, http.StatusConflict, "mailbox_in_use", "this mailbox is connected to another Hasala account")
		return
	}
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	// Every other device hears of the link (a security wake), the old holder
	// included, so it stops fetching (spec 02 §12.5, AT-GM-9).
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	writeJSON(w, http.StatusOK, LinkResponse{Provider: provider,
		Holder: LinkHolder{WriterID: info.WriterID, IsThisDevice: true}, CreatedAt: created, ClientState: clientState})
}

func (s *Server) handleLinkWatch(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if s.mailboxLimited(w, userID) {
		return
	}
	// Without the push there is nothing to watch (/meta's gmail_watch_topic
	// is null) and no watch to record. The app skips users.watch without a
	// topic, so it never sends this; one that read a topic before the push
	// was turned off stops its watch, forgets the topic and reads /meta
	// again. With no push for either provider it is checked before the body,
	// the binding and the holder on purpose (spec 02 route 36): the answer
	// depends only on this server's configuration, which /meta already makes
	// public, so a non-holder learns nothing from no_watch_topic, and nothing
	// is written. With one provider's push on, the same answer for the other
	// provider's link comes after the holder check below.
	if s.gmailPush() == nil && s.outlookPush() == nil {
		writeErr(w, http.StatusConflict, "no_watch_topic", "this server relays no mailbox wakes")
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
	var provider, holder string
	err := s.Pool.QueryRow(r.Context(),
		`SELECT provider, holder_writer_id FROM mailbox_links WHERE user_id = $1`, userID).Scan(&provider, &holder)
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
	if !s.pushOn(provider) {
		writeErr(w, http.StatusConflict, "no_watch_topic", "this server relays no wakes for this mailbox")
		return
	}
	if provider == gmailpush.ProviderOutlook && req.ExpiresAt.After(now.Add(maxOutlookWatchAhead)) {
		writeErr(w, http.StatusBadRequest, "bad_request", "expires_at must be in the next 7 days")
		return
	}
	// The provider is matched too: a link replaced since the read above is
	// not given the old one's watch.
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE mailbox_links SET watch_expires_at = $4, updated_at = $5
		  WHERE user_id = $1 AND provider = $2 AND holder_writer_id = $3`,
		userID, provider, info.WriterID, req.ExpiresAt, now); err != nil {
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
		`SELECT provider, holder_writer_id, watch_expires_at, last_wake_hour, created_at
		   FROM mailbox_links WHERE user_id = $1`, userID).
		Scan(&out.Provider, &out.Holder.WriterID, &out.WatchExpiresAt, &out.LastWakeHour, &out.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "no_link", "")
		return
	}
	if err != nil {
		s.logf("api: get link for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out.Holder.IsThisDevice = info.WriterID != "" && out.Holder.WriterID == info.WriterID
	if !s.pushOn(out.Provider) {
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
			`DELETE FROM mailbox_links WHERE user_id = $1 RETURNING holder_writer_id`,
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

var (
	errNoLink       = errors.New("api: no mailbox link")
	errMailboxInUse = errors.New("api: mailbox linked to another account")
)
