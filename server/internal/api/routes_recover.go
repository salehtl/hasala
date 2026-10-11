package api

import "net/http"

// routes_recover.go is a pre-assigned seam (spec 02 §4.2): access recovery with
// an email code and the phrase (spec 02 §10.4, routes #7, #48, #8). Owner:
// WS-3. Handler calls mountRecover on every start; it registers nothing until
// that workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountRecover(mux *http.ServeMux) {}
