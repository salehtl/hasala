package console

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/banks"
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

func TestBankToldLeavesOutAFailedEmail(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	var user string
	if err := pool.QueryRow(bg, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
		VALUES (decode(md5('a') || md5('b'), 'hex'), now(), 'maya@example.test', now(), 'Maya Test') RETURNING id`).
		Scan(&user); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `INSERT INTO bank_requests (bank_slug, source, user_id, created_at) VALUES ('fab', 'app', $1, now())`, user); err != nil {
		t.Fatal(err)
	}
	status := func(form url.Values) {
		t.Helper()
		form.Set("csrf", c.csrf("owner@github", "/banks/fab/status", "fab", c.now()))
		if code := req(c, "POST", "/banks/fab/status", form, nil).Code; code != http.StatusSeeOther {
			t.Fatalf("status: %d", code)
		}
	}
	told := func() bool {
		t.Helper()
		body := req(c, "GET", "/banks", nil, nil).Body.String()
		yes, no := strings.Contains(body, "<td>1</td><td>0</td><td>0</td><td>1</td>"), strings.Contains(body, "<td>1</td><td>0</td><td>0</td><td>0</td>")
		if yes == no {
			t.Fatalf("the row for fab is not on the page as expected:\n%s", body)
		}
		return yes
	}
	if told() {
		t.Fatal("told before any email")
	}
	status(url.Values{"status": {"supported"}})
	if !told() {
		t.Fatal("a queued email is not counted as told")
	}
	if _, err := pool.Exec(bg, `UPDATE mail_log SET status = 'failed', final_at = now(), next_attempt_at = NULL,
		recipient_tag = decode(repeat('cd', 32), 'hex') WHERE kind = 'bank_supported'`); err != nil {
		t.Fatal(err)
	}
	if told() {
		t.Fatal("a failed email is counted as told")
	}
	status(url.Values{"status": {"supported"}, "notify": {"on"}})
	if !told() {
		t.Fatal("the retried email is not counted as told")
	}
	var mails int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM mail_log WHERE kind = 'bank_supported'`).Scan(&mails); err != nil || mails != 2 {
		t.Fatalf("%d emails (%v), want the failed one and the retry", mails, err)
	}
}

