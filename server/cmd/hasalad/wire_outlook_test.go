package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/msjwt"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

// The [outlook] group mounts the Outlook link on the shared route key, with
// or without [gmail], and its push URLs only when configured.
func TestWireExtrasMountsTheOutlookLink(t *testing.T) {
	pool := pgtest.New(t)
	route := filepath.Join(t.TempDir(), "route")
	if err := os.WriteFile(route, []byte(strings.Repeat("ab", 32)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	const clientID = "00000000-1111-4222-8333-444444444444"
	outlook := []string{
		"HASALA_PG_DSN=x",
		"HASALA_MAILBOX_ROUTE_KEY_FILE=" + route,
		"HASALA_OUTLOOK_CLIENT_ID=" + clientID,
	}
	push := []string{
		"HASALA_OUTLOOK_NOTIFICATION_URL=https://api.hasala.app/hooks/outlook/graph",
		"HASALA_OUTLOOK_LIFECYCLE_URL=https://api.hasala.app/hooks/outlook/graph/lifecycle",
	}
	wire := func(env ...string) *api.Server {
		t.Helper()
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
		srv := &api.Server{Pool: pool}
		ctx, cancel := context.WithCancel(context.Background())
		ex, err := wireExtras(ctx, cfg, pool, srv)
		if err != nil {
			t.Fatal(err)
		}
		cancel()
		ex.wait()
		return srv
	}

	// Outlook alone: no Gmail link, no push.
	srv := wire(outlook...)
	if srv.Gmail != nil || srv.Outlook == nil || srv.Outlook.Push != nil || srv.Outlook.ClientID != clientID ||
		!srv.Outlook.RouteKey.Valid() {
		t.Fatalf("outlook link only: gmail %v outlook %+v", srv.Gmail != nil, srv.Outlook)
	}
	if v, ok := srv.Outlook.Link.(*msjwt.Verifier); !ok || v.Audience != clientID {
		t.Fatalf("outlook verifier %T %+v", srv.Outlook.Link, srv.Outlook.Link)
	}

	// With the push.
	srv = wire(append(outlook, push...)...)
	if p := srv.Outlook.Push; p == nil || p.NotificationURL != "https://api.hasala.app/hooks/outlook/graph" ||
		p.LifecycleURL != "https://api.hasala.app/hooks/outlook/graph/lifecycle" {
		t.Fatalf("outlook push %+v", p)
	}

	// Beside Gmail: one route key for both.
	srv = wire(append(outlook, "HASALA_GOOGLE_IOS_CLIENT_ID=1-x.apps.googleusercontent.com")...)
	if srv.Gmail == nil || srv.Outlook == nil {
		t.Fatalf("both links: gmail %v outlook %v", srv.Gmail != nil, srv.Outlook != nil)
	}
	if _, ok := srv.Gmail.Link.(*googlejwt.Verifier); !ok {
		t.Fatalf("gmail verifier %T", srv.Gmail.Link)
	}
	if string(srv.Gmail.RouteKey.KeyID()) != string(srv.Outlook.RouteKey.KeyID()) {
		t.Fatal("the two links have different route keys")
	}

	// Neither link.
	if srv := wire("HASALA_PG_DSN=x"); srv.Outlook != nil || srv.Gmail != nil {
		t.Fatal("bare: a mailbox link is mounted")
	}
}
