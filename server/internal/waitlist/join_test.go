package waitlist

import (
	"bytes"
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestJoiningRevokesTheEntrysOtherInvites(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{5}, 32)
	var user, entry, open, queued, redeemed uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
		VALUES (decode(md5('j') || md5('k'), 'hex'), now(), 'join@example.test', now(), 'Join Test') RETURNING id`).
		Scan(&user); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at, invited_at) VALUES ($1, 'join@example.test', 'invited', 'web', now(), now(), now(), now()) RETURNING id`,
		tag).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO invite_codes (code_hash, email_tag, waitlist_entry_id, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES (decode(repeat('aa', 32), 'hex'), $1, $2, 'admin', 'active', now(), now(),
		now() + interval '1 day', 1) RETURNING id`, tag, entry).Scan(&open); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO invite_codes (email_tag, waitlist_entry_id, origin, state, created_at)
		VALUES ($1, $2, 'admin', 'queued', now()) RETURNING id`, tag, entry).Scan(&queued); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO invite_codes (code_hash, origin, state, created_at, minted_at, expires_at,
		mint_count, redeemed_at, redeemed_by, closed_at) VALUES (decode(repeat('bb', 32), 'hex'), 'cli', 'redeemed', now(),
		now(), now() + interval '1 day', 1, now(), $1, now()) RETURNING id`, user).Scan(&redeemed); err != nil {
		t.Fatal(err)
	}
	if err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		return OnInviteRedeemedTx(ctx, tx, redeemed, user, tag)
	}); err != nil {
		t.Fatal(err)
	}
	var state string
	if err := pool.QueryRow(ctx, `SELECT state FROM waitlist_entries WHERE id = $1`, entry).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if state != "joined" {
		t.Fatalf("entry %s, want joined", state)
	}
	for id, want := range map[uuid.UUID]string{open: "revoked", queued: "revoked", redeemed: "redeemed"} {
		var got string
		if err := pool.QueryRow(ctx, `SELECT state FROM invite_codes WHERE id = $1`, id).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("invite %s is %s, want %s", id, got, want)
		}
	}
}
