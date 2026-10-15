// Package outlookpush relays Microsoft Graph change notifications for an
// Outlook mailbox into content-free wakes: the validation handshake's token
// check, and the parser that turns a notification body into the hashes of the
// clientState values it carries.
//
// The server holds no Microsoft credential and reads no mail. A Graph
// notification names the changed message (resource, resourceData); the parser
// decodes into a struct that has no field for either, so neither is ever held
// in a variable, logged or stored. The clientState is the per-link secret the
// server minted when the mailbox was linked: it is hashed on the spot and only
// the SHA-256 leaves this package, because the database holds only that hash.
package outlookpush

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"sync/atomic"
)

// MaxValidationToken bounds the validationToken the handshake echoes.
const MaxValidationToken = 256

// MaxEntries bounds the notifications one body may carry.
const MaxEntries = 100

// clientStateLen is the length of the clientState the link mints: 32 random
// bytes, base64url without padding.
const clientStateLen = 43

// ValidToken reports whether a validationToken may be echoed: 1 to 256 bytes,
// each printable ASCII (space to tilde). Anything else is refused, so the echo
// can never carry a control byte or a header-shaped line.
func ValidToken(tok string) bool {
	if tok == "" || len(tok) > MaxValidationToken {
		return false
	}
	for i := 0; i < len(tok); i++ {
		if tok[i] < 0x20 || tok[i] > 0x7e {
			return false
		}
	}
	return true
}

// The lifecycle events that wake the holder with a nudge: its subscription
// needs renewing, is gone, or Graph dropped notifications, and in each case
// the device must act (renew, resubscribe, scan).
const (
	EventReauthorizationRequired = "reauthorizationRequired"
	EventSubscriptionRemoved     = "subscriptionRemoved"
	EventMissed                  = "missed"
)

// ErrMalformed is a body that is not a notification collection.
var ErrMalformed = errors.New("outlookpush: malformed notification")

// Parsed is a notification body reduced to what routes it.
type Parsed struct {
	// Hashes are the SHA-256 of each distinct well-formed clientState, in
	// order of first appearance; at most MaxEntries.
	Hashes [][sha256.Size]byte
	// BadClientState counts entries whose clientState is absent or not the
	// shape the link mints: no link can match them.
	BadClientState int
	// Ignored counts lifecycle entries with an event that wakes nobody.
	Ignored int
}

// entry is one notification. It has no resource, resourceData or any other
// field Graph sends: encoding/json skips what a struct does not name.
type entry struct {
	ClientState    *string `json:"clientState"`
	LifecycleEvent string  `json:"lifecycleEvent"`
}

// Parse reads a Graph notification collection: a JSON object whose "value" is
// an array of 1 to MaxEntries objects. On the lifecycle path only the three
// lifecycle events count; on the main path every entry does. Duplicate
// clientStates collapse to one hash.
func Parse(body []byte, lifecycle bool) (Parsed, error) {
	var env struct {
		Value []json.RawMessage `json:"value"`
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&env); err != nil {
		return Parsed{}, ErrMalformed
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return Parsed{}, ErrMalformed // trailing data
	}
	if len(env.Value) == 0 || len(env.Value) > MaxEntries {
		return Parsed{}, ErrMalformed
	}
	var p Parsed
	seen := make(map[[sha256.Size]byte]bool, len(env.Value))
	for _, raw := range env.Value {
		var e entry
		if err := json.Unmarshal(raw, &e); err != nil {
			// Not an object, or a clientState that is not a string: no link
			// can match it, and the rest of the batch still counts.
			p.BadClientState++
			continue
		}
		if lifecycle && !wakes(e.LifecycleEvent) {
			p.Ignored++
			continue
		}
		if e.ClientState == nil || !wellFormed(*e.ClientState) {
			p.BadClientState++
			continue
		}
		h := sha256.Sum256([]byte(*e.ClientState))
		if !seen[h] {
			seen[h] = true
			p.Hashes = append(p.Hashes, h)
		}
	}
	return p, nil
}

func wakes(event string) bool {
	switch event {
	case EventReauthorizationRequired, EventSubscriptionRemoved, EventMissed:
		return true
	}
	return false
}

// wellFormed is the link's clientState shape: 43 base64url characters.
func wellFormed(cs string) bool {
	if len(cs) != clientStateLen {
		return false
	}
	for i := 0; i < len(cs); i++ {
		c := cs[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// Counters are the hooks' outcome counters.
type Counters struct {
	// Validations are echoed handshakes; BadValidation are refused tokens;
	// ValidationWithBody are requests carrying both a token and a body.
	Validations, BadValidation, ValidationWithBody atomic.Int64
	// Notifications are bodies received; Malformed are bodies that are not a
	// notification collection.
	Notifications, Malformed atomic.Int64
	// BadClientState, Unknown (well-formed but no link), LinkLimited and
	// Ignored count entries; Woken counts wakes sent.
	BadClientState, Unknown, LinkLimited, Ignored, Woken atomic.Int64
}
