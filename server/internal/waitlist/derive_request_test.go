package waitlist

import (
	"bytes"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

type bankRequest struct {
	id        int64
	slug      *string
	key, text *string
	created   time.Time
	notified  *time.Time
}

func requestsOf(t *testing.T, pool *pgxpool.Pool, entry uuid.UUID) []bankRequest {
	t.Helper()
	rows, err := pool.Query(submitCtx, `SELECT id, bank_slug, other_key, other_text, created_at, notified_at
		FROM bank_requests WHERE waitlist_entry_id = $1 ORDER BY id`, entry)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []bankRequest
	for rows.Next() {
		var r bankRequest
		if err := rows.Scan(&r.id, &r.slug, &r.key, &r.text, &r.created, &r.notified); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func confirmedEntry(t *testing.T, pool *pgxpool.Pool, tag []byte, email string, bank, otherText, otherKey any) uuid.UUID {
	t.Helper()
	var entry uuid.UUID
	if err := pool.QueryRow(submitCtx, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, other_bank,
		other_bank_key, source, created_at, updated_at, confirmed_at)
		VALUES ($1, $2, 'confirmed', $3, $4, $5, 'web', now(), now(), now()) RETURNING id`,
		tag, email, bank, otherText, otherKey).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	mustExec(t, pool, `SELECT waitlist_derive_request($1)`, entry)
	return entry
}

func onlyRequest(t *testing.T, pool *pgxpool.Pool, entry uuid.UUID) bankRequest {
	t.Helper()
	rs := requestsOf(t, pool, entry)
	if len(rs) != 1 {
		t.Fatalf("%d requests, want 1: %+v", len(rs), rs)
	}
	return rs[0]
}

func TestResubmittingTheSameBankKeepsTheNotifiedRequest(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{21}, 32)
	const email = "same@example.test"
	entry := confirmedEntry(t, pool, tag, email, "fab", nil, nil)
	first := onlyRequest(t, pool, entry)
	told := first.created.Add(time.Hour).Truncate(time.Second)
	mustExec(t, pool, `UPDATE bank_requests SET notified_at = $2 WHERE id = $1`, first.id, told)

	submit(t, pool, tag, email, "fab", nil, nil)

	got := onlyRequest(t, pool, entry)
	if got.id != first.id || !got.created.Equal(first.created) {
		t.Fatalf("the request was replaced: %+v, was %+v", got, first)
	}
	if got.notified == nil || !got.notified.Equal(told) {
		t.Fatalf("notified_at = %v, want %v", got.notified, told)
	}

	mustExec(t, pool, `UPDATE banks SET status = 'supported' WHERE slug = 'fab'`)
	submit(t, pool, tag, email, "fab", nil, nil)
	if got := onlyRequest(t, pool, entry); got.id != first.id || got.notified == nil {
		t.Fatalf("a notified request of a supported bank went: %+v", got)
	}
}

func TestAChangedChoiceReplacesTheRequest(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{22}, 32)
	const email = "change@example.test"
	entry := confirmedEntry(t, pool, tag, email, "fab", nil, nil)
	first := onlyRequest(t, pool, entry)
	mustExec(t, pool, `UPDATE bank_requests SET notified_at = now() WHERE id = $1`, first.id)

	submit(t, pool, tag, email, "mashreq", nil, nil)
	got := onlyRequest(t, pool, entry)
	if got.slug == nil || *got.slug != "mashreq" || got.notified != nil {
		t.Fatalf("after changing bank: %+v", got)
	}

	submit(t, pool, tag, email, nil, "Bank Of Nowhere", "bank of nowhere")
	other := onlyRequest(t, pool, entry)
	if other.slug != nil || other.key == nil || *other.key != "bank of nowhere" || *other.text != "Bank Of Nowhere" {
		t.Fatalf("after naming another bank: %+v", other)
	}

	submit(t, pool, tag, email, nil, "BANK OF NOWHERE", "bank of nowhere")
	respelled := onlyRequest(t, pool, entry)
	if respelled.id != other.id || *respelled.text != "BANK OF NOWHERE" {
		t.Fatalf("after respelling the same bank: %+v, was %+v", respelled, other)
	}

	submit(t, pool, tag, email, "enbd", nil, nil)
	if rs := requestsOf(t, pool, entry); len(rs) != 0 {
		t.Fatalf("a supported bank left requests: %+v", rs)
	}
}

func TestAnUnnotifiedRequestGoesWhenItsBankIsSupported(t *testing.T) {
	pool := pgtest.New(t)
	tag := bytes.Repeat([]byte{23}, 32)
	const email = "waiting@example.test"
	entry := confirmedEntry(t, pool, tag, email, "fab", nil, nil)
	onlyRequest(t, pool, entry)
	mustExec(t, pool, `UPDATE banks SET status = 'supported' WHERE slug = 'fab'`)
	submit(t, pool, tag, email, "fab", nil, nil)
	if rs := requestsOf(t, pool, entry); len(rs) != 0 {
		t.Fatalf("requests left: %+v", rs)
	}
}
