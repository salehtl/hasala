package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func writeKey(t *testing.T, hexKey string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "key")
	if err := os.WriteFile(p, []byte(hexKey+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	return p
}

// O9: serve records each key's fingerprint the first time and refuses a key
// file whose fingerprint differs; behind Cloudflare the two keys must differ.
func TestServeChecksTheServerKeys(t *testing.T) {
	salt := writeKey(t, strings.Repeat("11", 32))
	auth := writeKey(t, strings.Repeat("22", 32))
	var cfg config.Config
	if k, err := loadAuthKeys(cfg); err != nil || k != nil {
		t.Fatalf("no key files: %v %v", k, err)
	}
	cfg.Auth.SaltKeyFile, cfg.Auth.AuthKeyFile = salt, auth
	keys, err := loadAuthKeys(cfg)
	if err != nil || keys == nil {
		t.Fatal(err)
	}
	pool := pgtest.New(t)
	ctx := context.Background()
	if err := checkKeyIDs(ctx, pool, keys); err != nil {
		t.Fatalf("first start: %v", err)
	}
	if err := checkKeyIDs(ctx, pool, keys); err != nil {
		t.Fatalf("the same keys again: %v", err)
	}
	cfg.Auth.SaltKeyFile = writeKey(t, strings.Repeat("33", 32))
	other, err := loadAuthKeys(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := checkKeyIDs(ctx, pool, other); err == nil || !strings.Contains(err.Error(), "salt_key_id") {
		t.Fatalf("a different salt_key: %v", err)
	}
	cfg.Auth.SaltKeyFile = auth
	cfg.Server.TrustedProxy = config.ProxyCloudflare
	if _, err := loadAuthKeys(cfg); err == nil {
		t.Fatal("equal keys behind Cloudflare were accepted")
	}
	cfg.Auth.SaltKeyFile = writeKey(t, "nothex")
	if _, err := loadAuthKeys(cfg); err == nil {
		t.Fatal("a malformed key file was accepted")
	}
}
