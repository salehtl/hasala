package api

import "net/http"

// routes_signup.go is a pre-assigned seam (spec 02 §4.2): signup begin and
// verify, password signup (spec 02 §10.7, routes #43–#45). Owner: WS-3. Handler
// calls mountSignup on every start; it registers nothing until that workstream
// fills it in, so adding these routes never touches api.go.
func (s *Server) mountSignup(mux *http.ServeMux) {}
