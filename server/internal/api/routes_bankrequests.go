package api

import "net/http"

// routes_bankrequests.go is a pre-assigned seam (spec 02 §4.2): POST
// /api/v1/bank-requests (spec 07 §5.6, route #74). Owner: WS-19 (spec 07).
// Handler calls mountBankRequests on every start; it registers nothing until
// that workstream fills it in, so adding these routes never touches api.go.
func (s *Server) mountBankRequests(mux *http.ServeMux) {}
