package api

import "net/http"

// routes_reset.go is a pre-assigned seam (spec 02 §4.2): the C9 password reset
// approved by a signed-in iPhone (spec 02 §10.9, routes #49–#54). Owner: WS-3.
// Handler calls mountReset on every start; it registers nothing until that
// workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountReset(mux *http.ServeMux) {}
