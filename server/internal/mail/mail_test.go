package mail

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestCloudflareClassifiesAnswers(t *testing.T) {
	var gotAuth, gotPath string
	var gotBody map[string]any
	status, answer := 200, `{"success":true,"errors":[],"messages":[],"result":{"delivered":["a@example.com"],"permanent_bounces":[],"queued":[]}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(answer))
	}))
	defer srv.Close()
	c, err := NewCloudflare("0123456789abcdef0123456789abcdef", "tok", "no-reply@hasala.app")
	if err != nil {
		t.Fatal(err)
	}
	c.BaseURL = srv.URL
	ctx := context.Background()
	if _, err := c.Send(ctx, Message{To: "a@example.com", Subject: "s", Text: "t"}); err != nil {
		t.Fatalf("delivered: %v", err)
	}
	if gotAuth != "Bearer tok" || gotPath != "/accounts/0123456789abcdef0123456789abcdef/email/sending/send" {
		t.Fatalf("auth %q path %q", gotAuth, gotPath)
	}
	if gotBody["to"] != "a@example.com" || gotBody["from"] != "no-reply@hasala.app" || gotBody["html"] != nil {
		t.Fatalf("body %v", gotBody)
	}
	for _, tc := range []struct {
		status int
		answer string
		want   error
	}{
		{200, `{"success":true,"errors":[],"result":{"delivered":[],"permanent_bounces":["a@example.com"],"queued":[]}}`, ErrBounced},
		{400, `{"success":false,"errors":[{"code":10001,"message":"email.sending.error.x"}],"result":null}`, ErrPermanent},
		{401, `{"success":false,"errors":[{"code":10101,"message":"x"}],"result":null}`, ErrAuth},
		{403, `{"success":false,"errors":[{"code":10203,"message":"x"}],"result":null}`, ErrAuth},
	} {
		status, answer = tc.status, tc.answer
		if _, err := c.Send(ctx, Message{To: "a@example.com"}); !errors.Is(err, tc.want) {
			t.Errorf("%d: %v, want %v", tc.status, err, tc.want)
		}
	}
	for _, bad := range []Message{{To: "a@example.com, b@example.com"}, {To: "a@example.com\r\nBcc: c@example.com"},
		{To: ""}, {To: "a@example.com", Subject: "two\nlines"}} {
		if _, err := c.Send(ctx, bad); !errors.Is(err, ErrPermanent) {
			t.Errorf("%q / %q was not refused: %v", bad.To, bad.Subject, err)
		}
	}
	for k := range gotBody {
		switch k {
		case "to", "from", "subject", "text":
		default:
			t.Errorf("the request carries %q (only to, from, subject, text, and html and reply_to when set)", k)
		}
	}

	// With a display name, from is the API's named-address object.
	status, answer = 200, `{"success":true,"errors":[],"result":{"delivered":["a@example.com"],"permanent_bounces":[],"queued":[]}}`
	c.FromName, c.ReplyTo = "Hasala", "support@hasala.app"
	if _, err := c.Send(ctx, Message{To: "a@example.com", Subject: "s", Text: "t"}); err != nil {
		t.Fatalf("named sender: %v", err)
	}
	if gotBody["reply_to"] != "support@hasala.app" {
		t.Fatalf("reply_to %#v", gotBody["reply_to"])
	}
	if f, ok := gotBody["from"].(map[string]any); !ok || len(f) != 2 || f["address"] != "no-reply@hasala.app" || f["name"] != "Hasala" {
		t.Fatalf("named from %#v", gotBody["from"])
	}
	if gotBody["headers"] != nil {
		t.Fatalf("headers without an unsubscribe link: %#v", gotBody["headers"])
	}

	const oneClick = "https://api.hasala.app/api/v1/waitlist/unsubscribe?token=abc"
	if _, err := c.Send(ctx, Message{To: "a@example.com", Subject: "s", Text: "t", Unsubscribe: oneClick}); err != nil {
		t.Fatalf("unsubscribe: %v", err)
	}
	if h, ok := gotBody["headers"].(map[string]any); !ok || len(h) != 2 || h["List-Unsubscribe"] != "<"+oneClick+">" ||
		h["List-Unsubscribe-Post"] != "List-Unsubscribe=One-Click" {
		t.Fatalf("headers %#v", gotBody["headers"])
	}
	for _, bad := range []string{"http://api.hasala.app/x", "https://a/x>, <mailto:b@example.com", "https://a/x\r\nBcc: c@example.com"} {
		if _, err := c.Send(ctx, Message{To: "a@example.com", Unsubscribe: bad}); !errors.Is(err, ErrPermanent) {
			t.Errorf("unsubscribe %q was not refused: %v", bad, err)
		}
	}
	status, answer = 429, `{"success":false,"errors":[{"code":10004,"message":"x"}],"result":null}`
	if _, err := c.Send(ctx, Message{To: "a@example.com"}); err == nil || errors.Is(err, ErrPermanent) ||
		errors.Is(err, ErrAuth) || strings.Contains(err.Error(), "a@example") {
		t.Fatalf("a 429 is transient and names no address, got %v", err)
	}
	status, answer = 503, `{}`
	_, err = c.Send(ctx, Message{To: "a@example.com"})
	if err == nil || errors.Is(err, ErrAuth) || errors.Is(err, ErrPermanent) || errors.Is(err, ErrBounced) {
		t.Fatalf("a 503 is transient, got %v", err)
	}
}

var url = regexp.MustCompile(`https?://\S+`)

// Spec 02 §14.6's rules over every template: plain text, the greeting rule,
// the footer, and no link but the freeze link of two alerts.
func TestTheTemplatesAreContentFree(t *testing.T) {
	at := time.Date(2026, 10, 11, 9, 40, 0, 0, time.UTC)
	if When(at) != "Sun 11 Oct 2026, 13:40 UAE time" {
		t.Fatalf("When = %q", When(at))
	}
	var all []Message
	for _, p := range []string{"signup", "email_verify", "email_change_old", "email_change_new", "password_reset", "recovery"} {
		m, err := Code("maya@example.com", p, "123456", "Maya Rahman")
		if err != nil {
			t.Fatal(err)
		}
		wantHi := "Hi,"
		if CodeGreetsByName(p) {
			wantHi = "Hi Maya,"
		}
		if !strings.HasPrefix(m.Text, wantHi+"\n\n") {
			t.Errorf("code %s opens %q", p, strings.SplitN(m.Text, "\n", 2)[0])
		}
		all = append(all, m)
	}
	for _, sub := range AlertSubkinds {
		link := ""
		if AlertCarriesFreezeLink(sub) {
			link = DefaultFreezeURL + "#" + strings.Repeat("A", 43)
		}
		m, err := Alert("maya@example.com", sub, at, "Maya", link)
		if err != nil {
			t.Fatalf("%s: %v", sub, err)
		}
		links := url.FindAllString(m.Text, -1)
		if (len(links) == 1) != AlertCarriesFreezeLink(sub) || (len(links) == 1 && links[0] != link) {
			t.Errorf("%s carries links %v", sub, links)
		}
		if !strings.HasPrefix(m.Text, "Hi Maya,\n\n") {
			t.Errorf("%s does not greet the holder", sub)
		}
		all = append(all, m)
	}
	all = append(all, AddressInUse("maya@example.com"), Deleted("maya@example.com", at))
	for _, m := range all {
		if !strings.HasSuffix(m.Text, Footer+"\n") {
			t.Errorf("%q: no footer", m.Subject)
		}
		checkHTML(t, m)
		if strings.Contains(m.Subject, "Maya") || strings.Contains(m.Text, "maya@example.com") ||
			strings.Contains(m.HTML, "maya@example.com") {
			t.Errorf("%q names the address or puts the name in the subject", m.Subject)
		}
		for _, l := range url.FindAllString(m.Text, -1) {
			if !strings.HasPrefix(l, DefaultFreezeURL+"#") {
				t.Errorf("%q carries %s", m.Subject, l)
			}
		}
	}
	if _, err := Alert("m@example.com", "new_sign_in_password", at, "", ""); err == nil {
		t.Fatal("a freeze-link alert without its link was rendered")
	}
	if Greeting("") != "Hi," || Greeting("Maya") != "Hi Maya," || Greeting("Maya Rahman") != "Hi Maya," {
		t.Fatal("greeting")
	}
}
