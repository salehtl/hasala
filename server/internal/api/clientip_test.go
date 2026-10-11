package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Spec 02 §16.1's cases (the shape of conformance's client-ip.json).
func TestClientKeyFor(t *testing.T) {
	for _, c := range []struct {
		name, peer, header string
		cloudflare         bool
		want               string
	}{
		{"loopback + IPv4", "127.0.0.1:5000", "192.0.2.7", true, "4:192.0.2.7"},
		{"loopback v6 peer + IPv4", "[::1]:5000", "192.0.2.7", true, "4:192.0.2.7"},
		{"loopback + mapped IPv4", "127.0.0.1:5000", "::ffff:192.0.2.7", true, "4:192.0.2.7"},
		{"loopback + IPv6 → /64", "127.0.0.1:5000", "2001:db8:1:2:aaaa:bbbb:cccc:dddd", true, "6:20010db800010002"},
		{"other loopback address", "127.0.0.53:5000", "198.51.100.1", true, "4:198.51.100.1"},
		{"non-loopback + header is ignored", "203.0.113.9:5000", "192.0.2.7", true, "peer:203.0.113.9"},
		{"loopback + garbage header", "127.0.0.1:5000", "not an address", true, "local"},
		{"loopback + list header", "127.0.0.1:5000", "192.0.2.7, 198.51.100.1", true, "local"},
		{"loopback + zoned header", "127.0.0.1:5000", "fe80::1%eth0", true, "local"},
		{"loopback + no header", "127.0.0.1:5000", "", true, "local"},
		{"none mode ignores the header", "127.0.0.1:5000", "192.0.2.7", false, "peer:127.0.0.1"},
		{"none mode, remote peer", "203.0.113.9:5000", "", false, "peer:203.0.113.9"},
	} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.peer
		if c.header != "" {
			r.Header.Set("Cf-Connecting-Ip", c.header)
		}
		// Headers nothing may read (fence test 3) change nothing.
		r.Header.Set("X-Real-Ip", "198.51.100.200")
		r.Header.Set("X-Forwarded-For", "198.51.100.201")
		r.Header.Set("True-Client-Ip", "198.51.100.202")
		r.Header.Set("Forwarded", "for=198.51.100.203")
		if got := ClientKeyFor(r, c.cloudflare); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

// AT-RL-1, AT-RL-2 and AT-RL-3 through the handler, on meta-ip (no database).
func TestPerIPLimitsFollowCfConnectingIP(t *testing.T) {
	srv := &Server{TrustCloudflare: true, Logf: func(string, ...any) {}}
	srv.MetaPerIP = NewLimiter(0, 1, metaMaxKeys, nil)
	h := srv.Handler()
	get := func(peer, ip string) int {
		r := httptest.NewRequest("GET", "/api/v1/meta", nil)
		r.RemoteAddr = peer
		if ip != "" {
			r.Header.Set("Cf-Connecting-Ip", ip)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	const tunnel = "127.0.0.1:40000"
	// AT-RL-1: one client is limited, a second client behind the same tunnel
	// is not.
	if get(tunnel, "192.0.2.1") != http.StatusOK || get(tunnel, "192.0.2.1") != http.StatusTooManyRequests {
		t.Fatal("192.0.2.1 was not limited on its own key")
	}
	if c := get(tunnel, "192.0.2.2"); c != http.StatusOK {
		t.Fatalf("a second client behind the tunnel got %d: the limit is global", c)
	}
	// AT-RL-3: one /64 is one bucket; another /64 is its own.
	if get(tunnel, "2001:db8::1") != http.StatusOK || get(tunnel, "2001:db8::ffff:2") != http.StatusTooManyRequests {
		t.Fatal("two addresses in one /64 did not share a bucket")
	}
	if c := get(tunnel, "2001:db8:0:1::1"); c != http.StatusOK {
		t.Fatalf("another /64 got %d", c)
	}
	// AT-RL-2: a non-loopback peer is keyed by itself, whatever it claims.
	if c := get("203.0.113.5:1", "192.0.2.99"); c != http.StatusOK {
		t.Fatalf("first request from a remote peer: %d", c)
	}
	if c := get("203.0.113.5:1", "192.0.2.100"); c != http.StatusTooManyRequests {
		t.Fatalf("a remote peer rotated Cf-Connecting-Ip past the limit: %d", c)
	}
}
