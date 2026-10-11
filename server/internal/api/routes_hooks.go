package api

// routes_hooks.go: POST /hooks/gmail/pubsub (spec 02 §7 #39, §13.4), Gmail's
// change notices pushed by Pub/Sub with Google's OIDC token. A notice that
// routes to a link wakes exactly that account's holder device; everything
// else ends in a 204 and a counter, because Pub/Sub retries anything else.

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// hook-ip 20/s burst 100; hook-global 100/s burst 500; hook-link 60/h burst
// 10 per address HMAC (spec 02 §16.2).
const (
	hookIPRate       = 20.0
	hookIPBurst      = 100
	hookIPMaxKeys    = 4096
	hookGlobalRate   = 100.0
	hookGlobalBurst  = 500
	hookLinkRate     = 60.0 / 3600.0
	hookLinkBurst    = 10
	hookLinkMaxKeys  = 10_000
	hookMaxBody      = 64 << 10
	hookMaxAuthBytes = 16 << 10
	hookDeadline     = 10 * time.Second
	hookMaxRows      = 10
)

func (s *Server) mountHooks(mux *http.ServeMux) {
	if s.Gmail == nil {
		return
	}
	g := s.Gmail
	if g.HookPerIP == nil {
		g.HookPerIP = NewLimiter(hookIPRate, hookIPBurst, hookIPMaxKeys, s.now)
	}
	if g.HookGlobal == nil {
		g.HookGlobal = NewLimiter(hookGlobalRate, hookGlobalBurst, 1, s.now)
	}
	if g.HookLink == nil {
		g.HookLink = NewLimiter(hookLinkRate, hookLinkBurst, hookLinkMaxKeys, s.now)
	}
	mux.HandleFunc("POST /hooks/gmail/pubsub", s.handleGmailHook)
}

func (s *Server) handleGmailHook(w http.ResponseWriter, r *http.Request) {
	g := s.Gmail
	g.Counters.Pushes.Add(1)
	ctx, cancel := context.WithTimeout(r.Context(), hookDeadline)
	defer cancel()
	// 1: per caller before global, so one host cannot drain the shared budget.
	if !g.HookPerIP.Allow(clientKey(r)) || !g.HookGlobal.Allow("") {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	// 2: body cap.
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hookMaxBody))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "")
		return
	}
	// 3–4: Google's OIDC token for the push URL.
	authz := r.Header.Get("Authorization")
	const scheme = "bearer "
	if len(authz) <= len(scheme) || len(authz) > hookMaxAuthBytes || !strings.EqualFold(authz[:len(scheme)], scheme) {
		g.Counters.Unauthorized.Add(1)
		writeUnauthorized(w)
		return
	}
	claims, err := g.Hook.Verify(ctx, strings.TrimSpace(authz[len(scheme):]))
	if errors.Is(err, googlejwt.ErrKeySetUnavailable) {
		s.logf("api: gmail hook: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if err != nil {
		g.Counters.Unauthorized.Add(1)
		s.logf("api: gmail hook: token rejected: %v", err)
		writeUnauthorized(w)
		return
	}
	// 5: Pub/Sub's own service account, verified.
	if claims.Email != g.PushServiceAccount || !claims.EmailVerified {
		g.Counters.Forbidden.Add(1)
		writeErr(w, http.StatusForbidden, "forbidden", "")
		return
	}
	// 6–8: the envelope and the notice.
	n, err := gmailpush.ParseEnvelope(body, g.Subscription)
	switch {
	case errors.Is(err, gmailpush.ErrForeignSubscription):
		g.Counters.ForeignSubscription.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	case err != nil:
		g.Counters.Malformed.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	addrHMAC := g.RouteKey.AddressHMAC(n.EmailAddress)
	n = gmailpush.Notice{}
	// 8b: per mailbox, so an outsider's watch cannot spend a holder's budget.
	if !g.HookLink.Allow(hex.EncodeToString(addrHMAC)) {
		g.Counters.LinkLimited.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// 9: route.
	rows, err := s.Pool.Query(ctx,
		`SELECT user_id, holder_writer_id FROM mailbox_links WHERE address_hmac = $1 AND route_key_id = $2 LIMIT $3`,
		addrHMAC, g.RouteKey.KeyID(), hookMaxRows)
	if err != nil {
		s.logf("api: gmail hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	var holders []gmailpush.Holder
	for rows.Next() {
		var h gmailpush.Holder
		if err := rows.Scan(&h.UserID, &h.WriterID); err != nil {
			rows.Close()
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
			return
		}
		holders = append(holders, h)
	}
	rows.Close()
	if len(holders) == 0 {
		g.Counters.Unknown.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// 10: wake each holder; record the hour (at most one write per link per
	// hour, skipped while the disk fuse is tripped).
	hour := s.now().UTC().Truncate(time.Hour)
	tripped := s.Headroom != nil && s.Headroom.Tripped()
	for _, h := range holders {
		s.waker().WakeWriter(context.WithoutCancel(ctx), h.UserID, h.WriterID, pushv2.ReasonGmail)
		g.Counters.Woken.Add(1)
		if !tripped {
			if _, err := s.Pool.Exec(ctx,
				`UPDATE mailbox_links SET last_wake_hour = $3
				  WHERE user_id = $1 AND holder_writer_id = $2 AND provider = 'gmail'
				    AND last_wake_hour IS DISTINCT FROM $3`, h.UserID, h.WriterID, hour); err != nil {
				s.logf("api: gmail hook: wake hour: %v", err)
			}
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
