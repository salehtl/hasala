package console

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/banks"
)

type bankRow struct {
	Slug, Name, Status, Label, Note, Changed, Last string
	App, Waitlist, Web, Notified                   int
	Domains                                        []domainCount
	StatusTok                                      string
}

type domainCount struct {
	Domain string
	N      int
}

type otherRow struct {
	Key, Text, Last    string
	App, Waitlist, Web int
}

type statusOption struct {
	Value, Label string
}

func (c *Console) banksPage(ctx context.Context, tx pgx.Tx, login string, v *view) (string, error) {
	rows, err := tx.Query(ctx,
		`SELECT b.slug, b.name, b.status, b.note, b.status_changed_at,
		        count(r.id) FILTER (WHERE r.source = 'app'),
		        count(r.id) FILTER (WHERE r.source = 'web_waitlist'),
		        count(r.id) FILTER (WHERE r.source = 'web'),
		        count(r.id) FILTER (WHERE r.notified_at IS NOT NULL),
		        max(r.created_at)
		   FROM banks b LEFT JOIN bank_requests r ON r.bank_slug = b.slug
		  GROUP BY b.slug
		  ORDER BY CASE b.status WHEN 'supported' THEN 2 WHEN 'wont_do' THEN 3 ELSE 0 END,
		           count(r.id) DESC, b.name`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	now := c.now()
	idx := map[string]int{}
	for rows.Next() {
		var (
			b       bankRow
			changed time.Time
			last    *time.Time
		)
		if err := rows.Scan(&b.Slug, &b.Name, &b.Status, &b.Note, &changed, &b.App, &b.Waitlist, &b.Web,
			&b.Notified, &last); err != nil {
			return "", err
		}
		b.Label, b.Changed, b.Last = banks.Label(b.Status), fmtTime(&changed), fmtTime(last)
		b.StatusTok = c.csrf(login, "/banks/"+b.Slug+"/status", b.Slug, now)
		idx[b.Slug] = len(v.Banks)
		v.Banks = append(v.Banks, b)
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	rows.Close()
	drows, err := tx.Query(ctx,
		`SELECT bank_slug, sender_domain, count(*) FROM bank_requests
		  WHERE bank_slug IS NOT NULL AND sender_domain IS NOT NULL
		  GROUP BY bank_slug, sender_domain ORDER BY bank_slug, count(*) DESC, sender_domain`)
	if err != nil {
		return "", err
	}
	defer drows.Close()
	for drows.Next() {
		var slug string
		var d domainCount
		if err := drows.Scan(&slug, &d.Domain, &d.N); err != nil {
			return "", err
		}
		if i, ok := idx[slug]; ok {
			v.Banks[i].Domains = append(v.Banks[i].Domains, d)
		}
	}
	if err := drows.Err(); err != nil {
		return "", err
	}
	drows.Close()
	orows, err := tx.Query(ctx,
		`SELECT other_key, min(other_text),
		        count(*) FILTER (WHERE source = 'app'),
		        count(*) FILTER (WHERE source = 'web_waitlist'),
		        count(*) FILTER (WHERE source = 'web'),
		        max(created_at)
		   FROM bank_requests WHERE other_key IS NOT NULL
		  GROUP BY other_key ORDER BY count(*) DESC, other_key LIMIT 200`)
	if err != nil {
		return "", err
	}
	defer orows.Close()
	for orows.Next() {
		var o otherRow
		var last time.Time
		if err := orows.Scan(&o.Key, &o.Text, &o.App, &o.Waitlist, &o.Web, &last); err != nil {
			return "", err
		}
		o.Last = fmtTime(&last)
		v.Others = append(v.Others, o)
	}
	for _, s := range banks.Statuses {
		v.Statuses = append(v.Statuses, statusOption{Value: s, Label: banks.Label(s)})
	}
	v.AddTok = c.csrf(login, "/banks/add", "", now)
	return "banks.html", orows.Err()
}

func (c *Console) bankStatus(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	slug := r.PathValue("id")
	if _, err := banks.Slug(slug); err != nil {
		return slug, "/banks", "", errRefused
	}
	status := r.PostForm.Get("status")
	old, err := banks.SetStatus(ctx, tx, slug, status, r.PostForm.Get("note"), c.now())
	if errors.Is(err, banks.ErrBadStatus) || errors.Is(err, banks.ErrNoSuchBank) {
		return slug, "/banks", "", errRefused
	}
	if err != nil {
		return slug, "/banks", "", err
	}
	if status == "supported" && (old != "supported" || r.PostForm.Get("notify") == "on") {
		if _, err := banks.NotifySupported(ctx, tx, c.queue, slug, c.now()); err != nil {
			return slug, "/banks", "", err
		}
	}
	return slug, "/banks", "", nil
}

func (c *Console) bankAdd(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, string, error) {
	slug := strings.TrimSpace(r.PostForm.Get("slug"))
	err := banks.AddFromKey(ctx, tx, slug, r.PostForm.Get("name"), r.PostForm.Get("key"))
	if errors.Is(err, banks.ErrBadSlug) || errors.Is(err, banks.ErrBadBank) {
		return slug, "/banks", "", errRefused
	}
	return slug, "/banks", "", err
}
