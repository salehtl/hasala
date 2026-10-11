package api

// keyhistory.go serves the append-only key-history log (spec 02 #27) to the
// device it belongs to. Every entry carries its nonce and signature, so the
// device verifies the log itself (spec 01 §10.13): registrations under the
// authority key it derived from its own unwrapped seed, revocations under a
// writer that was live at that point. The server computes nothing over it.

import (
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

// KeyHistoryEntry is one entry, in wire form.
type KeyHistoryEntry struct {
	ID                 string    `json:"id"` // decimal
	WriterID           string    `json:"writer_id"`
	Alg                string    `json:"alg"`
	PubKey             string    `json:"pubkey"`               // b64
	DAKPubkey          *string   `json:"dak_pubkey"`           // b64; registered rows only
	Event              string    `json:"event"`                // registered | revoked
	AuthorizedBy       string    `json:"authorized_by"`        // authority | device
	AuthorizerWriterID *string   `json:"authorizer_writer_id"` // revoked rows
	FinalCounter       *string   `json:"final_counter"`        // decimal; revoked rows
	FinalHead          *string   `json:"final_head"`           // b64; revoked rows
	Nonce              string    `json:"nonce"`                // b64
	Signature          string    `json:"signature"`            // b64
	At                 time.Time `json:"at"`
}

// KeyHistoryResponse answers GET /api/v1/key-history: oldest first, complete;
// the last element is the head.
type KeyHistoryResponse struct {
	Entries []KeyHistoryEntry `json:"entries"`
}

func (s *Server) handleKeyHistory(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	log, err := s.Writers.KeyHistory(r.Context(), userID)
	if err != nil {
		s.logf("api: key history for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := KeyHistoryResponse{Entries: make([]KeyHistoryEntry, 0, len(log))}
	str := func(s string) *string { return &s }
	for _, e := range log {
		x := KeyHistoryEntry{
			ID: strconv.FormatInt(e.ID, 10), WriterID: e.WriterID, Alg: e.Alg, PubKey: b64(e.PubKey),
			Event: e.Event, AuthorizedBy: e.AuthorizedBy, Nonce: b64(e.Nonce), Signature: b64(e.Signature), At: e.At,
		}
		if e.DAKPubkey != nil {
			x.DAKPubkey = str(b64(e.DAKPubkey))
		}
		if e.AuthorizerWriterID != "" {
			x.AuthorizerWriterID = str(e.AuthorizerWriterID)
		}
		if e.FinalCounter != nil {
			x.FinalCounter = str(strconv.FormatInt(*e.FinalCounter, 10))
		}
		if e.FinalHead != nil {
			x.FinalHead = str(b64(e.FinalHead))
		}
		out.Entries = append(out.Entries, x)
	}
	writeJSON(w, http.StatusOK, out)
}
