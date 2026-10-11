package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
)

// ceremonySweepInterval is spec 02 §9.7's five-minute sweep of the ceremonies
// that hold a plaintext address.
const ceremonySweepInterval = 5 * time.Minute

// fakeSenderKeeps bounds what serve's fake sender holds in memory.
const fakeSenderKeeps = 64

// loadAuthKeys reads salt_key and auth_key (generation 1, spec 01 §4.11). Both
// files or neither; behind Cloudflare both are required (config) and the two
// keys must differ.
func loadAuthKeys(cfg config.Config) (*authkeys.Keys, error) {
	if cfg.Auth.AuthKeyFile == "" || cfg.Auth.SaltKeyFile == "" {
		return nil, nil
	}
	read := func(name, path string) ([]byte, error) {
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
	salt, err := read("HASALA_SALT_KEY_FILE", cfg.Auth.SaltKeyFile)
	if err != nil {
		return nil, err
	}
	ak, err := read("HASALA_AUTH_KEY_FILE", cfg.Auth.AuthKeyFile)
	if err != nil {
		return nil, err
	}
	if cfg.Server.TrustedProxy == config.ProxyCloudflare && subtle.ConstantTimeCompare(salt, ak) == 1 {
		return nil, errors.New("salt_key and auth_key are the same key; behind Cloudflare they must differ (spec 02 O9)")
	}
	return authkeys.New(salt, map[int][]byte{1: ak}, 1)
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

// enableAccounts wires the account ceremonies (keys, gate, mail) into srv and
// starts the mail worker and the account sweeps. It answers the channels that
// close when they stop. Without both key files the ceremonies stay unmounted.
func enableAccounts(ctx context.Context, cfg config.Config, pool *pgxpool.Pool, srv *api.Server) ([]<-chan struct{}, error) {
	keys, err := loadAuthKeys(cfg)
	if err != nil {
		return nil, refusal{err}
	}
	if keys == nil {
		slog.Warn("hasalad serve: HASALA_AUTH_KEY_FILE and HASALA_SALT_KEY_FILE are not both set: " +
			"signup, password, recovery, reset, email-change and freeze routes are NOT mounted")
		return nil, nil
	}
	if err := checkKeyIDs(ctx, pool, keys); err != nil {
		return nil, refusal{err}
	}
	var sender mail.Sender
	if cfg.Email.Enabled() {
		raw, err := os.ReadFile(cfg.Email.APITokenFile)
		if err != nil {
			return nil, refusal{fmt.Errorf("HASALA_EMAIL_API_TOKEN_FILE: %w", err)}
		}
		from := cfg.Email.From
		if from == "" {
			from = "no-reply@hasala.app"
		}
		sender = &mail.Cloudflare{AccountID: cfg.Email.CloudflareAccountID, Token: strings.TrimSpace(string(raw)), From: from}
	} else {
		slog.Warn("hasalad serve: no [email] group: emails are recorded by a fake sender and never leave this process")
		sender = &mail.Fake{Max: fakeSenderKeeps}
	}
	logf := func(format string, args ...any) { slog.Warn(fmt.Sprintf(format, args...)) }
	q := &mailq.Queue{Pool: pool, Sender: sender, Bounced: auth.BounceHook, Tagger: keys.EmailTag, Logf: logf}
	mailer := &auth.Mailer{Queue: q, Keys: keys, FreezeURL: cfg.Email.FreezeURL, Logf: logf}
	q.Renderers = mailer.Renderers()
	q.EnableKick()
	gate := authkeys.NewGate(cfg.Auth.PasswordHashConcurrency, authkeys.DefaultGateQueue, authkeys.DefaultGateWait)
	srv.EnableAccounts(keys, gate, mailer)

	worker := make(chan struct{})
	go func() {
		defer close(worker)
		q.Run(ctx, 30*time.Second)
	}()
	a := srv.Accounts
	return []<-chan struct{}{
		worker,
		startSweepEvery(ctx, "account ceremony sweep", ceremonySweepInterval, func(ctx context.Context) (string, error) {
			n, err := a.SweepCeremonies(ctx)
			if err != nil || n == 0 {
				return "", err
			}
			return fmt.Sprintf("swept %d expired ceremony(s)", n), nil
		}),
		startSweep(ctx, "mail log sweep", func(ctx context.Context) (string, error) {
			n, err := q.SweepLog(ctx, cfg.Email.LogRetention)
			if err != nil || n == 0 {
				return "", err
			}
			return fmt.Sprintf("deleted or redacted %d email log row(s)", n), nil
		}),
		startSweep(ctx, "account sweep", func(ctx context.Context) (string, error) {
			n, err := a.SweepHourly(ctx)
			if err != nil || n == 0 {
				return "", err
			}
			return fmt.Sprintf("swept %d row(s)", n), nil
		}),
	}, nil
}
