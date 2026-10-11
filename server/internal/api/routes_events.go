package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

// routes_events.go: the account's auth events (spec 02 §10.16, route #68).
// Owner: WS-3.
func (s *Server) mountEvents(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/auth/events", s.requireSession(s.userLimited(s.handleAuthEvents)))
}

// AuthEventWire is one event.
type AuthEventWire struct {
	ID           string    `json:"id"` // dec
	Kind         string    `json:"kind"`
	At           time.Time `json:"at"`
	Method       *string   `json:"method"`
	WriterID     *string   `json:"writer_id"`
	CredentialID *string   `json:"credential_id"` // b64url
}

// AuthEventsResponse is #68's answer: newest first, at most 200, at most 90
// days.
type AuthEventsResponse struct {
	Events []AuthEventWire `json:"events"`
}

func (s *Server) handleAuthEvents(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	rows, err := s.Pool.Query(r.Context(),
		`SELECT id, kind, at, method, writer_id, credential_id FROM auth_events
		  WHERE user_id = $1 AND at > $2 ORDER BY id DESC LIMIT 200`, userID, s.now().Add(-90*24*time.Hour))
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	defer rows.Close()
	out := AuthEventsResponse{Events: []AuthEventWire{}}
	for rows.Next() {
		var (
			e    AuthEventWire
			id   int64
			cred []byte
		)
		if err := rows.Scan(&id, &e.Kind, &e.At, &e.Method, &e.WriterID, &cred); err != nil {
			s.writeKeyErr(w, r, err)
			return
		}
		e.ID, e.At = strconv.FormatInt(id, 10), e.At.UTC()
		if cred != nil {
			c := b64url(cred)
			e.CredentialID = &c
		}
		out.Events = append(out.Events, e)
	}
	if err := rows.Err(); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}
