package api

import (
	"net/http"
	"time"
)

// meta-ip (spec 02 §16.2): 1/s per client IP, burst 20; the client IP is
// clientip.go's key.
const (
	metaRate    = 1.0
	metaBurst   = 20
	metaMaxKeys = 4096
)

// MetaResponse is GET /api/v1/meta (spec 02 §7 #2): what a device needs to
// know about this server before it signs in. Everything here is public.
type MetaResponse struct {
	RPID        string `json:"rp_id"`
	MinIOSBuild int    `json:"min_ios_build"`
	// GmailWatchTopic is the Pub/Sub topic a device watches its mailbox on,
	// and null whenever the hook (§7 #39) is not mounted: with no topic the
	// app skips users.watch, so it never makes a watch this server cannot
	// relay. The mailbox link (#34–#38) may be mounted either way.
	GmailWatchTopic *string `json:"gmail_watch_topic"`
	// LogGeneration is the integer in HASALA_LOG_GENERATION_FILE (§15.5): a
	// device that sees it rise was restored under, and says so instead of
	// reporting tampering.
	LogGeneration int `json:"log_generation"`
	// ServerTime is RFC 3339, UTC, to the second.
	ServerTime string `json:"server_time"`
}

// Meta is the configuration GET /api/v1/meta reports. NewServer fills it;
// gmail_watch_topic comes from Server.Gmail.Push instead.
type Meta struct {
	RPID        string
	MinIOSBuild int
	// LogGeneration is ≥ 1; zero is reported as 1 (an absent file).
	LogGeneration int
}

func (s *Server) mountMeta(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/meta", s.handleMeta)
}

func (s *Server) handleMeta(w http.ResponseWriter, r *http.Request) {
	if !s.MetaPerIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many requests; try again shortly")
		return
	}
	gen := s.Meta.LogGeneration
	if gen < 1 {
		gen = 1
	}
	// The topic comes with the hook's own configuration, so a topic is never
	// offered without the hook that relays its notices.
	var topic *string
	if p := s.gmailPush(); p != nil && p.Topic != "" {
		t := p.Topic
		topic = &t
	}
	writeJSON(w, http.StatusOK, MetaResponse{
		RPID:            s.Meta.RPID,
		MinIOSBuild:     s.Meta.MinIOSBuild,
		GmailWatchTopic: topic,
		LogGeneration:   gen,
		ServerTime:      s.now().UTC().Truncate(time.Second).Format(time.RFC3339),
	})
}
