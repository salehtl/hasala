package api

import "net/http"

// routes_events.go is a pre-assigned seam (spec 02 §4.2): the account's auth
// events (spec 02 §10.16, route #68). Owner: WS-3. Handler calls mountEvents on
// every start; it registers nothing until that workstream fills it in, so
// adding these routes never touches api.go.
func (s *Server) mountEvents(mux *http.ServeMux) {}
