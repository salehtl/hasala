package console

// health.go is the console's second listener (spec 07 §13.3,
// HASALA_CONSOLE_METRICS_LISTEN): GET /healthz for probe P8. It is not behind
// identify (Prometheus and the health probe reach it on loopback) and says
// nothing about any person: the database, the App Store Connect key and how
// many requests carrying a Cloudflare header reached the console in the last
// 24 hours. Any such refusal turns it 503, so a tunnel leak to the console
// pages the owner.
//
// The count lives in memory, so a restart forgets it (the refusal is also an
// ERROR in the journal). /metrics is not built yet and answers 404.

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

const healthDBTimeout = 2 * time.Second

// refusalLog keeps the times of recent refusals, bounded.
type refusalLog struct {
	mu    sync.Mutex
	times []time.Time
}

const refusalLogMax = 1024

func (l *refusalLog) add(t time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.times) == refusalLogMax {
		l.times = l.times[1:]
	}
	l.times = append(l.times, t)
}

func (l *refusalLog) since(t time.Time) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, x := range l.times {
		if x.After(t) {
			n++
		}
	}
	return n
}

// HealthBody is GET /healthz's body.
type HealthBody struct {
	Status           string `json:"status"`
	DB               string `json:"db"`
	ASC              string `json:"asc"`
	TunnelRefusals24 int    `json:"tunnel_refusals_24h"`
}

// HealthHandler serves the metrics listener: GET /healthz only.
func (c *Console) HealthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		b := HealthBody{Status: "ok", DB: "ok", ASC: "disabled",
			TunnelRefusals24: c.tunnel.since(c.now().Add(-24 * time.Hour))}
		ctx, cancel := context.WithTimeout(r.Context(), healthDBTimeout)
		defer cancel()
		if c.Pool == nil || c.Pool.Ping(ctx) != nil {
			b.DB = "down"
		}
		code := http.StatusOK
		if b.DB != "ok" || b.TunnelRefusals24 > 0 {
			b.Status, code = "fail", http.StatusServiceUnavailable
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(b)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	return mux
}
