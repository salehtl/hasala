// Package gmailpush relays Gmail's Pub/Sub change notices into content-free
// wakes (spec 02 §13): the routing key that turns a Gmail address into an
// HMAC the database can index without holding the address, the Pub/Sub push
// envelope parser, the watch-renewal nudge, and the startup check on the
// route key's fingerprint.
//
// The server holds no Google credential. A notice says only "this mailbox
// changed" (emailAddress and historyId); historyId is parsed for shape and
// never stored or logged, and the address lives only in a local variable for
// the length of one request.
package gmailpush

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// RouteKey is the 32-byte mailbox routing key (HASALA_MAILBOX_ROUTE_KEY_FILE).
type RouteKey struct{ k []byte }

// ErrRouteKey is a route key file that is not exactly 64 hex characters.
var ErrRouteKey = errors.New("gmailpush: the route key file holds exactly 64 hex characters")

// ParseRouteKey reads the key file's contents: 64 hex characters, at most one
// trailing newline. Anything else is refused.
func ParseRouteKey(s string) (RouteKey, error) {
	s = strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r")
	if len(s) != 64 {
		return RouteKey{}, ErrRouteKey
	}
	k, err := hex.DecodeString(s)
	if err != nil {
		return RouteKey{}, ErrRouteKey
	}
	return RouteKey{k: k}, nil
}

// NewRouteKey wraps 32 raw bytes (tests).
func NewRouteKey(raw []byte) (RouteKey, error) {
	if len(raw) != 32 {
		return RouteKey{}, ErrRouteKey
	}
	return RouteKey{k: append([]byte(nil), raw...)}, nil
}

// NormalizeAddress is spec 02 §13.3's address: trimmed, ASCII letters lowered,
// every other byte unchanged.
func NormalizeAddress(x string) string {
	x = strings.Trim(x, " \t\r\n")
	b := []byte(x)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

// The mailbox providers: the strings the database, the API and the address
// HMAC use.
const (
	ProviderGmail   = "gmail"
	ProviderOutlook = "outlook"
)

// AddressHMACFor is HMAC(route_key, "hasala/v1/mailbox-route" ‖ 00 ‖ provider
// ‖ 00 ‖ address) over the normalized address. The provider is one of the
// Provider constants, so one address linked through two providers gives two
// unrelated values.
func (r RouteKey) AddressHMACFor(provider, address string) []byte {
	m := hmac.New(sha256.New, r.k)
	m.Write([]byte(keyproto.DomainMailboxRoute))
	m.Write([]byte{0})
	m.Write([]byte(provider))
	m.Write([]byte{0})
	m.Write([]byte(NormalizeAddress(address)))
	return m.Sum(nil)
}

// AddressHMAC is AddressHMACFor(ProviderGmail, address), the key the Gmail
// hook routes by.
func (r RouteKey) AddressHMAC(address string) []byte { return r.AddressHMACFor(ProviderGmail, address) }

// KeyID is HMAC(route_key, "hasala/v1/mailbox-route-key-id")[0:8].
func (r RouteKey) KeyID() []byte {
	m := hmac.New(sha256.New, r.k)
	m.Write([]byte(keyproto.DomainMailboxRouteKeyID))
	return m.Sum(nil)[:8]
}

// Valid reports whether the key was loaded.
func (r RouteKey) Valid() bool { return len(r.k) == 32 }

// CheckKeyID is the startup check of spec 02 §13.3: every stored link was made
// under the current route key, or serve refuses to start.
func CheckKeyID(ctx context.Context, pool *pgxpool.Pool, r RouteKey) error {
	rows, err := pool.Query(ctx, `SELECT DISTINCT route_key_id FROM mailbox_links`)
	if err != nil {
		return fmt.Errorf("gmailpush: read route key ids: %w", err)
	}
	defer rows.Close()
	want := r.KeyID()
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			return err
		}
		if !bytes.Equal(id, want) {
			// Spec 02 §13.3 names `hasalad mailbox rekey --drop-links` for
			// this; that mode is not built yet, so the message says what it
			// would do.
			return errors.New("gmailpush: mailbox_links were made under another route key: put the " +
				"previous HASALA_MAILBOX_ROUTE_KEY_FILE back, or delete every mailbox_links row " +
				"(devices then offer \"Reconnect Gmail\")")
		}
	}
	return rows.Err()
}

// Notice is a decoded Gmail notification.
type Notice struct {
	EmailAddress string
}

// Envelope errors, each a 204 with its own counter (spec 02 §13.4 steps 6–8).
var (
	ErrMalformed           = errors.New("gmailpush: malformed push")
	ErrForeignSubscription = errors.New("gmailpush: push for another subscription")
)

// maxData bounds the decoded notice (spec 02 §13.4 step 8: 1 KiB).
const maxData = 1024