func TestATypedNameMovesOntoABankAlreadyListed(t *testing.T) {
	pool := pgtest.New(t)
	c := New(pool, host, "tail.example.ts.net", []string{"owner@github"}, 0)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(bg, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	account := func(handle, email string) string {
		t.Helper()
		var id string
		if err := pool.QueryRow(bg, `INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name)
			VALUES (decode(md5($1) || md5($1 || 'x'), 'hex'), now(), $2, now(), 'Maya Test') RETURNING id`, handle, email).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	typed := func(key, text string, user any) {
		t.Helper()
		source := "web"
		if user != nil {
			source = "app"
		}
		exec(`INSERT INTO bank_requests (other_key, other_text, source, user_id, created_at) VALUES ($1, $2, $3, $4, now())`,
			key, text, source, user)
	}
	add := func(slug, name, key string) int {
		t.Helper()
		form := url.Values{"slug": {slug}, "name": {name}, "key": {key}}
		form.Set("csrf", c.csrf("owner@github", "/banks/add", "", c.now()))
		return req(c, "POST", "/banks/add", form, nil).Code
	}
	counts := func() (listed, free int) {
		t.Helper()
		if err := pool.QueryRow(bg, `SELECT count(*) FILTER (WHERE bank_slug = 'fab'), count(*) FILTER (WHERE other_key IS NOT NULL)
			FROM bank_requests`).Scan(&listed, &free); err != nil {
			t.Fatal(err)
		}
		return
	}
	aliases := func() (out []string) {
		t.Helper()
		if err := pool.QueryRow(bg, `SELECT aliases FROM banks WHERE slug = 'fab'`).Scan(&out); err != nil {
			t.Fatal(err)
		}
		return
	}

	asker, both := account("asker", "asker@example.test"), account("both", "both@example.test")
	typed("first gulf", "First Gulf", asker)
	typed("first gulf", "First Gulf", both)
	typed("first gulf", "First Gulf", nil)
	exec(`INSERT INTO bank_requests (bank_slug, source, user_id, created_at) VALUES ('fab', 'app', $1, now())`, both)
	var entry string
	if err := pool.QueryRow(bg, `INSERT INTO waitlist_entries (email_tag, email_norm, state, other_bank, other_bank_key, source,
		created_at, updated_at, confirmed_at) VALUES (decode(repeat('ab', 32), 'hex'), 'guest@example.test', 'confirmed',
		'First Gulf', 'first gulf', 'web', now(), now(), now()) RETURNING id`).Scan(&entry); err != nil {
		t.Fatal(err)
	}
	exec(`INSERT INTO bank_requests (other_key, other_text, source, waitlist_entry_id, created_at)
		VALUES ('first gulf', 'First Gulf', 'web_waitlist', $1, now())`, entry)
	startAliases := len(aliases())

	if code := add("fab", "First Gulf", "first gulf"); code != http.StatusConflict {
		t.Fatalf("a slug that collides by accident: %d", code)
	}
	if listed, free := counts(); listed != 1 || free != 4 {
		t.Fatalf("a refused add moved requests: listed %d free %d", listed, free)
	}

	if code := add("fab", "First Abu Dhabi Bank", "first gulf"); code != http.StatusSeeOther {
		t.Fatalf("move onto the listed bank: %d", code)
	}
	if listed, free := counts(); listed != 4 || free != 0 {
		t.Fatalf("after the move: listed %d free %d, want 4 and 0 (the duplicate dropped)", listed, free)
	}
	var slug, name string
	var otherBank *string
	if err := pool.QueryRow(bg, `SELECT bank_slug, other_bank FROM waitlist_entries WHERE id = $1`, entry).Scan(&slug, &otherBank); err != nil ||
		slug != "fab" || otherBank != nil {
		t.Fatalf("the waitlist entry: %q %v %v", slug, otherBank, err)
	}
	if err := pool.QueryRow(bg, `SELECT name FROM banks WHERE slug = 'fab'`).Scan(&name); err != nil || name != "First Abu Dhabi Bank" {
		t.Fatalf("the catalog name changed: %q %v", name, err)
	}
	choice, err := banks.Resolve(bg, pool, "other", "First  Gulf")
	if err != nil || choice.Slug != "fab" {
		t.Fatalf("a later submission of the name: %+v %v", choice, err)
	}

	if code := add("fab", "First Abu Dhabi Bank", "first gulf"); code != http.StatusSeeOther {
		t.Fatalf("the same move again: %d", code)
	}
	if got := aliases(); len(got) != startAliases+1 {
		t.Fatalf("aliases %v, want the key once", got)
	}

	typed("fgb", "FGB", asker)
	if code := add("fab", "First Abu Dhabi", "fgb"); code != http.StatusSeeOther {
		t.Fatalf("named by one of the bank's aliases: %d", code)
	}

	exec(`UPDATE banks SET aliases = (SELECT array_agg('a' || g) FROM generate_series(1, 31) g) || aliases[1:1] WHERE slug = 'fab'`)
	newcomer := account("newcomer", "newcomer@example.test")
	typed("full bank", "Full Bank", newcomer)
	if code := add("fab", "First Abu Dhabi Bank", "full bank"); code != http.StatusConflict {
		t.Fatalf("a bank with no room for another alias: %d", code)
	}
	if _, free := counts(); free != 1 {
		t.Fatalf("a refused add moved requests: free %d", free)
	}
	exec(`UPDATE banks SET aliases = aliases[1:5] WHERE slug = 'fab'`)
	status := url.Values{"status": {"supported"}}
	status.Set("csrf", c.csrf("owner@github", "/banks/fab/status", "fab", c.now()))
	if code := req(c, "POST", "/banks/fab/status", status, nil).Code; code != http.StatusSeeOther {
		t.Fatalf("supported: %d", code)
	}
	if code := add("fab", "First Abu Dhabi Bank", "full bank"); code != http.StatusSeeOther {
		t.Fatalf("move onto a supported bank: %d", code)
	}
	var told int
	if err := pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE bank_slug = 'fab' AND notified_at IS NULL AND user_id = $1`, newcomer).Scan(&told); err != nil || told != 1 {
		t.Fatalf("%d of the newcomer's requests wait to be told (%v), want the one that moved", told, err)
	}
	notify := url.Values{"status": {"supported"}, "notify": {"on"}}
	notify.Set("csrf", c.csrf("owner@github", "/banks/fab/status", "fab", c.now()))
	if code := req(c, "POST", "/banks/fab/status", notify, nil).Code; code != http.StatusSeeOther {
		t.Fatalf("notify: %d", code)
	}
	if err := pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE bank_slug = 'fab' AND notified_at IS NULL AND user_id = $1`, newcomer).Scan(&told); err != nil || told != 0 {
		t.Fatalf("%d of the newcomer's requests still wait to be told (%v)", told, err)
	}
}
