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

func TestTheCloudflareClientSendsOneRecipientAndClassifiesResults(t *testing.T) {
	var (
		status int
		reply  string
		got    map[string]any
		auth   string
		path   string
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, path = r.Header.Get("Authorization"), r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		got = map[string]any{}
		_ = json.Unmarshal(raw, &got)
		w.WriteHeader(status)
		_, _ = io.WriteString(w, reply)
	}))
	defer srv.Close()
	c := &Cloudflare{AccountID: "acct", Token: "tok", From: "no-reply@hasala.app", BaseURL: srv.URL}
	m := Message{To: "maya@example.com", Subject: "Your Hasala code", Text: "body"}

	ok := `{"success":true,"errors":[],"messages":[],"result":{"delivered":["maya@example.com"],"permanent_bounces":[],"queued":[]}}`
	for _, tc := range []struct {
		status int
		reply  string
		want   error
	}{
		{200, ok, nil},
		{200, `{"success":true,"errors":[],"result":{"delivered":[],"permanent_bounces":["maya@example.com"],"queued":[]}}`, ErrBounced},
		{400, `{"success":false,"errors":[{"code":10001,"message":"email.sending.error.x"}],"result":null}`, ErrPermanent},
		{401, `{"success":false,"errors":[{"code":10101,"message":"x"}],"result":null}`, ErrAuth},
		{403, `{"success":false,"errors":[{"code":10203,"message":"x"}],"result":null}`, ErrAuth},
		{429, `{"success":false,"errors":[{"code":10004,"message":"x"}],"result":null}`, errTransient},
		{502, `bad gateway`, errTransient},
	} {
		status, reply = tc.status, tc.reply
		_, err := c.Send(context.Background(), m)
		if tc.want == nil && err != nil || tc.want != nil && !errors.Is(err, tc.want) {
			t.Errorf("HTTP %d: %v, want %v", tc.status, err, tc.want)
		}
		if err != nil && strings.Contains(err.Error(), "maya@") {
			t.Errorf("an error carries the address: %v", err)
		}
	}
	if auth != "Bearer tok" || path != "/accounts/acct/email/sending/send" {
		t.Fatalf("request %q %q", auth, path)
	}
	for k := range got {
		switch k {
		case "to", "from", "subject", "text":
		default:
			t.Errorf("the request carries %q (only to, from, subject, text, and html when set)", k)
		}
	}
	if got["to"] != "maya@example.com" || got["from"] != "no-reply@hasala.app" {
		t.Fatalf("request body %v", got)
	}
	if _, err := c.Send(context.Background(), Message{To: "a@example.com, b@example.com", Subject: "x"}); !errors.Is(err, ErrPermanent) {
		t.Fatal("two recipients were accepted")
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
	all = append(all, AddressInUse("maya@example.com"), Deleted("maya@example.com", at), Test("maya@example.com"))
	for _, m := range all {
		if m.HTML != "" || !strings.HasSuffix(m.Text, Footer+"\n") {
			t.Errorf("%q: HTML or no footer", m.Subject)
		}
		if strings.Contains(m.Subject, "Maya") || strings.Contains(m.Text, "maya@example.com") {
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
	if Greeting("") != "Hi," || Greeting("Maya") != "Hi Maya," {
		t.Fatal("greeting")
	}
}
