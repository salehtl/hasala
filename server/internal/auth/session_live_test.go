package auth

import (
	"testing"
	"time"
)

func TestTheSessionLivenessRuleIsTheSameInGoAndInSQL(t *testing.T) {
	f := newKeyFixture(t)
	now := f.clock.now()
	ttl := f.sessions.TTL
	for _, tc := range []struct {
		name    string
		last    time.Time
		expires time.Time
		revoked bool
		live    bool
	}{
		{name: "used now", last: now, expires: now.Add(time.Hour), live: true},
		{name: "revoked", last: now, expires: now.Add(time.Hour), revoked: true},
		{name: "cap ends now", last: now.Add(-time.Minute), expires: now},
		{name: "cap ends just after now", last: now.Add(-time.Minute), expires: now.Add(time.Microsecond), live: true},
		{name: "idle ends now", last: now.Add(-ttl), expires: now.Add(time.Hour)},
		{name: "idle ends just after now", last: now.Add(-ttl).Add(time.Microsecond), expires: now.Add(time.Hour), live: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			token := f.newSession()
			var at any
			var reason any
			if tc.revoked {
				at, reason = now, "logout"
			}
			if _, err := f.pool.Exec(bgctx,
				`UPDATE sessions SET created_at = $2, last_used_at = $3, expires_at = $4, revoked_at = $5, revoked_reason = $6
				  WHERE token_hash = $1`,
				tokenHash(token), now.Add(-3*time.Hour), tc.last, tc.expires, at, reason); err != nil {
				t.Fatal(err)
			}
			var inSQL bool
			if err := f.pool.QueryRow(bgctx,
				`SELECT EXISTS (SELECT 1 FROM sessions s WHERE s.token_hash = $1 AND `+LiveSessionSQL("s", "$2", "$3")+`)`,
				tokenHash(token), now, f.sessions.IdleSince(now)).Scan(&inSQL); err != nil {
				t.Fatal(err)
			}
			_, err := f.sessions.Info(bgctx, token)
			if inGo := err == nil; inGo != tc.live || inSQL != tc.live {
				t.Fatalf("Go says %v (%v), SQL says %v, want %v", inGo, err, inSQL, tc.live)
			}
		})
	}
}
