package mail

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
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
	status, answer = 503, `{}`
	_, err = c.Send(ctx, Message{To: "a@example.com"})
	if err == nil || errors.Is(err, ErrAuth) || errors.Is(err, ErrPermanent) || errors.Is(err, ErrBounced) {
		t.Fatalf("a 503 is transient, got %v", err)
	}
}
