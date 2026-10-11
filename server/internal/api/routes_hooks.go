package api

import "net/http"

// routes_hooks.go is a pre-assigned seam (spec 02 §4.2): POST
// /hooks/gmail/pubsub, the Pub/Sub push hook (spec 02 §13.4). Owner: WS-4.
// Handler calls mountHooks on every start; it registers nothing until that
// workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountHooks(mux *http.ServeMux) {}
