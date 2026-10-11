package mailq

// templates.go renders spec 07 §6.4's templates (and spec 02's `test`): a
// plain-text part whose first line is the subject, and for 07's kinds an HTML
// part in one shared layout. No template carries a script, an inline style, a
// remote image, an http:// link or a query string (spec 07 F7-6, enforced by
// TestTemplatesAreContentFree).

import (
	"bytes"
	"context"
	"embed"
	"fmt"
	htmltemplate "html/template"
	"strings"
	"sync"
	texttemplate "text/template"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
)

//go:embed templates/*.tmpl
var templateFS embed.FS

// Content is every value a template may substitute. Nothing here is a secret
// except the one the email exists to carry (a link with its token, a code).
type Content struct {
	Greeting     string // "Hi," or "Hi Maya,"
	Email        string // the recipient's own address
	BankName     string // a catalog name or "Another bank", never typed text
	ConfirmURL   string
	LeaveURL     string
	Code         string // display form, groups of four
	InviteURL    string
	FallbackText string
	Until        string
	ConfirmedOn  string
	InvitedOn    string
	Why          string // the footer's "You're getting this because …"

	Invited          bool
	ManualTestFlight bool
	AccountAudience  bool
}

// Rendered is one email's subject and parts.
type Rendered struct {
	Subject, Text, HTML string
}

var (
	tmplOnce sync.Once
	textT    *texttemplate.Template
	htmlT    map[string]*htmltemplate.Template
	tmplErr  error
)

func loadTemplates() {
	textT, tmplErr = texttemplate.ParseFS(templateFS, "templates/*.txt.tmpl")
	if tmplErr != nil {
		return
	}
	htmlT = map[string]*htmltemplate.Template{}
	entries, err := templateFS.ReadDir("templates")
	if err != nil {
		tmplErr = err
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".html.tmpl") || name == "layout.html.tmpl" {
			continue
		}
		t, err := htmltemplate.ParseFS(templateFS, "templates/layout.html.tmpl", "templates/"+name)
		if err != nil {
			tmplErr = err
			return
		}
		htmlT[strings.TrimSuffix(name, ".html.tmpl")] = t
	}
}

// RenderTemplate renders kind's template with c. The HTML part exists only for
// kinds that define one.
func RenderTemplate(kind string, c Content) (Rendered, error) {
	tmplOnce.Do(loadTemplates)
	if tmplErr != nil {
		return Rendered{}, tmplErr
	}
	if c.Greeting == "" {
		c.Greeting = "Hi,"
	}
	var tb bytes.Buffer
	if err := textT.ExecuteTemplate(&tb, kind+".txt.tmpl", c); err != nil {
		return Rendered{}, err
	}
	subject, body, _ := strings.Cut(tb.String(), "\n")
	r := Rendered{Subject: strings.TrimSpace(subject), Text: strings.TrimLeft(body, "\n")}
	if ht, ok := htmlT[kind]; ok {
		var hb bytes.Buffer
		data := struct {
			Content
			Title, Preview string
		}{c, r.Subject, ""}
		if err := ht.ExecuteTemplate(&hb, "layout", data); err != nil {
			return Rendered{}, err
		}
		r.HTML = hb.String()
	}
	return r, nil
}

// uae is the fixed UTC+4 clock every date in an email is written in.
var uae = time.FixedZone("UAE", 4*60*60)

// Date writes "Sunday 25 October" in UTC+4.
func Date(t time.Time) string { return t.In(uae).Format("Monday 2 January") }

// Greeting is "Hi {first}," for a display name, else "Hi,". The first name is
// the stored name up to its first space.
func Greeting(displayName string) string {
	first, _, _ := strings.Cut(strings.TrimSpace(displayName), " ")
	if first == "" {
		return "Hi,"
	}
	return "Hi " + first + ","
}

// EnqueueTest queues the operator's test email (`hasalad email test`).
func EnqueueTest(ctx context.Context, tx pgx.Tx, q *Queue, address string) (int64, error) {
	to, err := keyproto.EmailNorm(address)
	if err != nil {
		return 0, fmt.Errorf("mailq: %q is not an email address", address)
	}
	return q.EnqueueTx(ctx, tx, Enqueue{Kind: "test", Lane: LaneTransactional, To: to})
}

// TestRenderer renders the `test` kind: plain text, no secret.
var TestRenderer = RenderFunc(func(_ context.Context, _ pgx.Tx, row Row) (mail.Message, error) {
	r, err := RenderTemplate("test", Content{})
	if err != nil {
		return mail.Message{}, err
	}
	return mail.Message{To: row.Recipient, Subject: r.Subject, Text: r.Text}, nil
})
