package api

import "net/http"

// routes_freeze.go is a pre-assigned seam (spec 02 §4.2): freeze and unfreeze,
// including the CORS-free freeze link (spec 02 §10.13, routes #64–#66). Owner:
// WS-3. Handler calls mountFreeze on every start; it registers nothing until
// that workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountFreeze(mux *http.ServeMux) {}
