package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/config"
)

// ceremonySweepInterval is spec 02 §9.7's five-minute sweep of the ceremonies
// that hold a plaintext address.
const ceremonySweepInterval = 5 * time.Minute

// loadAuthKeys reads salt_key and auth_key (generation 1, spec 01 §4.11). Both
// files or neither; behind Cloudflare both are required (config) and the two
// keys must differ.
func loadAuthKeys(cfg config.Config) (*authkeys.Keys, error) {
	if cfg.Auth.AuthKeyFile == "" || cfg.Auth.SaltKeyFile == "" {
		return nil, nil
	}
	salt, err := readKeyFile("HASALA_SALT_KEY_FILE", cfg.Auth.SaltKeyFile)
	if err != nil {
		return nil, err
	}
	ak, err := readKeyFile("HASALA_AUTH_KEY_FILE", cfg.Auth.AuthKeyFile)
	if err != nil {
		return nil, err
	}
	if cfg.Server.TrustedProxy == config.ProxyCloudflare && subtle.ConstantTimeCompare(salt, ak) == 1 {
		return nil, errors.New("salt_key and auth_key are the same key; behind Cloudflare they must differ (spec 02 O9)")
	}
	return authkeys.New(salt, map[int][]byte{1: ak}, 1)
}

func readKeyFile(name, path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	k, err := authkeys.ParseKeyHex(string(raw))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return k, nil
}

// checkKeyIDs is O9's fingerprint check: the first start records each key's
// D41 id in server_meta, and every later start refuses a key whose id differs
// (a wrong salt_key would make every password fail silently).
func checkKeyIDs(ctx context.Context, pool *pgxpool.Pool, keys *authkeys.Keys) error {
	for _, kv := range []struct{ key, id string }{
		{"salt_key_id", keys.SaltKeyID},
		{"auth_key_id", keys.AuthKeyID[keys.Current()]},
	} {
		if _, err := pool.Exec(ctx, `INSERT INTO server_meta (key, value) VALUES ($1, $2) ON CONFLICT (key) DO NOTHING`,
			kv.key, kv.id); err != nil {
			return fmt.Errorf("record %s: %w", kv.key, err)
		}
		var stored string
		if err := pool.QueryRow(ctx, `SELECT value FROM server_meta WHERE key = $1`, kv.key).Scan(&stored); err != nil {
			return fmt.Errorf("read %s: %w", kv.key, err)
		}
		if stored != kv.id {
			return fmt.Errorf("the loaded key's %s is %s, the database recorded %s: wrong key file (spec 02 O9)",
				kv.key, kv.id, stored)
		}
	}
	return nil
}
