package invites

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func TestARevokedInviteStaysRevokedAfterARestore(t *testing.T) {
	pool := pgtest.New(t)
	path := filepath.Join(t.TempDir(), "purged")
	record := func(e purgeledger.Entry) {
		if err := purgeledger.AppendEntries(path, e); err != nil {
			t.Errorf("record: %v", err)
		}
	}
	now := time.Now()
	id, code, err := MintPrinted(bg, pool, "", DefaultTTL, false, now)
	if err != nil {
		t.Fatal(err)
	}
	var entry uuid.UUID
	tag := bytes.Repeat([]byte{5}, 32)
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at, invited_at) VALUES ($1, 'r@example.test', 'invited', 'web', now(), now(), now(), now()) RETURNING id`,
		tag).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	var addressed uuid.UUID
	if err := pool.QueryRow(bg, `INSERT INTO invite_codes (code_hash, email_tag, waitlist_entry_id, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES ($1, $2, $3, 'admin', 'active', now(), now(), now() + interval '1 day', 1)
		RETURNING id`, CodeHash("RESTOREDADDRESSEDCODE"), tag, entry).Scan(&addressed); err != nil {
		t.Fatal(err)
	}
	for _, inv := range []uuid.UUID{id, addressed} {
		if err := pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
			_, err := Revoke(bg, tx, inv.String(), now)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		RecordRevoked(record, inv, now)
	}
	entries, err := purgeledger.Read(path)
	if err != nil || len(entries) != 2 || entries[0].Kind != purgeledger.KindInviteRevoked || entries[0].ID != id ||
		entries[1].ID != addressed {
		t.Fatalf("ledger %+v %v, want two invite revocations", entries, err)
	}
	if n, err := ReapplyRevocations(bg, pool, entries); err != nil || n != 0 {
		t.Fatalf("a replay on the live database %d %v, want nothing", n, err)
	}

	if _, err := pool.Exec(bg, `UPDATE invite_codes SET state = 'active', closed_at = NULL WHERE id = ANY($1::uuid[])`,
		[]uuid.UUID{id, addressed}); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `UPDATE waitlist_entries SET state = 'invited', invited_at = now() WHERE id = $1`, entry); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(bg, pool, code, nil, nil, time.Now()); err != nil {
		t.Fatalf("the simulated restore did not bring the invite back: %v", err)
	}
	n, err := ReapplyRevocations(bg, pool, entries)
	if err != nil || n != 2 {
		t.Fatalf("reapply %d %v, want two revocations", n, err)
	}
	if _, err := Resolve(bg, pool, code, nil, nil, time.Now()); !errors.Is(err, ErrNotInvited) {
		t.Fatalf("a revoked invite resolves after the replay: %v", err)
	}
	var revoked int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM invite_codes WHERE id = ANY($1::uuid[]) AND state = 'revoked'
		AND closed_at IS NOT NULL`, []uuid.UUID{id, addressed}).Scan(&revoked); err != nil || revoked != 2 {
		t.Fatalf("%d revoked invites (%v), want 2", revoked, err)
	}
	var state string
	if err := pool.QueryRow(bg, `SELECT state FROM waitlist_entries WHERE id = $1`, entry).Scan(&state); err != nil || state != "confirmed" {
		t.Fatalf("the revoked invite's entry is %q (%v), want confirmed", state, err)
	}
	if n, err := ReapplyRevocations(bg, pool, entries); err != nil || n != 0 {
		t.Fatalf("a second replay %d %v", n, err)
	}
}

func TestARevocationReplayLeavesAnEntryWithAnotherOpenInvite(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{6}, 32)
	var entry uuid.UUID
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at, invited_at) VALUES ($1, 'o@example.test', 'invited', 'web', now(), now(), now(), now()) RETURNING id`,
		tag).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	var first uuid.UUID
	if err := pool.QueryRow(bg, `INSERT INTO invite_codes (code_hash, email_tag, waitlist_entry_id, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES ($1, $2, $3, 'admin', 'active', now(), now(), now() + interval '1 day', 1)
		RETURNING id`, CodeHash("FIRSTOPENINVITECODE"), tag, entry).Scan(&first); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `INSERT INTO invite_codes (email_tag, waitlist_entry_id, origin, state, created_at)
		VALUES ($1, $2, 'admin', 'queued', now())`, tag, entry); err != nil {
		t.Fatal(err)
	}
	e := purgeledger.Entry{ID: first, At: time.Now().Truncate(time.Second), Kind: purgeledger.KindInviteRevoked}
	if n, err := ReapplyRevocations(bg, pool, []purgeledger.Entry{e}); err != nil || n != 1 {
		t.Fatalf("reapply %d %v, want one revocation", n, err)
	}
	var state string
	if err := pool.QueryRow(bg, `SELECT state FROM waitlist_entries WHERE id = $1`, entry).Scan(&state); err != nil || state != "invited" {
		t.Fatalf("the entry is %q (%v), want invited: it still has an open invite", state, err)
	}
}
