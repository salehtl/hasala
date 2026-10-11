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
	}
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
