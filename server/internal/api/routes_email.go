package api

import "net/http"

// routes_email.go is a pre-assigned seam (spec 02 §4.2): email change and
// re-verification (spec 02 §10.12, routes #59–#63). Owner: WS-3. Handler calls
// mountEmail on every start; it registers nothing until that workstream fills
// it in, so adding these routes never touches api.go.
func (s *Server) mountEmail(mux *http.ServeMux) {}
