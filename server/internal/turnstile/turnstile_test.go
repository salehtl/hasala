package turnstile

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func rig(t *testing.T, status int, body string) (*Verifier, *[]string) {
	t.Helper()
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		seen = append(seen, r.Method+" "+r.PostForm.Get("secret")+" "+r.PostForm.Get("response"))
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	v, err := New("test-secret\n", []string{"hasala.app"})
	if err != nil {
		t.Fatal(err)
	}
	v.URL = srv.URL
	return v, &seen
}

func TestVerify(t *testing.T) {
	ctx := context.Background()
	ok := `{"success":true,"hostname":"hasala.app","action":"waitlist"}`
	v, seen := rig(t, http.StatusOK, ok)
	if err := v.Verify(ctx, "tok", "waitlist"); err != nil {
		t.Fatalf("a good token: %v", err)
	}
	if len(*seen) != 1 || (*seen)[0] != "POST test-secret tok" {
		t.Fatalf("siteverify saw %q", *seen)
	}
	if err := v.Verify(ctx, "tok", "bank_request"); !errors.Is(err, ErrRefused) {
		t.Fatalf("another action: %v", err)
	}
	for name, c := range map[string]struct {
		status int
		body   string
		want   error
	}{
		"refused":        {http.StatusOK, `{"success":false,"error-codes":["invalid-input-response"]}`, ErrRefused},
		"other hostname": {http.StatusOK, `{"success":true,"hostname":"example.com","action":"waitlist"}`, ErrRefused},
		"server error":   {http.StatusInternalServerError, ok, ErrUnavailable},
		"bad body":       {http.StatusOK, `<html>`, ErrUnavailable},
	} {
		v, _ := rig(t, c.status, c.body)
		if err := v.Verify(ctx, "tok", "waitlist"); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	v, seen = rig(t, http.StatusOK, ok)
	for _, tok := range []string{"", string(make([]byte, maxToken+1))} {
		if err := v.Verify(ctx, tok, "waitlist"); !errors.Is(err, ErrRefused) {
			t.Errorf("token of %d bytes: %v", len(tok), err)
		}
	}
	if len(*seen) != 0 {
		t.Fatalf("an empty or oversized token reached siteverify")
	}
}

func TestNewRefusesABadSecret(t *testing.T) {
	for _, s := range []string{"", " \n", "two words"} {
		if _, err := New(s, nil); err == nil {
			t.Errorf("New(%q) accepted", s)
		}
	}
}
