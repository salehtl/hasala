package console

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestBankRequestsQueue(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	var user, entry string
	if err := pool.QueryRow(bg, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
		VALUES (decode(md5('a') || md5('b'), 'hex'), now(), 'maya@example.test', now(), 'Maya Test') RETURNING id`).
		Scan(&user); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, source, created_at,
		updated_at, confirmed_at) VALUES (decode(repeat('ab', 32), 'hex'), 'guest@example.test', 'confirmed', 'fab', 'web',
		now(), now(), now()) RETURNING id`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO bank_requests (bank_slug, source, user_id, sender_domain, created_at) VALUES ('fab', 'app', '` + user + `', 'alerts.example.ae', now())`,
		`INSERT INTO bank_requests (other_key, other_text, source, user_id, created_at) VALUES ('some bank', 'Some Bank', 'app', '` + user + `', now())`,
		`INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at) VALUES ('fab', 'web_waitlist', '` + entry + `', now())`,
		`INSERT INTO bank_requests (bank_slug, source, created_at) VALUES ('fab', 'web', now())`,
	} {
		if _, err := pool.Exec(bg, q); err != nil {
			t.Fatal(err)
		}
	}

	page := req(c, "GET", "/banks", nil, nil)
	body := page.Body.String()
	if page.Code != http.StatusOK || strings.Contains(body, "<script") || strings.Contains(body, "style=") {
		t.Fatalf("banks: %d %s", page.Code, body)
	}
	for _, want := range []string{"First Abu Dhabi Bank", "alerts.example.ae (1)", "Some Bank", "Collecting samples", "Template in progress"} {
		if !strings.Contains(body, want) {
			t.Errorf("the page lacks %q", want)
		}
	}

	status := func(slug string, form url.Values) int {
		form.Set("csrf", c.csrf("owner@github", "/banks/"+slug+"/status", slug, c.now()))
		return req(c, "POST", "/banks/"+slug+"/status", form, nil).Code
	}
	queued := func() (account, waitlist int) {
		_ = pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE params ->> 'audience' = 'account' AND user_id IS NOT NULL),
			count(*) FILTER (WHERE params ->> 'audience' = 'waitlist' AND waitlist_entry_id IS NOT NULL)
			FROM mail_log WHERE kind = 'bank_supported' AND bank_slug = 'fab'`).Scan(&account, &waitlist)
		return
	}

	if code := status("fab", url.Values{"status": {"planned"}, "note": {"two samples so far"}}); code != http.StatusSeeOther {
		t.Fatalf("planned: %d", code)
	}
	var st, note string
	_ = pool.QueryRow(bg, `SELECT status, note FROM banks WHERE slug = 'fab'`).Scan(&st, &note)
	if st != "planned" || note != "two samples so far" {
		t.Fatalf("after planned: %s %q", st, note)
	}
	if a, w := queued(); a+w != 0 {
		t.Fatalf("mail before supported: %d %d", a, w)
	}
	if code := status("fab", url.Values{"status": {"bogus"}}); code != http.StatusConflict {
		t.Fatalf("bogus status: %d", code)
	}
	if code := status("nope", url.Values{"status": {"planned"}}); code != http.StatusConflict {
		t.Fatalf("unknown bank: %d", code)
	}

	if code := status("fab", url.Values{"status": {"supported"}}); code != http.StatusSeeOther {
		t.Fatalf("supported: %d", code)
	}
	if a, w := queued(); a != 1 || w != 1 {
		t.Fatalf("after supported: account %d waitlist %d", a, w)
	}
	var told int
	_ = pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE bank_slug = 'fab' AND notified_at IS NOT NULL`).Scan(&told)
	if told != 2 {
		t.Fatalf("%d requests told, want 2 (the anonymous one has nobody to tell)", told)
	}
	if code := status("fab", url.Values{"status": {"supported"}, "notify": {"on"}}); code != http.StatusSeeOther {
		t.Fatalf("supported again: %d", code)
	}
	if a, w := queued(); a != 1 || w != 1 {
		t.Fatalf("told twice: account %d waitlist %d", a, w)
	}

	add := func(form url.Values) int {
		form.Set("csrf", c.csrf("owner@github", "/banks/add", "", c.now()))
		return req(c, "POST", "/banks/add", form, nil).Code
	}
	if code := add(url.Values{"slug": {"Bad Slug"}, "name": {"Some Bank"}, "key": {"some bank"}}); code != http.StatusConflict {
		t.Fatalf("bad slug: %d", code)
	}
	if code := add(url.Values{"slug": {"fab"}, "name": {"Again"}}); code != http.StatusConflict {
		t.Fatalf("existing slug: %d", code)
	}
	if code := add(url.Values{"slug": {"some-bank"}, "name": {"Some Bank"}, "key": {"some bank"}}); code != http.StatusSeeOther {
		t.Fatalf("add: %d", code)
	}
	var moved, left int
	_ = pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE bank_slug = 'some-bank'), count(*) FILTER (WHERE other_key IS NOT NULL)
		FROM bank_requests`).Scan(&moved, &left)
	if moved != 1 || left != 0 {
		t.Fatalf("after add: moved %d left %d", moved, left)
	}
	var audits int
	_ = pool.QueryRow(bg, `SELECT count(*) FROM admin_audit WHERE action IN ('console.bank.status', 'console.bank.add')`).Scan(&audits)
	if audits != 8 {
		t.Fatalf("%d audit rows, want 8", audits)
	}
}
