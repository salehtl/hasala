package mailq

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

const untaggedConstraint = "mail_log_untagged_shape"

func wantUntaggedRefused(t *testing.T, name string, err error) {
	t.Helper()
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.ConstraintName != untaggedConstraint {
		t.Errorf("%s: err = %v, want a violation of %s", name, err, untaggedConstraint)
	}
}

func TestARowLacksATagOnlyWhileQueuedOrAsAnExpiredGoodbye(t *testing.T) {
	pool := pgtest.New(t)
	const head = `INSERT INTO mail_log (kind, lane, recipient, recipient_hint, params, status, `
	const addr = `'x@example.com', 'x•••@example.com', '{}', `
	for name, sql := range map[string]string{
		"sending":            head + `lease_until, created_at) VALUES ('test', 'transactional', ` + addr + `'sending', now(), now())`,
		"sent":               head + `sent_at, final_at, created_at) VALUES ('test', 'transactional', ` + addr + `'sent', now(), now(), now())`,
		"bounced":            head + `final_at, created_at) VALUES ('test', 'transactional', ` + addr + `'bounced', now(), now())`,
		"suppressed":         head + `final_at, created_at) VALUES ('test', 'waitlist', ` + addr + `'suppressed', now(), now())`,
		"failed":             head + `final_at, created_at) VALUES ('test', 'transactional', ` + addr + `'failed', now(), now())`,
		"failed, no address": head + `final_at, created_at) VALUES ('test', 'transactional', NULL, 'x•••@example.com', '{}', 'failed', now(), now())`,
		"goodbye, addressed": head + `final_at, created_at) VALUES ('deleted', 'transactional', ` + addr + `'failed', now(), now())`,
	} {
		_, err := pool.Exec(bg, sql)
		wantUntaggedRefused(t, name, err)
	}

	if _, err := pool.Exec(bg, head+`next_attempt_at, created_at) VALUES ('test', 'transactional', `+addr+`'queued', now(), now())`); err != nil {
		t.Fatalf("a queued row with no tag yet: %v", err)
	}
	_, err := pool.Exec(bg, `UPDATE mail_log SET status = 'failed', next_attempt_at = NULL, final_at = now(), recipient = NULL`)
	wantUntaggedRefused(t, "a queued row failed with no tag", err)
}

func TestAGoodbyeThatNeverGotATagStillExpires(t *testing.T) {
	pool := pgtest.New(t)
	q := New(pool, nil, nil)
	id := enqueue(t, pool, q, Enqueue{Kind: "deleted", To: "gone@example.com", Params: map[string]any{"deleted_at": "x"}})
	if _, err := pool.Exec(bg, `UPDATE mail_log SET created_at = now() - interval '25 hours' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Sweep(bg); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	st, _, rcp, _ := row(t, pool, id)
	if st != "failed" || rcp != nil {
		t.Fatalf("expired goodbye: %s keeps %v", st, rcp)
	}
	var tagless bool
	if err := pool.QueryRow(bg, `SELECT recipient_tag IS NULL FROM mail_log WHERE id = $1`, id).Scan(&tagless); err != nil || !tagless {
		t.Fatalf("tagless = %v, %v", tagless, err)
	}
}
