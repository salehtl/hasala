package api

import "net/http"

// routes_mailboxlink.go is a pre-assigned seam (spec 02 §4.2): the Gmail
// mailbox link routes, #34–#39, mounted only with the [gmail] group configured
// (spec 02 §13.2). Owner: WS-4. Handler calls mountMailboxLink on every start;
// it registers nothing until that workstream fills it in, so adding these
// routes never touches api.go.
func (s *Server) mountMailboxLink(mux *http.ServeMux) {}
