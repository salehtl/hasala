package api

import "net/http"

// routes_password.go is a pre-assigned seam (spec 02 §4.2): password salt and
// sign-in, set, change, remove, C8 (spec 02 §10.8, §10.10). Owner: WS-3.
// Handler calls mountPassword on every start; it registers nothing until that
// workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountPassword(mux *http.ServeMux) {}
