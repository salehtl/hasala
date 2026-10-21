package purge

import (
	"github.com/salehtl/hasala/server/internal/pgtest"
	"testing"
	"time"
)

func TestASecondPurgeOfOneAccountQueuesNoSecondGoodbye(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool, "raced")
	exec(t, pool, `UPDATE users SET email_norm = 'raced@example.com' WHERE id = $1`, u)
	first, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Rollback(bg) }()
	if _, err := first.Exec(bg, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, u); err != nil {
		t.Fatal(err)
	}
	type result struct {
		rep Report
		err error
	}
	second := make(chan result, 1)
	go func() {
		rep, err := PurgeWith(bg, pool, u, Options{Goodbye: true})
		second <- result{rep, err}
	}()
	time.Sleep(300 * time.Millisecond)
	if _, err := first.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := first.Commit(bg); err != nil {
		t.Fatal(err)
	}
	r := <-second
	if r.err != nil {
		t.Fatal(r.err)
	}
	if len(r.rep.Users) != 0 || r.rep.Goodbyes != 0 {
		t.Fatalf("the second purge reports %v and %d goodbyes", r.rep.Users, r.rep.Goodbyes)
	}
	if n := countRows(t, pool, `SELECT count(*) FROM mail_log WHERE recipient = 'raced@example.com'`); n != 0 {
		t.Fatalf("%d goodbye emails queued by the second purge", n)
	}
}
