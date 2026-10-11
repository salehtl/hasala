package invites

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

func TestCodeShapes(t *testing.T) {
	c, err := NewCode()
	if err != nil || len(c) != CodeLen || strings.Trim(c, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") != "" {
		t.Fatalf("code %q %v", c, err)
	}
	d := Display(c)
	if len(d) != 29 || strings.Count(d, "-") != 5 || Normalize(d) != c || Normalize(strings.ToLower(d)) != c {
		t.Fatalf("display %q", d)
	}
	if !bytes.Equal(CodeHash(d), CodeHash(c)) || CodeHash(" - ") != nil {
		t.Fatal("CodeHash")
	}
	raw, enc, h, err := NewLinkKey()
	if err != nil || len(enc) != 43 || !LinkKeyMatches(raw, h) || LinkKeyMatches(raw[:31], h) {
		t.Fatal("link key")
	}
	if Link("https://hasala.app", d, enc) != "https://hasala.app/i/"+c+"#"+enc {
		t.Fatal("Link")
	}
	if FallbackText("https://hasala.app", c) != "hasala.app/i/"+d {
		t.Fatal("FallbackText")
	}
	for _, ttl := range []time.Duration{time.Hour, 31 * 24 * time.Hour} {
		if CheckTTL(ttl) == nil {
			t.Fatalf("ttl %s accepted", ttl)
		}
	}
}

func TestMintRedeemRevokeAndSweep(t *testing.T) {
	pool := pgtest.New(t)
	now := time.Now()
	_, code, err := MintPrinted(bg, pool, "app-review", DefaultTTL, true, now)
	if err != nil {
		t.Fatal(err)
	}
	r, err := Resolve(bg, pool, code, nil, nil, now)
	if err != nil || !r.Review || r.Proven {
		t.Fatalf("resolve a review invite: %+v %v", r, err)
	}
	u := oplogtest.NewUser(t, pool)
	err = pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		got, err := RedeemTx(bg, tx, CodeHash(code), nil, u, time.Now())
		if err == nil && !got.Review {
			t.Error("the review flag did not come back from redemption")
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	err = pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		_, err := RedeemTx(bg, tx, CodeHash(code), nil, u, time.Now())
		return err
	})
	if !errors.Is(err, ErrNotInvited) {
		t.Fatalf("a spent code redeemed twice: %v", err)
	}

	// Revoke by prefix; an expired invite's entry goes back to confirmed.
	id, code2, _ := MintPrinted(bg, pool, "", DefaultTTL, false, now)
	err = pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
		got, err := Revoke(bg, tx, ShortID(id), time.Now())
		if got != id {
			t.Errorf("revoked %s, want %s", got, id)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(bg, pool, code2, nil, nil, time.Now()); !errors.Is(err, ErrNotInvited) {
		t.Fatal("a revoked invite resolves")
	}
	var entry string
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, source, created_at, updated_at,
		confirmed_at, invited_at) VALUES ($1, 'w@example.com', 'invited', 'web', now(), now(), now(), now()) RETURNING id`,
		bytes.Repeat([]byte{3}, 32)).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `INSERT INTO invite_codes (code_hash, email_tag, waitlist_entry_id, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES ($1, $2, $3, 'admin', 'active', now() - interval '20 days',
		now() - interval '20 days', now() - interval '6 days', 1)`, CodeHash("EXPIREDCODE"), bytes.Repeat([]byte{3}, 32), entry); err != nil {
		t.Fatal(err)
	}
	if msg, err := Sweep(bg, pool); err != nil || msg == "" {
		t.Fatalf("sweep %q %v", msg, err)
	}
	var state string
	_ = pool.QueryRow(bg, `SELECT state FROM waitlist_entries WHERE id = $1`, entry).Scan(&state)
	if state != "confirmed" {
		t.Fatalf("the expired invite's entry is %s, want confirmed", state)
	}
	list, err := List(bg, pool)
	if err != nil || len(list) != 3 {
		t.Fatalf("list %d %v", len(list), err)
	}
}

// Spec 02 §14.1's binding at redemption: an unaddressed invite redeems for
// any account; an addressed one only for the account whose address has its
// tag, and never without a tag.
func TestRedeemTxBindsAnAddressedInvite(t *testing.T) {
	pool := pgtest.New(t)
	now := time.Now()
	_, printed, err := MintPrinted(bg, pool, "", DefaultTTL, false, now)
	if err != nil {
		t.Fatal(err)
	}
	_, _, lkh, _ := NewLinkKey()
	mine, theirs := bytes.Repeat([]byte{4}, 32), bytes.Repeat([]byte{5}, 32)
	const addressed = "ADDRESSEDCODEADDRESSEDCO"
	if _, err := pool.Exec(bg, `INSERT INTO invite_codes (code_hash, email_tag, link_key_hash, origin, state, created_at,
		minted_at, expires_at, mint_count) VALUES ($1, $2, $3, 'admin', 'active', now(), now(), now() + interval '1 day', 1)`,
		CodeHash(addressed), mine, lkh); err != nil {
		t.Fatal(err)
	}
	redeem := func(code string, tag []byte) error {
		u := oplogtest.NewUser(t, pool)
		return pgx.BeginFunc(bg, pool, func(tx pgx.Tx) error {
			_, err := RedeemTx(bg, tx, CodeHash(code), tag, u, now)
			return err
		})
	}
	for _, c := range []struct {
		name string
		code string
		tag  []byte
		ok   bool
	}{
		{"addressed, no tag", addressed, nil, false},
		{"addressed, another tag", addressed, theirs, false},
		{"unknown code", "UNKNOWNCODEUNKNOWNCODEUN", mine, false},
		{"no code", "", mine, false},
		{"addressed, its tag", addressed, mine, true},
		{"unaddressed, any tag", printed, theirs, true},
	} {
		if err := redeem(c.code, c.tag); (err == nil) != c.ok || (err != nil && !errors.Is(err, ErrNotInvited)) {
			t.Errorf("%s: %v", c.name, err)
		}
	}
}
