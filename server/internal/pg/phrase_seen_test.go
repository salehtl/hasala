package pg_test

import (
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pg"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestDownTo27IsWhat00027Left(t *testing.T) { downIsWhatUpLeft(t, 27) }

func TestAccountsMadeBeforeThePhraseFlagCountAsSeen(t *testing.T) {
	dsn, _ := pgtest.NewEmpty(t)
	pool, err := pg.Open(bg, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := pg.MigrateTo(bg, pool, 27); err != nil {
		t.Fatal(err)
	}
	before := oplogtest.NewUserWithoutKeys(t, pool)
	oplogtest.AddKeys(t, pool, before)
	var at time.Time
	if err := pool.QueryRow(bg, `SELECT created_at FROM account_keys WHERE user_id = $1`, before).Scan(&at); err != nil {
		t.Fatal(err)
	}
	if err := pg.Migrate(bg, pool); err != nil {
		t.Fatal(err)
	}
	var seen *time.Time
	if err := pool.QueryRow(bg, `SELECT phrase_seen_at FROM account_keys WHERE user_id = $1`, before).Scan(&seen); err != nil {
		t.Fatal(err)
	}
	if seen == nil || !seen.Equal(at) {
		t.Fatalf("phrase_seen_at %v, want the creation time %v", seen, at)
	}
	after := oplogtest.NewUserWithoutKeys(t, pool)
	oplogtest.AddKeys(t, pool, after)
	if err := pool.QueryRow(bg, `SELECT phrase_seen_at FROM account_keys WHERE user_id = $1`, after).Scan(&seen); err != nil {
		t.Fatal(err)
	}
	if seen != nil {
		t.Fatalf("a new row without a value is %v, want NULL (only bootstrap and signup set it)", seen)
	}
}

func TestTheRuntimeRoleMaySetThePhraseFlag(t *testing.T) {
	pool := pgtest.New(t)
	u := oplogtest.NewUserWithoutKeys(t, pool)
	oplogtest.AddKeys(t, pool, u)
	tag, err := pool.Exec(bg, `UPDATE account_keys SET phrase_seen_at = now() WHERE user_id = $1 AND phrase_seen_at IS NULL`, u)
	if err != nil || tag.RowsAffected() != 1 {
		t.Fatalf("the runtime role set the flag: %v %v", tag, err)
	}
}
