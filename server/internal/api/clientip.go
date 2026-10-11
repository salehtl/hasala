package api

// clientip.go is spec 02 §16.1: the rate-limit key for an unauthenticated
// caller.
//
// Behind cloudflared every request arrives from loopback, so the peer address
// alone would make every per-IP limiter one global limit (the whole internet
// sharing six waitlist sign-ups an hour). With server.trusted_proxy =
// cloudflare, a request from a loopback peer is keyed by Cf-Connecting-Ip, and
// an IPv6 client by its /64 (D-8: one host owns a /64 and could otherwise
// rotate past the limiter). The header is trusted ONLY from loopback: a
// non-loopback peer is keyed by its own address whatever it sends, and config
// load refuses trusted_proxy = cloudflare unless http_listen is loopback, so a
// header from the open network never reaches this code with a loopback peer.
//
// No other forwarded header (X-Forwarded-For, True-Client-IP, Forwarded) is
// ever read (fence test 3).

import (
	"context"
	"encoding/hex"
	"net"
	"net/http"
	"net/netip"
)

// cfConnectingIP is the one forwarded header hasalad reads.
const cfConnectingIP = "Cf-Connecting-Ip"

type clientKeyCtx struct{}

// ClientKeyFor is §16.1's function: the limiter key for r given the deployment's
// trusted proxy ("cloudflare" or anything else, which is "none").
func ClientKeyFor(r *http.Request, trustCloudflare bool) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if trustCloudflare && isLoopbackHost(peer) {
		if ip, err := netip.ParseAddr(r.Header.Get(cfConnectingIP)); err == nil && ip.Zone() == "" {
			ip = ip.Unmap()
			if ip.Is4() {
				return "4:" + ip.String()
			}
			b := ip.As16()
			return "6:" + hex.EncodeToString(b[:8])
		}
		// A local process (a health probe, an operator's curl): one shared key.
		return "local"
	}
	return "peer:" + peer
}

func isLoopbackHost(host string) bool {
	ip, err := netip.ParseAddr(host)
	return err == nil && ip.Unmap().IsLoopback()
}

// withClientKey computes the key once per request, before any handler, so
// every limiter on the request sees the same one.
func (s *Server) withClientKey(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k := ClientKeyFor(r, s.TrustCloudflare)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), clientKeyCtx{}, k)))
	})
}

// clientKey is the rate-limit key for an unauthenticated caller. A request
// that did not pass through Handler (a handler called directly in a test) is
// keyed by its peer, as trusted_proxy = none would.
func clientKey(r *http.Request) string {
	if k, ok := r.Context().Value(clientKeyCtx{}).(string); ok {
		return k
	}
	return ClientKeyFor(r, false)
}
