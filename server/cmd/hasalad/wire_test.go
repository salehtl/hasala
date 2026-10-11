package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/pgtest"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

// wireExtras turns every configured group on and leaves the rest off; nothing
// here reaches the network (no wake is sent, no email leaves the fake).
func TestWireExtrasFollowsTheConfiguration(t *testing.T) {
	pool := pgtest.New(t)
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	env := []string{
		"HASALA_PG_DSN=x", "HASALA_RP_ID=hasala.app", "HASALA_RP_ORIGINS=https://hasala.app",
		"HASALA_APNS_ENABLED=true", "HASALA_APNS_TEAM_ID=TEAM123456", "HASALA_APNS_KEY_ID=KEY1234567",
		"HASALA_APNS_KEY_FILE=" + write("apns.p8", string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))),
		"HASALA_GOOGLE_IOS_CLIENT_ID=1-x.apps.googleusercontent.com",
		"HASALA_GMAIL_PUBSUB_TOPIC=projects/p/topics/t",
		"HASALA_GMAIL_PUBSUB_SUBSCRIPTION=projects/p/subscriptions/s",
		"HASALA_GMAIL_PUBSUB_AUDIENCE=https://api.hasala.app/hooks/gmail/pubsub",
		"HASALA_GMAIL_PUBSUB_SA_EMAIL=push@p.iam.gserviceaccount.com",
		"HASALA_MAILBOX_ROUTE_KEY_FILE=" + write("route", strings.Repeat("ab", 32)+"\n"),
		"HASALA_AUTH_KEY_FILE=" + write("auth", strings.Repeat("cd", 32)+"\n"),
		"HASALA_WEB_ORIGINS=https://hasala.app",
		"HASALA_EMAIL_CF_ACCOUNT_ID=" + strings.Repeat("0a", 16),
		"HASALA_EMAIL_API_TOKEN_FILE=" + write("cftoken", "test-token\n"),
	}
	load := func(env []string) config.Config {
		t.Helper()
		lookup := func(name string) (string, bool) {
			for _, kv := range env {
				if k, v, ok := strings.Cut(kv, "="); ok && k == name {
					return v, true
				}
			}
			return "", false
		}
		cfg, err := config.LoadEnv("", lookup, env)
		if err != nil {
			t.Fatal(err)
		}
		return cfg
	}
	cfg := load(env)
	srv := &api.Server{Pool: pool}
	ctx, cancel := context.WithCancel(context.Background())
	ex, err := wireExtras(ctx, cfg, pool, srv)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := srv.Push.Waker.(*pushv2.Dispatcher); !ok {
		t.Fatalf("waker %T, want the dispatcher", srv.Push.Waker)
	}
	if srv.Gmail == nil || srv.Meta.GmailWatchTopic != "projects/p/topics/t" || srv.Web == nil {
		t.Fatalf("gmail %v topic %q web %v", srv.Gmail != nil, srv.Meta.GmailWatchTopic, srv.Web != nil)
	}
	// Each verifier has its own audience: the app's ID token is for the iOS
	// client, Pub/Sub's is for the push URL. Swapped, every fake-verifier API
	// test would still pass.
	link, okLink := srv.Gmail.Link.(*googlejwt.Verifier)
	hook, okHook := srv.Gmail.Hook.(*googlejwt.Verifier)
	if !okLink || !okHook || link.Audience != "1-x.apps.googleusercontent.com" ||
		hook.Audience != "https://api.hasala.app/hooks/gmail/pubsub" || srv.Gmail.IOSClientID != link.Audience {
		t.Fatalf("verifiers: link %T %+v, hook %T %+v", srv.Gmail.Link, link, srv.Gmail.Hook, hook)
	}
	// Without HASALA_SALT_KEY_FILE the account ceremonies stay unmounted.
	if srv.Accounts != nil {
		t.Fatal("the account ceremonies were mounted with the auth key alone")
	}
	cancel()
	ex.wait()

	// Both server keys: the account ceremonies are mounted on the same queue.
	srv = &api.Server{Pool: pool}
	ctx, cancel = context.WithCancel(context.Background())
	ex, err = wireExtras(ctx, load(append(env, "HASALA_SALT_KEY_FILE="+write("salt", strings.Repeat("ef", 32)+"\n"))), pool, srv)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Accounts == nil || srv.Accounts.Mail == nil || srv.Accounts.Mail.Queue == nil || srv.Accounts.Keys == nil {
		t.Fatal("the account ceremonies were not mounted with both keys")
	}
	cancel()
	ex.wait()

	// The auth key without [email]: the worker runs (every send fails as
	// not configured) but the website routes are not mounted.
	var noEmail []string
	for _, kv := range env {
		if !strings.HasPrefix(kv, "HASALA_EMAIL_") {
			noEmail = append(noEmail, kv)
		}
	}
	srv = &api.Server{Pool: pool}
	ctx, cancel = context.WithCancel(context.Background())
	ex, err = wireExtras(ctx, load(noEmail), pool, srv)
	if err != nil {
		t.Fatal(err)
	}
	if srv.Web != nil {
		t.Fatal("the waitlist routes are mounted without [email]")
	}
	cancel()
	ex.wait()

	// Without the groups: nothing optional is mounted.
	bare, err := config.LoadEnv("", func(n string) (string, bool) {
		switch n {
		case "HASALA_PG_DSN":
			return "x", true
		}
		return "", false
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	srv = &api.Server{Pool: pool}
	ctx, cancel = context.WithCancel(context.Background())
	ex, err = wireExtras(ctx, bare, pool, srv)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := srv.Push.Waker.(pushv2.NopWaker); !ok || srv.Gmail != nil || srv.Web != nil {
		t.Fatalf("bare: waker %T gmail %v web %v", srv.Push.Waker, srv.Gmail != nil, srv.Web != nil)
	}
	cancel()
	ex.wait()
}

// HASALA_EMAIL_API_BASE_URL reaches the Cloudflare client (a local run's mail
// capture); unset, the client talks to Cloudflare; without [email] nothing is
// sent at all.
func TestTheSenderFollowsTheEmailGroup(t *testing.T) {
	tok := filepath.Join(t.TempDir(), "cftoken")
	if err := os.WriteFile(tok, []byte("test-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	load := func(extra ...string) config.Config {
		t.Helper()
		env := append([]string{"HASALA_EMAIL_CF_ACCOUNT_ID=" + strings.Repeat("0a", 16), "HASALA_EMAIL_API_TOKEN_FILE=" + tok},
			extra...)
		cfg, err := config.LoadEnv("", func(name string) (string, bool) {
			for _, kv := range env {
				if k, v, ok := strings.Cut(kv, "="); ok && k == name {
					return v, true
				}
			}
			return "", false
		}, env)
		if err != nil {
			t.Fatal(err)
		}
		return cfg
	}
	for _, c := range []struct {
		extra []string
		want  string
	}{
		{nil, mail.DefaultBaseURL},
		{[]string{"HASALA_EMAIL_API_BASE_URL=" + mail.DefaultBaseURL}, mail.DefaultBaseURL},
		{[]string{"HASALA_EMAIL_API_BASE_URL=http://127.0.0.1:18444/client/v4"}, "http://127.0.0.1:18444/client/v4"},
	} {
		s, err := newSender(load(c.extra...))
		if err != nil {
			t.Fatal(err)
		}
		cf, ok := s.(*mail.Cloudflare)
		if !ok || cf.BaseURL != c.want {
			t.Fatalf("%v: sender %T base %q, want %q", c.extra, s, cf.BaseURL, c.want)
		}
	}
	if s, err := newSender(config.Config{}); err != nil || s != (mail.Unconfigured{}) {
		t.Fatalf("no [email]: %T %v", s, err)
	}
}
