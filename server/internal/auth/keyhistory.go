package auth

// keyhistory.go is the read side of the append-only key-history log (spec 02
// #27). Every entry carries the signature that authorized it and the nonce it
// was made over, so a device verifies the log itself (spec 01 §10.13) instead
// of trusting the server's account of it: registrations verify under the
// authority key the device derived from its own unwrapped seed, revocations
// under a writer that was live at that point of the log. The server returns
// the log and computes nothing over it.

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// KeyHistoryEntry is one append-only log row.
type KeyHistoryEntry struct {
	ID                 int64
	WriterID           string
	Alg                string
	PubKey             []byte
	DAKPubkey          []byte // registered rows only
	Event              string // EventRegistered | EventRevoked
	AuthorizedBy       string // AuthorizedAuthority | AuthorizedDevice
	AuthorizerWriterID string // revoked rows: the signing writer
	FinalCounter       *int64 // revoked rows: the pinned final head
	FinalHead          []byte
	Nonce              []byte
	Signature          []byte
	At                 time.Time
}

// KeyHistory returns a user's whole log, oldest first: ascending id makes the
// last element the head, so a truncated log changes the head a device compares.
func (w *Writers) KeyHistory(ctx context.Context, userID uuid.UUID) ([]KeyHistoryEntry, error) {
	if w == nil || w.Pool == nil {
		return nil, errors.New("auth: Writers.Pool is nil")
	}
	rows, err := w.Pool.Query(ctx,
		`SELECT id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, authorizer_writer_id,
		        final_counter, final_head, nonce, signature, at
		   FROM key_history WHERE user_id = $1 ORDER BY id`, userID)
	if err != nil {
		return nil, fmt.Errorf("auth: key history for user %s: %w", userID, err)
	}
	defer rows.Close()
	var out []KeyHistoryEntry
	for rows.Next() {
		var (
			e     KeyHistoryEntry
			authz *string
		)
		if err := rows.Scan(&e.ID, &e.WriterID, &e.Alg, &e.PubKey, &e.DAKPubkey, &e.Event, &e.AuthorizedBy, &authz,
			&e.FinalCounter, &e.FinalHead, &e.Nonce, &e.Signature, &e.At); err != nil {
			return nil, fmt.Errorf("auth: scan key history entry: %w", err)
		}
		if authz != nil {
			e.AuthorizerWriterID = *authz
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("auth: key history for user %s: %w", userID, err)
	}
	return out, nil
}
