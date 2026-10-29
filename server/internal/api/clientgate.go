package api

import (
	"net/http"
	"strconv"
	"strings"
)

func (s *Server) clientGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		floor := s.Meta.MinIOSBuild
		if floor > 0 && !clientGateExempt(r.URL.Path) {
			if b, ok := iosBuild(r.Header.Get("Hasala-Client")); ok && b < int64(floor) {
				writeErr(w, http.StatusUpgradeRequired, "upgrade_required",
					"this version of Hasala is too old; install the newest build")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func clientGateExempt(path string) bool {
	return path == "/api/v1/meta" || path == "/api/v1/healthz"
}

func iosBuild(h string) (int64, bool) {
	parts := strings.Split(h, "/")
	if len(parts) != 3 || parts[0] != "ios" {
		return 0, false
	}
	digits := strings.ReplaceAll(parts[2], ".", "")
	if digits == "" || len(digits) > 18 {
		return 0, false
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	b, err := strconv.ParseInt(digits, 10, 64)
	return b, err == nil
}
