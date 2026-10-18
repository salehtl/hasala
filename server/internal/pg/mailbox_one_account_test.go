package pg_test

import (
	"bytes"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pg"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMigrationKeepsTheNewestLinkOfASharedMailbox(t *testing.T) {
	dsn, _ := pgtest.NewEmpty(t)
	pool, err := pg.Open(bg, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := pg.MigrateTo(bg, pool, 23); err != nil {
		t.Fatal(err)
	}
	shared, own := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)
	at := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	older, newer, alone := oplogtest.NewUserWithoutKeys(t, pool), oplogtest.NewUserWithoutKeys(t, pool),
		oplogtest.NewUserWithoutKeys(t, pool)
	for i, row := range []struct {
		user uuid.UUID
		hmac []byte
	}{{older, shared}, {newer, shared}, {alone, own}} {
		writer := fmt.Sprintf("ios-%08d-0000-4000-8000-000000000000", i)
		oplogtest.NewWriter(t, pool, row.user, writer)
		created := at.Add(time.Duration(i) * time.Hour)
		if _, err := pool.Exec(bg, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id,
		    holder_writer_id, created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, $5, $5)`,
			row.user, row.hmac, bytes.Repeat([]byte{9}, 8), writer, created); err != nil {
			t.Fatal(err)
		}
	}
	if err := pg.Migrate(bg, pool); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(bg, `SELECT user_id FROM mailbox_links ORDER BY created_at`)
	if err != nil {
		t.Fatal(err)
	}
	var kept []uuid.UUID
	for rows.Next() {
		var u uuid.UUID
		if err := rows.Scan(&u); err != nil {
			t.Fatal(err)
		}
		kept = append(kept, u)
	}
	rows.Close()
	if len(kept) != 2 || kept[0] != newer || kept[1] != alone {
		t.Fatalf("kept %v, want the newer link of the shared mailbox and the unshared one", kept)
	}
}
