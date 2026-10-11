package api

import "net/http"

// routes_push.go is a pre-assigned seam (spec 02 §4.2): the APNs device-token
// routes (spec 02 §12). Owner: WS-4. Handler calls mountPush on every start; it
// registers nothing until that workstream fills it in, so adding these routes
// never touches api.go.
func (s *Server) mountPush(mux *http.ServeMux) {}
