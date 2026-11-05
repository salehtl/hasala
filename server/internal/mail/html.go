package mail

// html.go is the HTML half of every transactional email: the one shared
// layout (templates/layout.html.tmpl, Paper's P2 row 14.7) that spec 07's
// templated kinds in internal/mailq and spec 02 §14.6's account emails here
// both render into. Styling is the layout's one <style> block. The only
// image is the Hasala mark, a static PNG on hasala.app (LogoURL): nothing in
// its address names the recipient, so a client that fetches it learns
// nothing about who opened what. A client that blocks images still shows the
// "Hasala" wordmark next to it.

import (
	"bytes"
	"embed"
	htmltemplate "html/template"
	"sync"
)

// LogoURL is the Hasala mark the layout shows: a 120 x 72 PNG (40 x 24 at
// 3x) that the website serves from web/public/brand/. Gmail and Outlook do
// not show SVG in email, so it is a PNG.
const LogoURL = "https://hasala.app/brand/hasala-mark-email.png"

//go:embed templates/*.html.tmpl
var htmlFS embed.FS

var (
	layoutOnce sync.Once
	layoutT    *htmltemplate.Template
	accountT   *htmltemplate.Template
	layoutErr  error
)

func loadLayout() {
	layoutT, layoutErr = htmltemplate.ParseFS(htmlFS, "templates/layout.html.tmpl")
	if layoutErr != nil {
		return
	}
	var c *htmltemplate.Template
	if c, layoutErr = layoutT.Clone(); layoutErr != nil {
		return
	}
	accountT, layoutErr = c.ParseFS(htmlFS, "templates/account.html.tmpl")
}

// Layout returns a fresh copy of the shared layout. The caller parses its own
// "content" template into it and executes "layout" with data that has the
// fields Title, Preview, Greeting and Why.
func Layout() (*htmltemplate.Template, error) {
	layoutOnce.Do(loadLayout)
	if layoutErr != nil {
		return nil, layoutErr
	}
	return layoutT.Clone()
}

// Row is one line of the grey summary table.
type Row struct{ Label, Value string }

// page is an account email's HTML content. Lead comes before the code panel
// and the table, Paras after them; Freeze is the freeze link of the two
// alert kinds that carry one.
type page struct {
	Title, Preview, Greeting, Why string

	Heading string
	Lead    []string
	Code    string
	Rows    []Row
	Paras   []string
	Freeze  string
	Small   string
}

// render executes the account content in the layout.
func (p page) render() (string, error) {
	layoutOnce.Do(loadLayout)
	if layoutErr != nil {
		return "", layoutErr
	}
	var b bytes.Buffer
	if err := accountT.ExecuteTemplate(&b, "layout", p); err != nil {
		return "", err
	}
	return b.String(), nil
}
