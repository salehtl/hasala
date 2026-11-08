package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMailboxRekeyLeavesTheMismatchedState(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.New(t)
	previous, err := gmailpush.NewRouteKey(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	current, err := gmailpush.NewRouteKey(bytes.Repeat([]byte{8}, 32))
	if err != nil {
		t.Fatal(err)
	}
	link := func(writer, address string, key gmailpush.RouteKey) {
		t.Helper()
		user := oplogtest.NewUser(t, pool)
		oplogtest.NewWriter(t, pool, user, writer)
		if _, err := pool.Exec(ctx, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		    created_at, updated_at) VALUES ($1, 'gmail', $2, $3, $4, now(), now())`,
			user, key.AddressHMAC(address), key.KeyID(), writer); err != nil {
			t.Fatal(err)
		}
	}
	link("ios-11111111-1111-4111-8111-111111111111", "a@example.com", previous)
	link("ios-22222222-2222-4222-8222-222222222222", "b@example.com", previous)
	link("ios-33333333-3333-4333-8333-333333333333", "c@example.com", current)
	links := func() int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM mailbox_links`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	keyID := hex.EncodeToString(current.KeyID())

	refused := gmailpush.CheckKeyID(ctx, pool, current)
	if refused == nil || !strings.Contains(refused.Error(), "hasalad mailbox rekey --drop-links --keep-key-id "+keyID) {
		t.Fatalf("the startup refusal does not name the way out: %v", refused)
	}

	env := []string{"HASALA_PG_DSN=" + pool.Config().ConnString(), "USER=operator"}
	for _, argv := range [][]string{
		{"mailbox", "rekey", "--keep-key-id", keyID},
		{"mailbox", "rekey", "--drop-links"},
		{"mailbox", "rekey", "--drop-links", "--keep-key-id", "nope"},
		{"mailbox", "rekey", "--drop-links", "--keep-key-id", strings.ToUpper(keyID)},
	} {
		if code, _, msg := hasalad(t, env, argv...); code != 2 {
			t.Fatalf("hasalad %v exited %d (%s), want 2", argv, code, msg)
		}
	}
	if links() != 3 {
		t.Fatal("a refused rekey dropped a link")
	}

	code, out, msg := hasalad(t, env, "mailbox", "rekey", "--drop-links", "--keep-key-id", keyID)
	if code != 0 || !strings.Contains(out, "dropped 2") {
		t.Fatalf("mailbox rekey exited %d with %q (%s)", code, out, msg)
	}
	if links() != 1 {
		t.Fatalf("%d links left, want the one under the current key", links())
	}
	if err := gmailpush.CheckKeyID(ctx, pool, current); err != nil {
		t.Fatalf("the startup check still refuses: %v", err)
	}
	var audited int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM admin_audit
	    WHERE action = 'cli.mailbox_rekey' AND target_kind = 'system' AND target_id = $1
	      AND actor = 'cli:operator' AND params = '{"dropped": 2}'`, keyID).Scan(&audited); err != nil || audited != 1 {
		t.Fatalf("%d audit rows (%v), want 1", audited, err)
	}

	if code, out, msg := hasalad(t, env, "mailbox", "rekey", "--drop-links", "--keep-key-id", keyID); code != 0 ||
		!strings.Contains(out, "dropped 0") {
		t.Fatalf("a second rekey exited %d with %q (%s)", code, out, msg)
	}
	if links() != 1 {
		t.Fatal("a second rekey dropped a link under the current key")
	}
}
