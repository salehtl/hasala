package pushv2

// throttle.go is spec 02 §12.4: per-token debounce windows and hourly caps,
// in memory (lost on restart, which is acceptable: the worst case is a few
// extra background pushes, which Apple throttles on its side anyway).

import (
	"container/list"
	"time"

	"github.com/google/uuid"
)

// Windows and caps (spec 02 §12.4).
const (
	mailWindow      = 300 * time.Second
	syncWindow      = 120 * time.Second
	capWindow       = time.Hour
	mailCap         = 6
	totalCap        = 12
	cooldownFor     = 60 * time.Second
	throttleMaxKeys = 10_000
)

type tokenState struct {
	key string
	t   Target
	// Debounce windows: the end of the open window and whether a trailing
	// wake is owed when it closes, per debounced reason.
	windowEnd map[Reason]time.Time
	pending   map[Reason]bool
	owner     map[Reason]uuid.UUID
	// Sends counted toward the caps within the last hour.
	mailSends []time.Time
	allSends  []time.Time
	coolUntil time.Time
	elem      *list.Element
}

// throttle decides, per token, whether a wake goes out now, waits for the
// window's trailing edge, or is dropped. It is not safe for concurrent use;
// the dispatcher serializes access.
type throttle struct {
	states map[string]*tokenState
	lru    *list.List
}

func newThrottle() *throttle {
	return &throttle{states: map[string]*tokenState{}, lru: list.New()}
}

// decision is what admit says about one wake.
type decision uint8

const (
	sendNow decision = iota + 1
	deferred
	dropCap
	dropCool
)

func windowFor(r Reason) time.Duration {
	switch r {
	case ReasonMail:
		return mailWindow
	case ReasonSync:
		return syncWindow
	}
	return 0
}

func tokenKey(t Target) string { return t.Environment + ":" + t.TokenHex }

func exempt(r Reason) bool { return r == ReasonSecurity || r == ReasonAccountGone }

func (th *throttle) state(t Target) *tokenState {
	key := tokenKey(t)
	if s, ok := th.states[key]; ok {
		th.lru.MoveToFront(s.elem)
		return s
	}
	s := &tokenState{key: key, t: t, windowEnd: map[Reason]time.Time{}, pending: map[Reason]bool{},
		owner: map[Reason]uuid.UUID{}}
	s.elem = th.lru.PushFront(s)
	th.states[key] = s
	for th.lru.Len() > throttleMaxKeys {
		// An evicted entry loses only its pending trailing wake.
		old := th.lru.Back()
		th.lru.Remove(old)
		delete(th.states, old.Value.(*tokenState).key)
	}
	return s
}

func prune(ts []time.Time, now time.Time) []time.Time {
	i := 0
	for i < len(ts) && now.Sub(ts[i]) >= capWindow {
		i++
	}
	return ts[i:]
}

// capped reports whether one more wake of reason r would exceed a cap.
func (s *tokenState) capped(r Reason, now time.Time) bool {
	s.mailSends = prune(s.mailSends, now)
	s.allSends = prune(s.allSends, now)
	if exempt(r) {
		return false
	}
	if r == ReasonMail && len(s.mailSends) >= mailCap {
		return true
	}
	return len(s.allSends) >= totalCap
}

func (s *tokenState) count(r Reason, now time.Time) {
	if exempt(r) {
		return
	}
	if r == ReasonMail {
		s.mailSends = append(s.mailSends, now)
	}
	s.allSends = append(s.allSends, now)
}

// admit decides one wake for t at now, on behalf of owner (uuid.Nil for
// pre-collected tokens). A sendNow has already been counted.
func (th *throttle) admit(t Target, r Reason, now time.Time, owner uuid.UUID) decision {
	s := th.state(t)
	if !exempt(r) && now.Before(s.coolUntil) {
		return dropCool
	}
	if w := windowFor(r); w > 0 {
		if end, ok := s.windowEnd[r]; ok && now.Before(end) {
			s.pending[r] = true
			s.owner[r] = owner
			return deferred
		}
		if s.capped(r, now) {
			return dropCap
		}
		s.windowEnd[r] = now.Add(w)
		s.pending[r] = false
		s.count(r, now)
		return sendNow
	}
	if s.capped(r, now) {
		return dropCap
	}
	s.count(r, now)
	return sendNow
}

// trailing is one wake owed at the end of a window, for the account whose
// wake was deferred (uuid.Nil when the token was pre-collected).
type trailing struct {
	t     Target
	r     Reason
	owner uuid.UUID
}

// due closes every window that has ended by now and returns the trailing wakes
// owed, already counted against the caps; a trailing wake over a cap is
// dropped and reported in dropped.
func (th *throttle) due(now time.Time) (out []trailing, dropped []Reason) {
	for _, s := range th.states {
		for r, end := range s.windowEnd {
			if now.Before(end) {
				continue
			}
			delete(s.windowEnd, r)
			if !s.pending[r] {
				continue
			}
			s.pending[r] = false
			if now.Before(s.coolUntil) || s.capped(r, now) {
				dropped = append(dropped, r)
				continue
			}
			// The trailing wake opens a new window of its own, so a steady
			// stream of notices sends at most one wake per window.
			s.windowEnd[r] = now.Add(windowFor(r))
			s.count(r, now)
			out = append(out, trailing{t: s.t, r: r, owner: s.owner[r]})
		}
	}
	return out, dropped
}

// cool rests a token after a 429.
func (th *throttle) cool(t Target, now time.Time) {
	th.state(t).coolUntil = now.Add(cooldownFor)
}

// forget drops a token's state (its row was deleted).
func (th *throttle) forget(t Target) {
	key := tokenKey(t)
	if s, ok := th.states[key]; ok {
		th.lru.Remove(s.elem)
		delete(th.states, key)
	}
}
