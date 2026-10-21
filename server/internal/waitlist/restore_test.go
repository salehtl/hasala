package waitlist

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func plantEntry(t *testing.T, pool *pgxpool.Pool, seed byte, addr string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(context.Background(), `INSERT INTO waitlist_entries (email_tag, email_norm, state, source,
		created_at, updated_at, confirmed_at) VALUES ($1, $2, 'confirmed', 'web', now(), now(), now()) RETURNING id`,
		bytes.Repeat([]byte{seed}, 32), addr).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func entryCount(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM waitlist_entries WHERE id = $1`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestALeaveIsRecordedAndSurvivesARestore(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	s := New(pool, nil, "https://hasala.app")
	var recorded []purgeledger.Entry
	s.Record = func(e purgeledger.Entry) { recorded = append(recorded, e) }
	leaving := plantEntry(t, pool, 7, "leave@example.test")
	staying := plantEntry(t, pool, 8, "stay@example.test")
	var tok string
	if err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		var err error
		tok, err = MintToken(ctx, tx, leaving, "leave")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Leave(ctx, tok); err != nil {
		t.Fatal(err)
	}
	if entryCount(t, pool, leaving) != 0 {
		t.Fatal("the leave kept the entry")
	}
	if len(recorded) != 1 || recorded[0].ID != leaving || recorded[0].Kind != purgeledger.KindWaitlistLeave ||
		time.Since(recorded[0].At) > time.Minute {
		t.Fatalf("recorded %+v, want the entry's id", recorded)
	}
	if err := s.Leave(ctx, tok); err != nil || len(recorded) != 1 {
		t.Fatalf("a used link recorded again: %v %d", err, len(recorded))
	}

	if _, err := pool.Exec(ctx, `INSERT INTO waitlist_entries (id, email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at) VALUES ($1, $2, 'leave@example.test', 'confirmed', 'web', now(), now(), now())`,
		leaving, bytes.Repeat([]byte{7}, 32)); err != nil {
		t.Fatal(err)
	}
	var invite uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO invite_codes (email_tag, waitlist_entry_id, origin, state, created_at)
		VALUES ($1, $2, 'admin', 'queued', now()) RETURNING id`, bytes.Repeat([]byte{7}, 32), leaving).Scan(&invite); err != nil {
		t.Fatal(err)
	}
	n, err := ReapplyLeaves(ctx, pool, append(recorded, purgeledger.Entry{ID: staying, At: time.Now(), Kind: purgeledger.KindPassword}))
	if err != nil || n != 1 {
		t.Fatalf("reapply %d %v, want 1", n, err)
	}
	if entryCount(t, pool, leaving) != 0 {
		t.Fatal("the restored entry came back")
	}
	if entryCount(t, pool, staying) != 1 {
		t.Fatal("another entry went")
	}
	var state string
	if err := pool.QueryRow(ctx, `SELECT state FROM invite_codes WHERE id = $1`, invite).Scan(&state); err != nil || state != "revoked" {
		t.Fatalf("the restored invite is %q (%v), want revoked", state, err)
	}
	if n, err := ReapplyLeaves(ctx, pool, recorded); err != nil || n != 0 {
		t.Fatalf("a second replay %d %v", n, err)
	}
}