// ParseEnvelope is steps 6–8: the Pub/Sub push envelope, leniently (unknown
// fields ignored), its subscription, and its base64 data, which must be a
// small JSON object with a string emailAddress and a numeric or string
// historyId. The history id is checked for shape and dropped.
func ParseEnvelope(body []byte, subscription string) (Notice, error) {
	var env struct {
		Message *struct {
			Data string `json:"data"`
		} `json:"message"`
		Subscription string `json:"subscription"`
	}
	if err := json.Unmarshal(body, &env); err != nil || env.Message == nil {
		return Notice{}, ErrMalformed
	}
	if env.Subscription != subscription {
		return Notice{}, ErrForeignSubscription
	}
	if base64.StdEncoding.DecodedLen(len(env.Message.Data)) > maxData+3 {
		return Notice{}, ErrMalformed
	}
	data, err := base64.StdEncoding.DecodeString(env.Message.Data)
	if err != nil {
		if data, err = base64.URLEncoding.DecodeString(env.Message.Data); err != nil {
			return Notice{}, ErrMalformed
		}
	}
	if len(data) > maxData {
		return Notice{}, ErrMalformed
	}
	var n struct {
		EmailAddress *string         `json:"emailAddress"`
		HistoryID    json.RawMessage `json:"historyId"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&n); err != nil || n.EmailAddress == nil || *n.EmailAddress == "" || len(*n.EmailAddress) > 320 {
		return Notice{}, ErrMalformed
	}
	if !validHistoryID(n.HistoryID) {
		return Notice{}, ErrMalformed
	}
	return Notice{EmailAddress: *n.EmailAddress}, nil
}

func validHistoryID(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return false
	}
	if s[0] == '"' {
		var str string
		if json.Unmarshal(raw, &str) != nil {
			return false
		}
		s = str
	}
	if s == "" || len(s) > 20 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// Holder is one link a notice routes to.
type Holder struct {
	UserID   uuid.UUID
	WriterID string
}

// Counters are the hook's outcome counters (spec 02 §13.4, §20.1).
type Counters struct {
	Pushes, Woken, Malformed, ForeignSubscription, Unknown, LinkLimited, Unauthorized, Forbidden atomic.Int64
}

// Waker is the slice of pushv2.Waker the nudge needs.
type Waker interface {
	WakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r pushv2.Reason)
}

// QueueingWaker is a Waker that reports whether a wake was queued, as
// *pushv2.Dispatcher does.
type QueueingWaker interface {
	TryWakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r pushv2.Reason) bool
}

// Nudge is spec 02 §13.7, run every 15 minutes: a holder whose watch was never
// reported (an hour after linking) or expires within 36 hours gets one nudge
// wake, and no second one for 12 hours. The mark is taken back for a wake w
// did not queue (a QueueingWaker that answers false), so the next run tries
// again instead of 12 hours later. Only links of the given providers are
// nudged: those whose push this server relays, since a provider without one
// can never have a watch to renew.
func Nudge(ctx context.Context, pool *pgxpool.Pool, w Waker, providers ...string) (string, error) {
	if len(providers) == 0 {
		return "", nil
	}
	rows, err := pool.Query(ctx,
		`WITH due AS (
		   SELECT user_id, provider, last_nudge_at FROM mailbox_links
		    WHERE provider = ANY($1)
		      AND (watch_expires_at IS NULL AND created_at < now() - interval '1 hour'
		           OR watch_expires_at < now() + interval '36 hours')
		      AND (last_nudge_at IS NULL OR last_nudge_at < now() - interval '12 hours')
		    LIMIT 500
		    FOR UPDATE SKIP LOCKED)
		 UPDATE mailbox_links m SET last_nudge_at = now()
		   FROM due WHERE m.user_id = due.user_id AND m.provider = due.provider
		 RETURNING m.user_id, m.provider, m.holder_writer_id, due.last_nudge_at, m.last_nudge_at`, providers)
	if err != nil {
		return "", fmt.Errorf("gmailpush: nudge: %w", err)
	}
	type nudged struct {
		h          Holder
		provider   string
		prev, mark *time.Time
	}
	var due []nudged
	for rows.Next() {
		var n nudged
		if err := rows.Scan(&n.h.UserID, &n.provider, &n.h.WriterID, &n.prev, &n.mark); err != nil {
			rows.Close()
			return "", err
		}
		due = append(due, n)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", err
	}
	qw, queueing := w.(QueueingWaker)
	sent := 0
	for _, n := range due {
		if !queueing {
			w.WakeWriter(ctx, n.h.UserID, n.h.WriterID, pushv2.ReasonNudge)
			sent++
			continue
		}
		if qw.TryWakeWriter(ctx, n.h.UserID, n.h.WriterID, pushv2.ReasonNudge) {
			sent++
			continue
		}
		if _, err := pool.Exec(ctx,
			`UPDATE mailbox_links SET last_nudge_at = $3
			  WHERE user_id = $1 AND provider = $2 AND last_nudge_at = $4`,
			n.h.UserID, n.provider, n.prev, n.mark); err != nil {
			return "", fmt.Errorf("gmailpush: nudge: take back the mark: %w", err)
		}
	}
	if len(due) == 0 {
		return "", nil
	}
	if sent < len(due) {
		return fmt.Sprintf("nudged %d mailbox holder(s); %d not queued", sent, len(due)-sent), nil
	}
	return fmt.Sprintf("nudged %d mailbox holder(s)", sent), nil
}
