package pushv2

import (
	"context"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

type fakeSender struct {
	mu     sync.Mutex
	sent   []Target
	result func(Target) Result
	block  chan struct{}
}

func (f *fakeSender) Send(_ context.Context, t Target) Result {
	if f.block != nil {
		<-f.block
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, t)
	if f.result != nil {
		return f.result(t)
	}
	return ResultSent
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time              { return c.t }
func (c *clock) add(d time.Duration)         { c.t = c.t.Add(d) }
func fixedTarget(b byte) Target              { return Target{TokenHex: tokenHex(b), Environment: EnvProduction} }
func wake(d *Dispatcher, t Target, r Reason) { d.run(bg, job{tokens: []Target{t}, r: r}) }

// AT-APNS-5: debounce and caps (spec 02 §12.4).
func TestDebounceAndCaps(t *testing.T) {
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(nil, s)
	d.Now = c.now
	tok := fixedTarget(1)

	// 10 Gmail notifications in 5 s: the leading send, then one trailing at 300 s.
	for range 10 {
		wake(d, tok, ReasonMail)
		c.add(500 * time.Millisecond)
		d.Flush(bg)
	}
	if s.count() != 1 {
		t.Fatalf("%d sends inside the window, want the leading one", s.count())
	}
	c.t = c.t.Add(300*time.Second - 5*time.Second)
	d.Flush(bg)
	if s.count() != 2 {
		t.Fatalf("%d sends after the window, want leading + trailing", s.count())
	}
	c.add(10 * time.Minute)
	d.Flush(bg)
	if s.count() != 2 {
		t.Fatalf("a closed window with nothing pending sent again: %d", s.count())
	}

	// The 7th Gmail wake in an hour is dropped (each spaced past the window).
	tok2 := fixedTarget(2)
	sent := s.count()
	for i := range 7 {
		wake(d, tok2, ReasonMail)
		c.add(301 * time.Second)
		d.Flush(bg)
		if i < 6 && s.count() != sent+i+1 {
			t.Fatalf("mail wake %d not sent", i+1)
		}
	}
	if s.count() != sent+6 {
		t.Fatalf("the 7th mail wake in an hour was sent (%d)", s.count()-sent)
	}
	if d.Stats.Dropped[ReasonMail].Load() == 0 {
		t.Fatal("the dropped mail wake was not counted")
	}

	// The 13th wake across mail, sync and nudge is dropped; a security wake
	// after both caps is still sent.
	tok3 := fixedTarget(3)
	sent = s.count()
	for i := range 6 {
		wake(d, tok3, ReasonNudge)
		_ = i
	}
	for range 6 {
		wake(d, tok3, ReasonSync)
		c.add(121 * time.Second)
		d.Flush(bg)
	}
	if s.count() != sent+12 {
		t.Fatalf("%d of 12 allowed wakes sent", s.count()-sent)
	}
	wake(d, tok3, ReasonNudge)
	if s.count() != sent+12 {
		t.Fatal("the 13th wake in the hour was sent")
	}
	wake(d, tok3, ReasonSecurity)
	wake(d, tok3, ReasonAccountGone)
	if s.count() != sent+14 {
		t.Fatal("a security or account-gone wake was capped")
	}
	// An hour later the caps have rolled.
	c.add(time.Hour)
	wake(d, tok3, ReasonNudge)
	if s.count() != sent+15 {
		t.Fatal("the cap did not roll after an hour")
	}
}

func TestCooldownAndConfigPause(t *testing.T) {
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{result: func(t Target) Result {
		if t.TokenHex == tokenHex(1) {
			return ResultCooldown
		}
		return ResultSent
	}}
	d := NewDispatcher(nil, s)
	d.Now = c.now
	wake(d, fixedTarget(1), ReasonNudge)
	wake(d, fixedTarget(1), ReasonNudge)
	if s.count() != 1 {
		t.Fatalf("a cooled token was sent to: %d", s.count())
	}
	c.add(61 * time.Second)
	wake(d, fixedTarget(1), ReasonNudge)
	if s.count() != 2 {
		t.Fatal("the cooldown did not end after 60 s")
	}

	s.result = func(Target) Result { return ResultConfig }
	wake(d, fixedTarget(2), ReasonNudge)
	s.result = nil
	wake(d, fixedTarget(3), ReasonSecurity)
	if s.count() != 3 {
		t.Fatalf("sent during the configuration pause: %d", s.count())
	}
	c.add(5*time.Minute + time.Second)
	wake(d, fixedTarget(3), ReasonSecurity)
	if s.count() != 4 {
		t.Fatal("the configuration pause did not end")
	}
}

// AT-APNS-6: a full queue drops instead of blocking the caller.
func TestAFullQueueNeverBlocks(t *testing.T) {
	s := &fakeSender{block: make(chan struct{})}
	d := NewDispatcher(nil, s)
	done := make(chan struct{})
	go func() {
		for range queueCapacity + 100 {
			d.WakeTokens(bg, []Target{fixedTarget(1)}, ReasonSecurity)
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("enqueueing blocked")
	}
	if d.Stats.Dropped[ReasonSecurity].Load() != 100 {
		t.Fatalf("dropped %d, want 100", d.Stats.Dropped[ReasonSecurity].Load())
	}
	close(s.block)
}

// AT-APNS-3 (the database half): a gone token's row is deleted; WakeWriter and
// WakeOthers reach exactly the right devices.
func TestDispatcherResolvesTokensAndForgetsGoneOnes(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	other := oplogtest.NewUser(t, pool)
	insert := func(user uuid.UUID, writer string, b byte) {
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
	a, b, c := "ios-11111111-1111-4111-8111-111111111111", "ios-22222222-2222-4222-8222-222222222222",
		"ios-33333333-3333-4333-8333-333333333333"
	insert(u, a, 1)
	insert(u, b, 2)
	insert(other, c, 3)
	s := &fakeSender{result: func(t Target) Result {
		if t.TokenHex == tokenHex(2) {
			return ResultGone
		}
		return ResultSent
	}}
	d := NewDispatcher(pool, s)
	d.run(bg, job{user: u, writer: a, r: ReasonMail, resolve: true})
	if s.count() != 1 || s.sent[0].TokenHex != tokenHex(1) {
		t.Fatalf("WakeWriter reached %v", s.sent)
	}
	d.run(bg, job{user: u, writer: a, others: true, r: ReasonSecurity, resolve: true})
	if s.count() != 2 || s.sent[1].TokenHex != tokenHex(2) {
		t.Fatalf("WakeOthers reached %v", s.sent)
	}
	var n int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM apns_tokens WHERE token_hex = $1`, tokenHex(2)).Scan(&n); err != nil || n != 0 {
		t.Fatalf("the gone token survived (%d, %v)", n, err)
	}
	if err := pool.QueryRow(bg, `SELECT count(*) FROM apns_tokens`).Scan(&n); err != nil || n != 2 {
		t.Fatalf("%d tokens left, want 2", n)
	}
}

func TestATrailingWakeSkipsATokenThatWasRemovedOrMoved(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUser(t, pool)
	other := oplogtest.NewUser(t, pool)
	insert := func(user uuid.UUID, writer string, b byte) {
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
	a, b, k := "ios-11111111-1111-4111-8111-111111111111", "ios-22222222-2222-4222-8222-222222222222",
		"ios-33333333-3333-4333-8333-333333333333"
	insert(u, a, 1)
	insert(u, b, 2)
	insert(other, k, 3)
	c := &clock{t: time.Unix(1_760_000_000, 0)}
	s := &fakeSender{}
	d := NewDispatcher(pool, s)
	d.Now = c.now
	for range 2 {
		d.run(bg, job{user: u, writer: a, others: true, r: ReasonMail, resolve: true})
		d.run(bg, job{user: other, writer: k, r: ReasonMail, resolve: true})
	}
	if s.count() != 2 {
		t.Fatalf("%d leading sends, want 2", s.count())
	}
	if _, err := pool.Exec(bg, `DELETE FROM apns_tokens WHERE token_hex = $1`, tokenHex(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `UPDATE apns_tokens SET user_id = $2, writer_id = $3 WHERE token_hex = $1`,
		tokenHex(3), u, b); err != nil {
		t.Fatal(err)
	}
	c.add(mailWindow + time.Second)
	d.Flush(bg)
	if s.count() != 2 {
		t.Fatalf("trailing wakes reached %v, want none", s.sent[2:])
	}
	if d.Stats.Dropped[ReasonMail].Load() != 2 {
		t.Fatalf("dropped %d trailing wakes, want 2", d.Stats.Dropped[ReasonMail].Load())
	}

	d.run(bg, job{user: u, writer: b, r: ReasonMail, resolve: true})
	d.run(bg, job{user: u, writer: a, r: ReasonMail, resolve: true})
	d.run(bg, job{user: u, writer: a, r: ReasonMail, resolve: true})
	c.add(mailWindow + time.Second)
	d.Flush(bg)
	if s.count() != 5 {
		t.Fatalf("a live token's trailing wake was not sent: %v", s.sent)
	}
	live := 0
	for _, sent := range s.sent[2:] {
		if sent.TokenHex == tokenHex(1) {
			live++
		}
	}
	if live != 2 {
		t.Fatalf("a live token's trailing wake was not sent: %v", s.sent)
	}
}

func TestTryWakeWriterReportsAFullQueue(t *testing.T) {
	d := NewDispatcher(nil, &fakeSender{})
	u := uuid.New()
	for i := range queueCapacity {
		if !d.TryWakeWriter(bg, u, "w", ReasonNudge) {
			t.Fatalf("wake %d not queued", i)
		}
	}
	if d.TryWakeWriter(bg, u, "w", ReasonNudge) {
		t.Fatal("a wake past the queue's capacity was reported queued")
	}
	if d.TryWakeWriter(bg, u, "", ReasonNudge) {
		t.Fatal("a wake for no writer was reported queued")
	}
}
