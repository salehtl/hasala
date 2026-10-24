package api

// routes_hooks.go: the mail providers' change hooks.
//
// POST /hooks/gmail/pubsub (spec 02 §7 #39, §13.4) is Gmail's change notices
// pushed by Pub/Sub with Google's OIDC token. A notice that routes to a link
// wakes exactly that account's holder device; everything else ends in a 204
// and a counter, because Pub/Sub retries anything else.
//
// POST /hooks/outlook/graph and /hooks/outlook/graph/lifecycle are Microsoft
// Graph's change and lifecycle notifications for an Outlook link's
// subscription. Graph signs nothing a public client can check; what proves a
// notification is the clientState the link minted, which Graph echoes and the
// server routes by its SHA-256. The resource and resourceData Graph sends name
// the message, so they are never decoded (internal/outlookpush), and the
// clientState itself is never logged, stored or echoed.

import (
	"cmp"
	"context"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/outlookpush"
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

// The Outlook hooks' paths: they equal config.OutlookNotificationPath and
// config.OutlookLifecyclePath, and the tunnel's ingress admits exactly these.
const (
	outlookHookPath      = "/hooks/outlook/graph"
	outlookLifecyclePath = "/hooks/outlook/graph/lifecycle"
)

// mountHooks mounts each provider's hook only with that provider's push; a
// mailbox link alone leaves it to the catch-all 404. The per-IP budget is one
// across both providers' hooks and is spent by every request; each provider
// has its own global budget, spent only by a request that proved itself (a
// verified Google token, a clientState that names a link), so unauthenticated
// traffic cannot delay a real wake.
func (s *Server) mountHooks(mux *http.ServeMux) {
	g, o := s.gmailPush(), s.outlookPush()
	if g == nil && o == nil {
		return
	}
	var perIP *Limiter
	if g != nil {
		perIP = g.HookPerIP
	}
	if o != nil {
		perIP = cmp.Or(perIP, o.HookPerIP)
	}
	s.ensureLimiter(&perIP, hookIPRate, hookIPBurst, hookIPMaxKeys)
	if g != nil {
		g.HookPerIP = perIP
		s.ensureLimiter(&g.HookGlobal, hookGlobalRate, hookGlobalBurst, 1)
		s.ensureLimiter(&g.HookLink, hookLinkRate, hookLinkBurst, hookLinkMaxKeys)
		mux.HandleFunc("POST /hooks/gmail/pubsub", s.handleGmailHook)
	}
	if o != nil {
		o.HookPerIP = perIP
		if o.HookGlobal == nil || (g != nil && o.HookGlobal == g.HookGlobal) {
			o.HookGlobal = NewLimiter(hookGlobalRate, hookGlobalBurst, 1, s.now)
		}
		s.ensureLimiter(&o.HookLink, hookLinkRate, hookLinkBurst, hookLinkMaxKeys)
		mux.HandleFunc("POST "+outlookHookPath, func(w http.ResponseWriter, r *http.Request) {
			s.handleOutlookHook(w, r, false)
		})
		mux.HandleFunc("POST "+outlookLifecyclePath, func(w http.ResponseWriter, r *http.Request) {
			s.handleOutlookHook(w, r, true)
		})
	}
}

func (s *Server) handleGmailHook(w http.ResponseWriter, r *http.Request) {
	g := s.Gmail.Push
	g.Counters.Pushes.Add(1)
	ctx, cancel := context.WithTimeout(r.Context(), hookDeadline)
	defer cancel()
	// 1: per caller; the global budget is spent only after step 5.
	if !g.HookPerIP.Allow(clientKey(r)) {
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
	if claims.Email != g.ServiceAccount || !claims.EmailVerified {
		g.Counters.Forbidden.Add(1)
		writeErr(w, http.StatusForbidden, "forbidden", "")
		return
	}
	if !g.HookGlobal.Allow("") {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
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
	addrHMAC := s.Gmail.RouteKey.AddressHMAC(n.EmailAddress)
	n = gmailpush.Notice{}
	// 8b: per mailbox, so an outsider's watch cannot spend a holder's budget.
	if !g.HookLink.Allow(hex.EncodeToString(addrHMAC)) {
		g.Counters.LinkLimited.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// 9: route.
	rows, err := s.Pool.Query(ctx,
		`SELECT user_id, holder_writer_id FROM mailbox_links
		  WHERE address_hmac = $1 AND route_key_id = $2 AND provider = 'gmail' LIMIT $3`,
		addrHMAC, s.Gmail.RouteKey.KeyID(), hookMaxRows)
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
	if err := rows.Err(); err != nil {
		// A read that failed part-way is not "no such link".
		s.logf("api: gmail hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if len(holders) == 0 {
		g.Counters.Unknown.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// 10: wake each holder; record the hour (at most one write per link per
	// hour, skipped while the disk fuse is tripped).
	hour := s.now().UTC().Truncate(time.Hour)
	tripped := s.fuseTripped()
	for _, h := range holders {
		s.waker().WakeWriter(context.WithoutCancel(ctx), h.UserID, h.WriterID, pushv2.ReasonMail)
		g.Counters.Woken.Add(1)
		if !tripped {
			s.markWakeHour(ctx, gmailpush.ProviderGmail, h, hour)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleOutlookHook is both Graph hooks; lifecycle says which. The order:
//
//  1. hook-ip for every request, the handshake included.
//  2. The 64 KiB body cap.
//  3. The validation handshake: a validationToken and an empty body is
//     answered 200 with the token as text/plain, after no database work. A
//     token with a body is no handshake: 204 and a counter.
//  4. The notification collection; a malformed one is 204 and a counter.
//  5. One route query by the unique client_state_hash for the distinct
//     hashes. A request with a match spends hook-global once (429 when it is
//     out); then per link that matched: hook-link, then the wake (an
//     unmatched hash never touches hook-global or hook-link): ReasonMail on the main path,
//     ReasonNudge for a lifecycle event (reauthorizationRequired,
//     subscriptionRemoved, missed). An unknown clientState is a counter.
//  6. 202, or 503 if the route could not be read (Graph retries).
func (s *Server) handleOutlookHook(w http.ResponseWriter, r *http.Request, lifecycle bool) {
	o := s.Outlook.Push
	if !o.HookPerIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hookMaxBody))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "")
		return
	}
	if q := r.URL.Query(); q.Has("validationToken") {
		if len(body) != 0 {
			o.Counters.ValidationWithBody.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		toks := q["validationToken"]
		if len(toks) != 1 || !outlookpush.ValidToken(toks[0]) {
			o.Counters.BadValidation.Add(1)
			writeErr(w, http.StatusBadRequest, "bad_request", "")
			return
		}
		o.Counters.Validations.Add(1)
		h := w.Header()
		h.Set("Content-Type", "text/plain; charset=utf-8")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, toks[0])
		return
	}

	o.Counters.Notifications.Add(1)
	p, err := outlookpush.Parse(body, lifecycle)
	if err != nil {
		o.Counters.Malformed.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	o.Counters.BadClientState.Add(int64(p.BadClientState))
	o.Counters.Ignored.Add(int64(p.Ignored))
	if len(p.Hashes) == 0 {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	hashes := make([][]byte, len(p.Hashes))
	for i := range p.Hashes {
		hashes[i] = p.Hashes[i][:]
	}

	// The route comes before hook-global and hook-link: only a clientState
	// that names a link spends them, so made-up clientStates cannot drain the
	// global budget, nor fill the link limiter and push real links into its
	// shared fallback. The lookup itself is bounded by hook-ip and the 100
	// entries.
	ctx, cancel := context.WithTimeout(r.Context(), hookDeadline)
	defer cancel()
	rows, err := s.Pool.Query(ctx,
		`SELECT client_state_hash, user_id, holder_writer_id FROM mailbox_links
		  WHERE provider = 'outlook' AND client_state_hash = ANY($1::bytea[])`, hashes)
	if err != nil {
		s.logf("api: outlook hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	type match struct {
		hash []byte
		h    gmailpush.Holder
	}
	var matched []match
	for rows.Next() {
		var m match
		if err := rows.Scan(&m.hash, &m.h.UserID, &m.h.WriterID); err != nil {
			rows.Close()
			s.logf("api: outlook hook: route: %v", err)
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
			return
		}
		matched = append(matched, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		// A read that failed part-way is not "no such link".
		s.logf("api: outlook hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	o.Counters.Unknown.Add(int64(len(hashes) - len(matched)))
	if len(matched) > 0 && !o.HookGlobal.Allow("") {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var holders []gmailpush.Holder
	for _, m := range matched {
		// Per link, so one link's flood cannot spend another's budget.
		if !o.HookLink.Allow(hex.EncodeToString(m.hash)) {
			o.Counters.LinkLimited.Add(1)
			continue
		}
		holders = append(holders, m.h)
	}

	reason := pushv2.ReasonMail
	if lifecycle {
		reason = pushv2.ReasonNudge
	}
	hour := s.now().UTC().Truncate(time.Hour)
	tripped := s.fuseTripped()
	for _, h := range holders {
		s.waker().WakeWriter(context.WithoutCancel(ctx), h.UserID, h.WriterID, reason)
		o.Counters.Woken.Add(1)
		// Like Gmail's: the hour of the last mail wake, at most one write per
		// link per hour, none while the disk fuse is tripped.
		if !lifecycle && !tripped {
			s.markWakeHour(ctx, gmailpush.ProviderOutlook, h, hour)
		}
	}
	w.WriteHeader(http.StatusAccepted)
}

func (s *Server) markWakeHour(ctx context.Context, provider string, h gmailpush.Holder, hour time.Time) {
	if _, err := s.Pool.Exec(ctx,
		`UPDATE mailbox_links SET last_wake_hour = $3
		  WHERE user_id = $1 AND holder_writer_id = $2 AND provider = $4
		    AND last_wake_hour IS DISTINCT FROM $3`, h.UserID, h.WriterID, hour, provider); err != nil {
		s.logf("api: %s hook: wake hour: %v", provider, err)
	}
}
