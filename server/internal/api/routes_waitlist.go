package api

import "net/http"

// routes_waitlist.go is a pre-assigned seam (spec 02 §4.2): the website's
// waitlist routes, POST /api/v1/waitlist, /waitlist/confirm, /waitlist/leave
// and their CORS preflight (spec 07 §5, routes #71–#73, #75). Owner: WS-19
// (spec 07). Handler calls mountWaitlist on every start; it registers nothing
// until that workstream fills it in, so adding these routes never touches
// api.go.
func (s *Server) mountWaitlist(mux *http.ServeMux) {}
