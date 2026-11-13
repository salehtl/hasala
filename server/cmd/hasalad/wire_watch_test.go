package main

import (
	"context"
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestServeForgetsTheWatchOfAProviderWithNoPush(t *testing.T) {
	pool := pgtest.New(t)
	ctx := context.Background()
	route := filepath.Join(t.TempDir(), "route")
	secret := strings.Repeat("ab", 32)
	if err := os.WriteFile(route, []byte(secret+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rk, err := gmailpush.ParseRouteKey(secret)
	if err != nil {
		t.Fatal(err)
	}
	seed := func(provider string, n byte) uuid.UUID {
		t.Helper()
		u := oplogtest.NewUserWithoutKeys(t, pool)
		writer := "ios-00000000-0000-4000-8000-0000000000" + string([]byte{'a', 'a' + n})
		oplogtest.NewWriter(t, pool, u, writer)
		var cs []byte
		if provider == gmailpush.ProviderOutlook {
			sum := sha256.Sum256([]byte{n})
			cs = sum[:]
		}
		if _, err := pool.Exec(ctx, `INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id,
		    client_state_hash, watch_expires_at, created_at, updated_at)
		    VALUES ($1, $2, $3, $4, $5, $6, now() + interval '3 days', now(), now())`,
			u, provider, rk.AddressHMACFor(provider, u.String()), rk.KeyID(), writer, cs); err != nil {
			t.Fatal(err)
		}
		return u
	}
	gmail, outlook := seed(gmailpush.ProviderGmail, 1), seed(gmailpush.ProviderOutlook, 2)
	restore := func() {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE mailbox_links SET watch_expires_at = now() + interval '3 days'`); err != nil {
			t.Fatal(err)
		}
	}
	watching := func(u uuid.UUID) bool {
		t.Helper()
		var on bool
		if err := pool.QueryRow(ctx, `SELECT watch_expires_at IS NOT NULL FROM mailbox_links WHERE user_id = $1`, u).Scan(&on); err != nil {
			t.Fatal(err)
		}
		return on
	}
	wire := func(env ...string) {
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
		runCtx, cancel := context.WithCancel(ctx)
		ex, err := wireExtras(runCtx, cfg, pool, &api.Server{Pool: pool})
		if err != nil {
			t.Fatal(err)
		}
		cancel()
		ex.wait()
	}
	base := []string{"HASALA_PG_DSN=x", "HASALA_MAILBOX_ROUTE_KEY_FILE=" + route}
	gmailLink := "HASALA_GOOGLE_IOS_CLIENT_ID=1-x.apps.googleusercontent.com"
	outlookLink := "HASALA_OUTLOOK_CLIENT_ID=00000000-1111-4222-8333-444444444444"
	gmailPush := []string{
		"HASALA_GMAIL_PUBSUB_TOPIC=projects/p/topics/t",
		"HASALA_GMAIL_PUBSUB_SUBSCRIPTION=projects/p/subscriptions/s",
		"HASALA_GMAIL_PUBSUB_AUDIENCE=https://api.hasala.app/hooks/gmail/pubsub",
		"HASALA_GMAIL_PUBSUB_SA_EMAIL=push@p.iam.gserviceaccount.com",
	}
	outlookPush := []string{
		"HASALA_OUTLOOK_NOTIFICATION_URL=https://api.hasala.app/hooks/outlook/graph",
		"HASALA_OUTLOOK_LIFECYCLE_URL=https://api.hasala.app/hooks/outlook/graph/lifecycle",
	}
	links := append(append([]string{}, base...), gmailLink, outlookLink)

	wire(append(append(append([]string{}, links...), gmailPush...), outlookPush...)...)
	if !watching(gmail) || !watching(outlook) {
		t.Fatalf("both pushes on: gmail %v outlook %v", watching(gmail), watching(outlook))
	}

	wire(append(append([]string{}, links...), outlookPush...)...)
	if watching(gmail) || !watching(outlook) {
		t.Fatalf("only outlook's push: gmail %v outlook %v", watching(gmail), watching(outlook))
	}

	restore()
	wire(links...)
	if watching(gmail) || watching(outlook) {
		t.Fatalf("no push: gmail %v outlook %v", watching(gmail), watching(outlook))
	}

	restore()
	wire("HASALA_PG_DSN=x")
	if watching(gmail) || watching(outlook) {
		t.Fatalf("no link group: gmail %v outlook %v", watching(gmail), watching(outlook))
	}
}
