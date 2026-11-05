package mail

import (
	"flag"
	"html"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite testdata/golden/*.html")

var (
	hrefRE = regexp.MustCompile(`href="([^"]*)"`)
	imgRE  = regexp.MustCompile(`<img [^>]*>`)
)

// The logo the layout shows, exactly as the template writes it.
const logoTag = `<img src="` + LogoURL + `" width="40" height="24" alt="">`

// checkHTML is spec 07 F7-6 over a rendered account email: the shared layout
// with the logo as its only image, no script, inline style, remote stylesheet
// or http:// link, and links only to hasala.app's support and privacy pages
// and the freeze page.
func checkHTML(t *testing.T, m Message) {
	t.Helper()
	h := m.HTML
	if !strings.HasPrefix(h, "<!doctype html>") || !strings.Contains(h, `<div class="card">`) {
		t.Errorf("%q: no HTML part in the shared layout", m.Subject)
		return
	}
	if imgs := imgRE.FindAllString(h, -1); len(imgs) != 1 || imgs[0] != logoTag {
		t.Errorf("%q: images %v, want only the logo", m.Subject, imgs)
	}
	for _, bad := range []string{"<script", " style=", "http://", "url(", "@import"} {
		if strings.Contains(strings.ToLower(h), bad) {
			t.Errorf("%q: HTML contains %q", m.Subject, bad)
		}
	}
	for _, l := range hrefRE.FindAllStringSubmatch(h, -1) {
		switch u := l[1]; {
		case u == "https://hasala.app/support", u == "https://hasala.app/privacy":
		case strings.HasPrefix(u, DefaultFreezeURL+"#"):
		default:
			t.Errorf("%q: HTML links to %q", m.Subject, u)
		}
	}
	greeting, _, _ := strings.Cut(m.Text, "\n")
	if !strings.Contains(h, `<p class="greeting">`+greeting+`</p>`) {
		t.Errorf("%q: HTML does not open with %q", m.Subject, greeting)
	}
	if !strings.Contains(h, "We'll never ask you to share anything from the Hasala app") {
		t.Errorf("%q: HTML has no footer", m.Subject)
	}
}

// The layout and the account template themselves: the same rules, before
// any rendering.
func TestHTMLTemplatesAreContentFree(t *testing.T) {
	n := 0
	err := fs.WalkDir(htmlFS, "templates", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, _ := htmlFS.ReadFile(path)
		s := string(b)
		n++
		for _, bad := range []string{"<script", " style=", "http://", "url(", "@import"} {
			if strings.Contains(strings.ToLower(s), bad) {
				t.Errorf("%s contains %q", path, bad)
			}
		}
		imgs := imgRE.FindAllString(s, -1)
		if want := path == "templates/layout.html.tmpl"; (len(imgs) == 1 && imgs[0] == logoTag) != want || len(imgs) > 1 {
			t.Errorf("%s has images %v", path, imgs)
		}
		for _, m := range hrefRE.FindAllStringSubmatch(s, -1) {
			if !strings.HasPrefix(m[1], "https://hasala.app/") && !strings.HasPrefix(m[1], "{{") {
				t.Errorf("%s links to %q", path, m[1])
			}
		}
		return nil
	})
	if err != nil || n != 2 {
		t.Fatalf("walked %d templates: %v", n, err)
	}
}

// The freeze alerts put the link in the button; the goodbye carries its
// summary table. Both used to be plain text only.
func TestAccountEmailsHaveTheStyledLayout(t *testing.T) {
	at := time.Date(2026, 10, 11, 9, 40, 0, 0, time.UTC)
	link := DefaultFreezeURL + "#" + strings.Repeat("A", 43)
	m, err := Alert("maya@example.com", "new_sign_in_passkey", at, "Maya Rahman", link)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(m.HTML, `<a class="button" href="`+link+`">Freeze my account</a>`) {
		t.Errorf("the sign-in alert has no freeze button:\n%s", m.HTML)
	}
	d := Deleted("maya@example.com", at)
	for _, want := range []string{"<h1>Your account is deleted.</h1>", `<table class="summary">`,
		"Sun 11 Oct 2026, 13:40 UAE time"} {
		if !strings.Contains(d.HTML, want) {
			t.Errorf("the goodbye's HTML lacks %q", want)
		}
	}
	c, err := Code("maya@example.com", "signup", "482913", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(c.HTML, `<p class="otp"><strong>482913</strong>`) {
		t.Errorf("the code email has no code panel")
	}
}

// Golden files: what four account emails render to, byte for byte. Open
// them in a browser to see the layout. Rewrite with
// `go test ./internal/mail -run TestHTMLGolden -update`.
func TestHTMLGolden(t *testing.T) {
	at := time.Date(2026, 10, 11, 9, 40, 0, 0, time.UTC)
	code, err := Code("maya@example.com", "email_verify", "482913", "Maya Rahman")
	if err != nil {
		t.Fatal(err)
	}
	alert, err := Alert("maya@example.com", "new_sign_in_password", at, "Maya Rahman",
		DefaultFreezeURL+"#"+strings.Repeat("A", 43))
	if err != nil {
		t.Fatal(err)
	}
	change, err := Alert("maya@example.com", "password_changed", at, "Maya Rahman", "")
	if err != nil {
		t.Fatal(err)
	}
	for name, m := range map[string]Message{
		"alert-change.html": change,
		"deleted.html":      Deleted("maya@example.com", at),
		"code.html":         code,
		"alert-freeze.html": alert,
	} {
		path := filepath.Join("testdata", "golden", name)
		if *update {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(m.HTML), 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%v (run with -update to write it)", err)
		}
		if string(want) != m.HTML {
			t.Errorf("%s is stale: rerun with -update and review the diff", path)
		}
	}
}

func TestChangeAlertsHaveTheWasntYouPanel(t *testing.T) {
	at := time.Date(2026, 10, 11, 9, 40, 0, 0, time.UTC)
	for _, sub := range []string{"new_passkey", "password_changed", "device_removed", "email_changed_old", "account_unfrozen"} {
		m, err := Alert("maya@example.com", sub, at, "Maya Rahman", "")
		if err != nil {
			t.Fatal(err)
		}
		checkHTML(t, m)
		panel := `<div class="wasnt-you">` + "\n" + `<p class="title">Wasn't you?</p>` + "\n<p>" + htmlEscape(notYou) + "</p>\n</div>"
		if !strings.Contains(m.HTML, panel) {
			t.Errorf("%s: no Wasn't you? panel:\n%s", sub, m.HTML)
		}
		if strings.Count(m.HTML, htmlEscape(notYou)) != 1 || strings.Contains(m.HTML, `class="alarm"`) {
			t.Errorf("%s: the line is repeated or the alarm panel shows", sub)
		}
		if !strings.Contains(m.Text, notYou) {
			t.Errorf("%s: the text part lost its line", sub)
		}
	}
	f, err := Alert("maya@example.com", "account_frozen", at, "Maya Rahman", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.HTML, `<div class="wasnt-you">`) || strings.Contains(f.HTML, DefaultFreezeURL) {
		t.Errorf("the frozen email has no neutral panel, or has a freeze link:\n%s", f.HTML)
	}
	s, err := Alert("maya@example.com", "new_sign_in_passkey", at, "Maya Rahman", DefaultFreezeURL+"#"+strings.Repeat("A", 43))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(s.HTML, `<div class="alarm">`) || strings.Contains(s.HTML, `class="wasnt-you"`) {
		t.Errorf("the sign-in alert lost its alarm panel")
	}
}

func TestDeletedSaysDidntDoThisAtBodySize(t *testing.T) {
	d := Deleted("maya@example.com", time.Date(2026, 10, 11, 9, 40, 0, 0, time.UTC))
	if strings.Contains(d.HTML, `<p class="small">Didn&#39;t do this?`) || !strings.Contains(d.HTML, "<p>Didn&#39;t do this?") {
		t.Errorf("Didn't do this? is not body text:\n%s", d.HTML)
	}
}

func htmlEscape(s string) string { return html.EscapeString(s) }
