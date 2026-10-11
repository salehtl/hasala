package api

import "net/http"

// routes_stepup.go is a pre-assigned seam (spec 02 §4.2): POST
// /api/v1/auth/step-up/begin (spec 02 §8, route #9). Owner: WS-3. Handler calls
// mountStepUp on every start; it registers nothing until that workstream fills
// it in, so adding these routes never touches api.go.
func (s *Server) mountStepUp(mux *http.ServeMux) {}
