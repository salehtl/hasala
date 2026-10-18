package opsnotify

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPost(t *testing.T) {
	var got *http.Request
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got, body = r, string(b)
	}))
	defer srv.Close()

	n := New(srv.URL+"/topic", "https://console.example/")
	if err := n.Post(context.Background(), "Hasala", "New early-access request", "inbox_tray"); err != nil {
		t.Fatal(err)
	}
	if got.Method != http.MethodPost || got.URL.Path != "/topic" || body != "New early-access request" {
		t.Fatalf("got %s %s %q", got.Method, got.URL.Path, body)
	}
	for h, want := range map[string]string{"Title": "Hasala", "Tags": "inbox_tray", "Click": "https://console.example/"} {
		if v := got.Header.Get(h); v != want {
			t.Errorf("%s = %q, want %q", h, v, want)
		}
	}
}

func TestPostNoClick(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := r.Header["Click"]; ok {
			t.Error("Click header sent without a click URL")
		}
	}))
	defer srv.Close()
	if err := New(srv.URL, "").Post(context.Background(), "t", "m", ""); err != nil {
		t.Fatal(err)
	}
}

func TestPostRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	if err := New(srv.URL, "").Post(context.Background(), "t", "m", ""); err == nil {
		t.Fatal("a 403 was reported as delivered")
	}
}
