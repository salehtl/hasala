package pushv2

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func registerToken(t *testing.T, pool *pgxpool.Pool, user uuid.UUID, writer string, b byte) {
	t.Helper()
	oplogtest.NewWriter(t, pool, user, writer)
	var hash []byte
	if err := pool.QueryRow(bg,
		`INSERT INTO sessions (token_hash, user_id, minted_by, created_at, last_used_at, expires_at)
		 VALUES (sha256($1::bytea), $2, 'login', now(), now(), now() + interval '1 hour') RETURNING token_hash`,
		[]byte(writer), user).Scan(&hash); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg,
		`INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, 'production', now(), now())`, user, writer, hash, tokenHex(b)); err != nil {
		t.Fatal(err)
	}
}

func (d *Dispatcher) capCounts(tok Target) (mail, all int) {
	s := d.th.states[tokenKey(tok)]
	return len(s.mailSends), len(s.allSends)
}

func TestATrailingWakeDroppedForAPauseCostsNothing(t *testing.T) {
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(nil, s)
	d.Now = c.now
	tok := fixedTarget(1)
	for range mailCap - 2 {
		wake(d, tok, ReasonMail)
		c.add(mailWindow + time.Second)
		d.Flush(bg)
	}
	wake(d, tok, ReasonMail)
	wake(d, tok, ReasonMail)
	sent := s.count()
	if sent != mailCap-1 {
		t.Fatalf("%d leading sends, want %d", sent, mailCap-1)
	}
	c.add(mailWindow + time.Second)
	d.pause = c.t.Add(time.Minute)
	d.Flush(bg)
	if s.count() != sent {
		t.Fatalf("a trailing wake went out during the pause: %d", s.count()-sent)
	}
	if d.Stats.Dropped[ReasonMail].Load() != 1 {
		t.Fatalf("dropped %d, want the trailing wake", d.Stats.Dropped[ReasonMail].Load())
	}
	if mail, all := d.capCounts(tok); mail != sent || all != sent {
		t.Fatalf("caps count %d mail, %d total after %d sends", mail, all, sent)
	}
	c.add(time.Minute + time.Second)
	wake(d, tok, ReasonMail)
	if s.count() != sent+1 {
		t.Fatal("the pause took the wake the mail cap still allowed")
	}
}

func TestATrailingWakeForAnEnvironmentPauseCostsNothing(t *testing.T) {
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(nil, s)
	d.Now = c.now
	tok := Target{TokenHex: tokenHex(1), Environment: EnvSandbox}
	wake(d, tok, ReasonSync)
	wake(d, tok, ReasonSync)
	c.add(syncWindow + time.Second)
	d.envPause = map[string]time.Time{EnvSandbox: c.t.Add(time.Minute)}
	d.Flush(bg)
	if _, all := d.capCounts(tok); all != 1 || s.count() != 1 {
		t.Fatalf("total cap counts %d after %d sends", all, s.count())
	}
}

func TestATrailingWakeForAGoneTokenCostsNothing(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	gone, live := fixedTarget(1), fixedTarget(2)
	registerToken(t, pool, u, "ios-11111111-1111-4111-8111-111111111111", 1)
	registerToken(t, pool, u, "ios-22222222-2222-4222-8222-222222222222", 2)
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	for _, tok := range []Target{gone, live} {
		wake(d, tok, ReasonMail)
		wake(d, tok, ReasonMail)
	}
	if _, err := pool.Exec(bg, `DELETE FROM apns_tokens WHERE token_hex = $1`, gone.TokenHex); err != nil {
		t.Fatal(err)
	}
	c.add(mailWindow + time.Second)
	d.Flush(bg)
	if s.count() != 3 {
		t.Fatalf("%d sends, want two leading and the live trailing", s.count())
	}
	if mail, all := d.capCounts(gone); mail != 1 || all != 1 {
		t.Fatalf("the dropped wake was counted: %d mail, %d total", mail, all)
	}
	if mail, all := d.capCounts(live); mail != 2 || all != 2 {
		t.Fatalf("the trailing wake that went out was not counted: %d mail, %d total", mail, all)
	}
}

func TestATrailingWakeStaysUnderTheCapItWasOwedAgainst(t *testing.T) {
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(nil, s)
	d.Now = c.now
	tok := fixedTarget(1)
	for range mailCap - 1 {
		wake(d, tok, ReasonMail)
		c.add(mailWindow + time.Second)
		d.Flush(bg)
	}
	wake(d, tok, ReasonMail)
	wake(d, tok, ReasonMail)
	c.add(mailWindow + time.Second)
	d.Flush(bg)
	if s.count() != mailCap {
		t.Fatalf("%d sends, want the cap of %d", s.count(), mailCap)
	}
}
