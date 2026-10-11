package api

import (
	"encoding/hex"
	"net"
	"net/http"
)

// Trusted-proxy settings (server.trusted_proxy).
const (
	ProxyNone       = "none"
	ProxyCloudflare = "cloudflare"
)

// clientKey is the rate-limit key for an unauthenticated caller (spec 02
// §16.1). With trusted_proxy = cloudflare and a LOOPBACK peer (cloudflared on
// the same host), the key is Cf-Connecting-Ip: "4:<ipv4>", or "6:<the first 64
// bits in hex>" for IPv6 (one host owns a /64, D-8); a loopback peer without a
// parseable header is "local" (a health probe). Otherwise it is
// "peer:<remote address>". No other forwarded header (X-Forwarded-For,
// True-Client-IP, Forwarded) is ever read, and the header is never trusted
// from a peer that is not loopback, so no caller can pick its own key.
func (s *Server) clientKey(r *http.Request) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if s.TrustedProxy == ProxyCloudflare {
		if ip := net.ParseIP(peer); ip != nil && ip.IsLoopback() {
			if v := net.ParseIP(r.Header.Get("Cf-Connecting-Ip")); v != nil {
				if v4 := v.To4(); v4 != nil {
					return "4:" + v4.String()
				}
				return "6:" + hex.EncodeToString(v.To16()[:8])
			}
			return "local"
		}
	}
	return "peer:" + peer
}
