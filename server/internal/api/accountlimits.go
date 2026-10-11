package api

import (
	"net/http"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authkeys"
)

// The account routes' in-memory limiters (spec 02 §16.2). Every one has a
// bounded key space; unauthenticated limiters run before any DB work.
const (
	accountLimiterKeys = 65536

	recoverIPRate  = 3.0 / 3600
	recoverIPBurst = 3
	codeIPRate     = 10.0 / 60
	codeIPBurst    = 10
	resetIPRate    = 30.0 / 60
	resetIPBurst   = 30
	freezeIPRate   = 10.0 / 60
	freezeIPBurst  = 10
	freezeGlobal   = 20.0
	freezeGlobalB  = 100
	devFreezeIP    = 10.0 / 60
	devFreezeIPB   = 10
	devFreezeWr    = 6.0 / 3600
	devFreezeWrB   = 3
	devFreezeGl    = 10.0
	devFreezeGlB   = 50
)

func (s *Server) defaultAccountLimiters() {
	set := func(l **Limiter, rate, burst float64, keys int) {
		if *l == nil {
			*l = NewLimiter(rate, burst, keys, s.now)
		}
	}
	set(&s.RecoverPerIP, recoverIPRate, recoverIPBurst, accountLimiterKeys)
	set(&s.CodePerIP, codeIPRate, codeIPBurst, accountLimiterKeys)
	set(&s.ResetPerIP, resetIPRate, resetIPBurst, accountLimiterKeys)
	set(&s.FreezePerIP, freezeIPRate, freezeIPBurst, accountLimiterKeys)
	set(&s.FreezeGlobal, freezeGlobal, freezeGlobalB, 1)
	set(&s.DevFreezeIP, devFreezeIP, devFreezeIPB, accountLimiterKeys)
	set(&s.DevFreezeWriter, devFreezeWr, devFreezeWrB, accountLimiterKeys)
	set(&s.DevFreezeGlobal, devFreezeGl, devFreezeGlB, 1)
}

// EnableAccounts wires the server's key set, the PBKDF2 gate and the mailer
// into the account ceremonies and mounts their routes (spec 02 §7 #7, #8,
// #43–#68, #76–#78). serve calls it after loading HASALA_SALT_KEY_FILE and
// HASALA_AUTH_KEY_FILE; without it those routes are not mounted.
func (s *Server) EnableAccounts(keys *authkeys.Keys, gate *authkeys.Gate, mailer *auth.Mailer) {
	if s.StepUp == nil {
		s.StepUp = &auth.StepUp{Pool: s.Pool, Passkeys: s.Passkeys}
	}
	s.StepUp.Keys, s.StepUp.Gate, s.StepUp.Mail = keys, gate, mailer
	if s.StepUp.Now == nil {
		s.StepUp.Now = s.Now
	}
	if s.Passkeys != nil {
		s.Passkeys.Mail = mailer
		if s.Passkeys.StepUp == nil {
			s.Passkeys.StepUp = s.StepUp
		}
	}
	if s.Writers != nil {
		s.Writers.Mail = mailer
	}
	s.Accounts = &auth.Accounts{Pool: s.Pool, Keys: keys, Gate: gate, Sessions: s.Sessions, Passkeys: s.Passkeys,
		StepUp: s.StepUp, Mail: mailer, Now: s.Now}
}

// limited runs the unauthenticated limiters in order, before any DB work.
func (s *Server) limited(h http.HandlerFunc, ls ...*Limiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := s.clientKey(r)
		for _, l := range ls {
			k := key
			if l == s.PasskeyGlobal || l == s.FreezeGlobal || l == s.DevFreezeGlobal {
				k = ""
			}
			if !l.Allow(k) {
				w.Header().Set("Retry-After", "60")
				writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
				return
			}
		}
		h(w, r)
	}
}

// userLimited is account-user (spec 02 §16.2) on a session route.
func (s *Server) userLimited(h authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
		if !s.AccountPerUser.Allow(userID.String()) {
			w.Header().Set("Retry-After", "60")
			writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
			return
		}
		h(w, r, userID)
	}
}
