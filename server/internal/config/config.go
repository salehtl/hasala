// Package config loads hasalad's configuration (spec 02 §18): defaults, then an
// optional TOML file (--config or HASALA_CONFIG; unknown keys refused), then
// HASALA_* environment overrides, then validation. Every key has an environment
// name, so a deployment can be environment-only, and the QA host is.
//
// Secrets never have a TOML key. They arrive as a path in a *_FILE variable
// (systemd LoadCredential=), and a secret file whose mode grants any group or
// other permission is refused. With server.trusted_proxy = cloudflare (the
// production posture) a secret supplied as a raw environment value is refused
// too.
//
// The [apns], [gmail] and [email] groups and the console's environment are
// loaded and validated here so that later workstreams (WS-4 push and Gmail, the
// mail sender, spec 07's console) only wire them in; nothing in this tree uses
// them yet.
package config

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/BurntSushi/toml"

	"github.com/salehtl/hasala/server/internal/headroom"
	"github.com/salehtl/hasala/server/internal/mail"
)

// Config is the full configuration surface.
type Config struct {
	// Mode is the dispatch mode cmd/hasalad is running as (see Modes). Never
	// read from TOML or the environment: main() sets it from the command line.
	Mode string `toml:"-"`

	Server   ServerConfig   `toml:"server"`
	Auth     AuthConfig     `toml:"auth"`
	Headroom HeadroomConfig `toml:"headroom"`
	APNs     APNsConfig     `toml:"apns"`
	Gmail    GmailConfig    `toml:"gmail"`
	Email    EmailConfig    `toml:"email"`
	// Web is spec 07's website routes and mail limits (environment only).
	Web WebConfig `toml:"-"`

	// Console is the operator console's configuration (spec 07 §8, §14.1). It
	// is environment-only and read only by the console mode; serve refuses to
	// start while any of it is set (fence F7-4, CheckServeEnvironment).
	Console ConsoleConfig `toml:"-"`

	// PGDSN is the runtime DSN (HASALA_PG_DSN), connected as hasala_runtime.
	// Environment-only: it may carry a password off the QA host.
	PGDSN string `toml:"-"`
	// MigrateDSN is the schema owner's DSN (HASALA_MIGRATE_DSN), used only by
	// `hasalad migrate` (spec 02 §5.5), which never falls back to PGDSN.
	MigrateDSN string `toml:"-"`

	// The command lines of the operator modes. Command-line only: which
	// account an operator is about to delete, or which invite to mint, must be
	// answerable from the command that ran and from nowhere else.
	Purge   PurgeArgs   `toml:"-"`
	Verify  VerifyArgs  `toml:"-"`
	Invite  InviteArgs  `toml:"-"`
	Migrate MigrateArgs `toml:"-"`
}

// ServerConfig controls the listeners.
type ServerConfig struct {
	// HTTPListen is the API listener. Plain HTTP, always loopback: there is no
	// TLS code in hasalad (spec 02 §21 F3); Cloudflare Tunnel terminates TLS.
	HTTPListen string `toml:"http_listen"`
	// MetricsListen is the optional Prometheus listener (spec 02 §20.1). Off
	// when empty; loopback and distinct from HTTPListen when set.
	MetricsListen string `toml:"metrics_listen"`
	// TrustedProxy is "none" (local runs, tests) or "cloudflare" (the QA host:
	// Cf-Connecting-Ip is trusted from loopback only, spec 02 §16.1, and the
	// production rails below apply).
	TrustedProxy string `toml:"trusted_proxy"`
	// MinIOSBuild, when positive, answers 426 upgrade_required to an app whose
	// CFBundleVersion is lower (spec 02 §6.1; WS-3 wires the gate).
	MinIOSBuild int `toml:"min_ios_build"`
	// LogLevel is debug, info, warn or error; debug is refused behind
	// Cloudflare.
	LogLevel string `toml:"log_level"`
	// LogGenerationFile (HASALA_LOG_GENERATION_FILE, env only) holds spec 02
	// §15.5's log generation: one decimal integer ≥ 1, written only by the
	// operator's restore and wipe runbooks. Absent means 1.
	LogGenerationFile string `toml:"-"`
	// LogGeneration is the file's value, read once by serve at start
	// (ReadLogGeneration) and reported by GET /api/v1/meta.
	LogGeneration int `toml:"-"`
}

// ReadLogGeneration reads spec 02 §15.5's log generation file. An empty path
// or a missing file is generation 1; anything but one decimal integer ≥ 1
// (surrounding whitespace allowed) is an error, because a device compares it
// to decide whether the server was restored under it.
func ReadLogGeneration(path string) (int, error) {
	if path == "" {
		return 1, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 1, nil
	}
	if err != nil {
		return 0, fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", err)
	}
	text := strings.TrimSpace(string(raw))
	n, err := strconv.Atoi(text)
	if err != nil || n < 1 || strings.HasPrefix(text, "+") {
		return 0, fmt.Errorf("HASALA_LOG_GENERATION_FILE %s holds %q: want one decimal integer >= 1", path, text)
	}
	return n, nil
}

// TrustedProxy values.
const (
	ProxyNone       = "none"
	ProxyCloudflare = "cloudflare"
)

// AuthConfig is the WebAuthn relying party, session lifetimes and the server's
// auth key.
type AuthConfig struct {
	// RPID is the bare effective domain ("hasala.app"); RPOrigins are the full
	// origins a ceremony may come from ("https://hasala.app"). Required by
	// serve; localhost is allowed only with trusted_proxy = none.
	RPID          string   `toml:"rp_id"`
	RPDisplayName string   `toml:"rp_display_name"`
	RPOrigins     []string `toml:"rp_origins"`
	// SessionIdle and SessionMax are spec 02 §9.2's sliding idle limit and
	// absolute cap (PO-15: 30 and 90 days).
	SessionIdle time.Duration `toml:"session_idle"`
	SessionMax  time.Duration `toml:"session_max"`
	InviteTTL   time.Duration `toml:"invite_ttl"`
	// PasswordHashConcurrency gates PBKDF2 (spec 02 §16.2), 1–8.
	PasswordHashConcurrency int `toml:"password_hash_concurrency"`
	// AuthKeyFile (HASALA_AUTH_KEY_FILE) holds the 32-byte auth_key, 64 hex
	// (spec 01 §4.11): the pepper, code and tag keys. Never TOML.
	AuthKeyFile string `toml:"-"`
	// SaltKeyFile (HASALA_SALT_KEY_FILE) holds the never-rotated salt_key, 64
	// hex, which keys only the public password salt (review 2 F-04). Never TOML.
	SaltKeyFile string `toml:"-"`
}

// HeadroomConfig is the disk fuse (internal/headroom).
type HeadroomConfig struct {
	// Path is any path on the Postgres data directory's filesystem. Required.
	Path       string        `toml:"path"`
	FloorBytes int64         `toml:"floor_bytes"`
	Interval   time.Duration `toml:"interval"`
}

// APNsConfig is the APNs sender (spec 02 §12; WS-4). When Enabled is false the
// waker is a no-op and the token routes stay mounted.
type APNsConfig struct {
	Enabled             bool     `toml:"enabled"`
	TeamID              string   `toml:"team_id"`
	KeyID               string   `toml:"key_id"`
	Topic               string   `toml:"topic"`
	AllowedEnvironments []string `toml:"allowed_environments"`
	// KeyFile (HASALA_APNS_KEY_FILE) is the .p8 signing key. Never TOML.
	KeyFile string `toml:"-"`
}

// GmailConfig is the Gmail Pub/Sub hook and mailbox link (spec 02 §13; WS-4).
// All or nothing: none of it leaves those routes unmounted.
type GmailConfig struct {
	IOSClientID          string `toml:"ios_client_id"`
	PubSubTopic          string `toml:"pubsub_topic"`
	PubSubSubscription   string `toml:"pubsub_subscription"`
	PubSubAudience       string `toml:"pubsub_audience"`
	PubSubServiceAccount string `toml:"pubsub_service_account"`
	// RouteKeyFile (HASALA_MAILBOX_ROUTE_KEY_FILE): 64 hex. Never TOML.
	RouteKeyFile string `toml:"-"`
}

// Enabled reports whether any of the group is configured.
func (g GmailConfig) Enabled() bool {
	return g.IOSClientID != "" || g.PubSubTopic != "" || g.PubSubSubscription != "" ||
		g.PubSubAudience != "" || g.PubSubServiceAccount != "" || g.RouteKeyFile != ""
}

// EmailConfig is outbound mail through Cloudflare Email Service (spec 02
// §14.4). The account id and the API token are all or nothing; none means
// every email fails (mail.Unconfigured) and the waitlist routes stay off.
// Required behind Cloudflare.
type EmailConfig struct {
	CloudflareAccountID string `toml:"cloudflare_account_id"`
	FromName            string `toml:"from_name"`
	From                string `toml:"from"`
	FreezeURL           string `toml:"freeze_url"`
	// APITokenFile (HASALA_EMAIL_API_TOKEN_FILE). Never TOML.
	APITokenFile string `toml:"-"`
	// WebBaseURL (HASALA_WEB_BASE_URL) is the base of every link in spec 07's
	// emails. Environment-only.
	WebBaseURL string `toml:"-"`
	// APIBaseURL (HASALA_EMAIL_API_BASE_URL) is the Email Service API root,
	// DefaultEmailAPIBaseURL when empty. A local end-to-end run points it at
	// a capture server; with trusted_proxy = cloudflare anything but the
	// default is refused. Environment-only.
	APIBaseURL string `toml:"-"`
}

// DefaultEmailAPIBaseURL is the Email Service API root the sender uses.
const DefaultEmailAPIBaseURL = mail.DefaultBaseURL

// Enabled reports whether either half of the sender is configured.
func (e EmailConfig) Enabled() bool { return e.CloudflareAccountID != "" || e.APITokenFile != "" }

// WebConfig is spec 07 §14.1's serve-side environment: the website routes,
// CORS origins and form redirect, the waitlist ceilings and retention, and the
// mail lanes' rates and the email log's retention.
type WebConfig struct {
	Origins            []string      // HASALA_WEB_ORIGINS; empty = CORS off
	DoneURL            string        // HASALA_WEB_WAITLIST_DONE_URL
	WaitlistMax        int64         // HASALA_WAITLIST_MAX
	WaitlistPendingMax int64         // HASALA_WAITLIST_PENDING_MAX
	WaitlistRetention  time.Duration // HASALA_WAITLIST_RETENTION
	RateWaitlist       int64         // HASALA_EMAIL_RATE_WAITLIST, per hour
	RateBulk           int64         // HASALA_EMAIL_RATE_BULK, per hour
	LogRetention       time.Duration // HASALA_EMAIL_LOG_RETENTION
}

// ConsoleConfig is the operator console's environment (spec 07 §8.1, §14.1).
// Only `hasalad console` reads it.
type ConsoleConfig struct {
	Listen        string   // HASALA_CONSOLE_LISTEN: a literal loopback IP:port
	MetricsListen string   // HASALA_CONSOLE_METRICS_LISTEN
	Host          string   // HASALA_CONSOLE_HOST: never a name under the RP ID
	Logins        []string // HASALA_CONSOLE_LOGINS: comma-separated, non-empty
	Tailnet       string   // HASALA_CONSOLE_TAILNET
	// TestFlightMode (HASALA_TESTFLIGHT_MODE) is "external" or "manual".
	TestFlightMode string
}

// PurgeArgs is `hasalad purge-user <uuid> --confirm <uuid> [--dry-run]`.
type PurgeArgs struct {
	User    string
	Confirm string
	DryRun  bool
}

// VerifyArgs is `hasalad verify structural|usage [--user <uuid>] [--repair]`.
type VerifyArgs struct {
	Check  string // "structural" or "usage"
	User   string
	Repair bool
	JSON   bool
}

// InviteArgs is `hasalad invite mint [--note …] | list`.
type InviteArgs struct {
	Action string // "mint" or "list"
	Note   string
}

// MigrateArgs is `hasalad migrate [--status | --pending] [--to VERSION]`.
type MigrateArgs struct {
	Status  bool
	Pending bool
	To      int64
}

// modeOrder is every mode cmd/hasalad dispatches (spec 02 §18.3, the subset
// built so far). cmd/hasalad cross-checks its dispatch table against it on
// every start (checkModeHandlers).
var modeOrder = []string{"serve", "migrate", "verify", "purge-user", "invite", "waitlist", "email", "console", "version"}

// Modes returns every mode cmd/hasalad dispatches.
func Modes() []string {
	out := make([]string, len(modeOrder))
	copy(out, modeOrder)
	return out
}

func defaults() Config {
	return Config{
		Server: ServerConfig{
			HTTPListen:   "127.0.0.1:8443",
			TrustedProxy: ProxyNone,
			LogLevel:     "info",
		},
		Auth: AuthConfig{
			RPDisplayName:           "Hasala",
			SessionIdle:             720 * time.Hour,
			SessionMax:              2160 * time.Hour,
			InviteTTL:               336 * time.Hour,
			PasswordHashConcurrency: 1,
		},
		Headroom: HeadroomConfig{
			// Spec 02 §18.2's decimal 8 GB, not headroom.DefaultFloor's
			// 8 GiB (ledgerd's, the fuse's own fallback).
			FloorBytes: 8_000_000_000,
			Interval:   headroom.DefaultInterval,
		},
		APNs: APNsConfig{
			Topic:               "app.hasala.ios",
			AllowedEnvironments: []string{"production", "sandbox"},
		},
		Web: WebConfig{
			DoneURL:            "https://hasala.app/joined",
			WaitlistMax:        10_000,
			WaitlistPendingMax: 2_000,
			WaitlistRetention:  4320 * time.Hour,
			RateWaitlist:       60,
			RateBulk:           120,
			LogRetention:       720 * time.Hour,
		},
		Email: EmailConfig{
			FromName:   "Hasala",
			From:       "no-reply@hasala.app",
			FreezeURL:  "https://hasala.app/freeze",
			WebBaseURL: "https://hasala.app",
		},
	}
}

// Load reads path (or HASALA_CONFIG when path is empty), applies the
// environment and validates what every mode shares. Mode-specific
// requirements are ValidateFor's.
func Load(path string) (Config, error) {
	return LoadEnv(path, os.LookupEnv, os.Environ())
}

// LoadEnv is Load against an explicit environment: lookup answers one
// variable, environ lists them all (the raw-secret rail scans every name).
func LoadEnv(path string, lookup func(string) (string, bool), environ []string) (Config, error) {
	cfg := defaults()
	if path == "" {
		path, _ = lookup("HASALA_CONFIG")
	}
	if path != "" {
		meta, err := toml.DecodeFile(path, &cfg)
		if err != nil {
			return Config{}, fmt.Errorf("decode config %q: %w", path, err)
		}
		if bad := meta.Undecoded(); len(bad) > 0 {
			keys := make([]string, len(bad))
			for i, k := range bad {
				keys[i] = k.String()
			}
			return Config{}, fmt.Errorf("config %q sets unrecognized key(s) %s: secrets come only from "+
				"HASALA_*_FILE paths and are never read from TOML, and misspelled keys are refused",
				path, strings.Join(keys, ", "))
		}
	}
	if err := applyEnv(&cfg, lookup); err != nil {
		return Config{}, err
	}
	if err := cfg.validate(lookup, environ); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func applyEnv(c *Config, lookup func(string) (string, bool)) error {
	str := func(name string, dst *string) {
		if v, ok := lookup(name); ok && v != "" {
			*dst = v
		}
	}
	list := func(name string, dst *[]string) {
		if v, ok := lookup(name); ok && v != "" {
			*dst = splitCSV(v)
		}
	}
	var errs []error
	dur := func(name string, dst *time.Duration) {
		if v, ok := lookup(name); ok && v != "" {
			d, err := time.ParseDuration(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not a duration: %w", name, v, err))
				return
			}
			*dst = d
		}
	}
	integer := func(name string, dst *int64) {
		if v, ok := lookup(name); ok && v != "" {
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not an integer: %w", name, v, err))
				return
			}
			*dst = n
		}
	}
	boolean := func(name string, dst *bool) {
		if v, ok := lookup(name); ok && v != "" {
			b, err := strconv.ParseBool(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not a boolean: %w", name, v, err))
				return
			}
			*dst = b
		}
	}

	str("HASALA_PG_DSN", &c.PGDSN)
	str("HASALA_MIGRATE_DSN", &c.MigrateDSN)

	str("HASALA_HTTP_LISTEN", &c.Server.HTTPListen)
	str("HASALA_METRICS_LISTEN", &c.Server.MetricsListen)
	str("HASALA_TRUSTED_PROXY", &c.Server.TrustedProxy)
	var minBuild = int64(c.Server.MinIOSBuild)
	integer("HASALA_MIN_IOS_BUILD", &minBuild)
	c.Server.MinIOSBuild = int(minBuild)
	str("HASALA_LOG_LEVEL", &c.Server.LogLevel)
	str("HASALA_LOG_GENERATION_FILE", &c.Server.LogGenerationFile)

	str("HASALA_RP_ID", &c.Auth.RPID)
	str("HASALA_RP_DISPLAY_NAME", &c.Auth.RPDisplayName)
	list("HASALA_RP_ORIGINS", &c.Auth.RPOrigins)
	dur("HASALA_SESSION_IDLE", &c.Auth.SessionIdle)
	dur("HASALA_SESSION_MAX", &c.Auth.SessionMax)
	dur("HASALA_INVITE_TTL", &c.Auth.InviteTTL)
	var conc = int64(c.Auth.PasswordHashConcurrency)
	integer("HASALA_PASSWORD_HASH_CONCURRENCY", &conc)
	c.Auth.PasswordHashConcurrency = int(conc)
	str("HASALA_AUTH_KEY_FILE", &c.Auth.AuthKeyFile)
	str("HASALA_SALT_KEY_FILE", &c.Auth.SaltKeyFile)

	str("HASALA_HEADROOM_PATH", &c.Headroom.Path)
	integer("HASALA_HEADROOM_FLOOR_BYTES", &c.Headroom.FloorBytes)
	dur("HASALA_HEADROOM_INTERVAL", &c.Headroom.Interval)

	boolean("HASALA_APNS_ENABLED", &c.APNs.Enabled)
	str("HASALA_APNS_TEAM_ID", &c.APNs.TeamID)
	str("HASALA_APNS_KEY_ID", &c.APNs.KeyID)
	str("HASALA_APNS_KEY_FILE", &c.APNs.KeyFile)
	str("HASALA_APNS_TOPIC", &c.APNs.Topic)
	list("HASALA_APNS_ENVIRONMENTS", &c.APNs.AllowedEnvironments)

	str("HASALA_GOOGLE_IOS_CLIENT_ID", &c.Gmail.IOSClientID)
	str("HASALA_GMAIL_PUBSUB_TOPIC", &c.Gmail.PubSubTopic)
	str("HASALA_GMAIL_PUBSUB_SUBSCRIPTION", &c.Gmail.PubSubSubscription)
	str("HASALA_GMAIL_PUBSUB_AUDIENCE", &c.Gmail.PubSubAudience)
	str("HASALA_GMAIL_PUBSUB_SA_EMAIL", &c.Gmail.PubSubServiceAccount)
	str("HASALA_MAILBOX_ROUTE_KEY_FILE", &c.Gmail.RouteKeyFile)

	str("HASALA_EMAIL_CF_ACCOUNT_ID", &c.Email.CloudflareAccountID)
	str("HASALA_EMAIL_FROM_NAME", &c.Email.FromName)
	str("HASALA_EMAIL_FROM", &c.Email.From)
	str("HASALA_FREEZE_URL", &c.Email.FreezeURL)
	str("HASALA_EMAIL_API_TOKEN_FILE", &c.Email.APITokenFile)
	str("HASALA_WEB_BASE_URL", &c.Email.WebBaseURL)
	str("HASALA_EMAIL_API_BASE_URL", &c.Email.APIBaseURL)
	list("HASALA_WEB_ORIGINS", &c.Web.Origins)
	str("HASALA_WEB_WAITLIST_DONE_URL", &c.Web.DoneURL)
	integer("HASALA_WAITLIST_MAX", &c.Web.WaitlistMax)
	integer("HASALA_WAITLIST_PENDING_MAX", &c.Web.WaitlistPendingMax)
	dur("HASALA_WAITLIST_RETENTION", &c.Web.WaitlistRetention)
	integer("HASALA_EMAIL_RATE_WAITLIST", &c.Web.RateWaitlist)
	integer("HASALA_EMAIL_RATE_BULK", &c.Web.RateBulk)
	dur("HASALA_EMAIL_LOG_RETENTION", &c.Web.LogRetention)

	str("HASALA_CONSOLE_LISTEN", &c.Console.Listen)
	str("HASALA_CONSOLE_METRICS_LISTEN", &c.Console.MetricsListen)
	str("HASALA_CONSOLE_HOST", &c.Console.Host)
	list("HASALA_CONSOLE_LOGINS", &c.Console.Logins)
	str("HASALA_CONSOLE_TAILNET", &c.Console.Tailnet)
	str("HASALA_TESTFLIGHT_MODE", &c.Console.TestFlightMode)
	return errors.Join(errs...)
}

// validate checks what every mode shares.
func (c Config) validate(lookup func(string) (string, bool), environ []string) error {
	switch c.Server.TrustedProxy {
	case ProxyNone, ProxyCloudflare:
	default:
		return fmt.Errorf("server.trusted_proxy is %q (HASALA_TRUSTED_PROXY): want %q or %q",
			c.Server.TrustedProxy, ProxyNone, ProxyCloudflare)
	}
	prod := c.Server.TrustedProxy == ProxyCloudflare
	if !IsLoopbackListen(c.Server.HTTPListen) {
		return fmt.Errorf("server.http_listen is %q (HASALA_HTTP_LISTEN): it must be a loopback "+
			"host:port; hasalad serves plain HTTP only and is reached through the tunnel", c.Server.HTTPListen)
	}
	if c.Server.MetricsListen != "" {
		if !IsLoopbackListen(c.Server.MetricsListen) {
			return fmt.Errorf("server.metrics_listen is %q (HASALA_METRICS_LISTEN): it must be loopback",
				c.Server.MetricsListen)
		}
		if samePort(c.Server.MetricsListen, c.Server.HTTPListen) {
			return fmt.Errorf("server.metrics_listen and server.http_listen must use different ports")
		}
	}
	if c.Server.MinIOSBuild < 0 {
		return fmt.Errorf("server.min_ios_build must not be negative")
	}
	switch c.Server.LogLevel {
	case "info", "warn", "error":
	case "debug":
		if prod {
			return errors.New("server.log_level debug is refused with trusted_proxy = cloudflare")
		}
	default:
		return fmt.Errorf("server.log_level is %q: want debug, info, warn or error", c.Server.LogLevel)
	}
	if err := c.validateAuth(prod); err != nil {
		return err
	}
	if err := c.validateHeadroom(); err != nil {
		return err
	}
	if err := c.validateAPNs(); err != nil {
		return err
	}
	if err := c.validateWeb(); err != nil {
		return err
	}
	if err := c.validateGmail(); err != nil {
		return err
	}
	if err := c.validateEmail(prod); err != nil {
		return err
	}
	credDir, _ := lookup("CREDENTIALS_DIRECTORY")
	for name, path := range map[string]string{
		"HASALA_AUTH_KEY_FILE":          c.Auth.AuthKeyFile,
		"HASALA_SALT_KEY_FILE":          c.Auth.SaltKeyFile,
		"HASALA_APNS_KEY_FILE":          c.APNs.KeyFile,
		"HASALA_MAILBOX_ROUTE_KEY_FILE": c.Gmail.RouteKeyFile,
		"HASALA_EMAIL_API_TOKEN_FILE":   c.Email.APITokenFile,
	} {
		if path == "" {
			continue
		}
		check := CheckSecretFile
		if InCredentialsDirectory(path, credDir) {
			check = CheckCredentialFile
		}
		if err := check(path); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	if prod {
		if err := refuseRawSecrets(c, lookup, environ); err != nil {
			return err
		}
	}
	return nil
}

func (c Config) validateAuth(prod bool) error {
	a := c.Auth
	if a.RPID != "" || len(a.RPOrigins) > 0 {
		if a.RPID == "" {
			return errors.New("auth.rp_origins is set but auth.rp_id is empty (HASALA_RP_ID)")
		}
		if strings.ContainsAny(a.RPID, "/:") {
			return fmt.Errorf("auth.rp_id is %q: it must be a bare domain with no scheme and no port", a.RPID)
		}
		if a.RPID == "localhost" && prod {
			return errors.New("auth.rp_id localhost is allowed only with trusted_proxy = none")
		}
		if len(a.RPOrigins) == 0 {
			return errors.New("auth.rp_id is set but auth.rp_origins is empty (HASALA_RP_ORIGINS)")
		}
		for _, o := range a.RPOrigins {
			u, err := url.Parse(o)
			if err != nil || u.Scheme == "" || u.Host == "" {
				return fmt.Errorf("auth.rp_origins entry %q is not an absolute origin (\"https://hasala.app\")", o)
			}
			if prod && u.Scheme != "https" {
				return fmt.Errorf("auth.rp_origins entry %q must be https with trusted_proxy = cloudflare", o)
			}
		}
	}
	if a.SessionIdle <= 0 {
		return errors.New("auth.session_idle must be positive (HASALA_SESSION_IDLE)")
	}
	if a.SessionMax < a.SessionIdle {
		return fmt.Errorf("auth.session_max (%s) must be at least auth.session_idle (%s)", a.SessionMax, a.SessionIdle)
	}
	if a.InviteTTL <= 0 {
		return errors.New("auth.invite_ttl must be positive (HASALA_INVITE_TTL)")
	}
	if a.PasswordHashConcurrency < 1 || a.PasswordHashConcurrency > 8 {
		return fmt.Errorf("auth.password_hash_concurrency is %d: want 1–8", a.PasswordHashConcurrency)
	}
	return nil
}

func (c Config) validateHeadroom() error {
	if c.Headroom.FloorBytes <= 0 {
		return fmt.Errorf("headroom.floor_bytes is %d (HASALA_HEADROOM_FLOOR_BYTES): a zero floor is a fuse that never trips",
			c.Headroom.FloorBytes)
	}
	if c.Headroom.Interval <= 0 {
		return fmt.Errorf("headroom.interval is %v (HASALA_HEADROOM_INTERVAL): it must be positive", c.Headroom.Interval)
	}
	return nil
}

var appleID10 = regexp.MustCompile(`^[A-Z0-9]{10}$`)

func (c Config) validateAPNs() error {
	a := c.APNs
	for _, e := range a.AllowedEnvironments {
		if e != "production" && e != "sandbox" {
			return fmt.Errorf("apns.allowed_environments entry %q: want production or sandbox", e)
		}
	}
	if !a.Enabled {
		return nil
	}
	switch {
	case !appleID10.MatchString(a.TeamID):
		return fmt.Errorf("apns.enabled needs apns.team_id (HASALA_APNS_TEAM_ID), 10 characters")
	case !appleID10.MatchString(a.KeyID):
		return fmt.Errorf("apns.enabled needs apns.key_id (HASALA_APNS_KEY_ID), 10 characters")
	case a.KeyFile == "":
		return errors.New("apns.enabled needs HASALA_APNS_KEY_FILE")
	case a.Topic == "":
		return errors.New("apns.topic must not be empty")
	case len(a.AllowedEnvironments) == 0:
		return errors.New("apns.allowed_environments must not be empty")
	}
	return nil
}

func (c Config) validateGmail() error {
	g := c.Gmail
	if !g.Enabled() {
		return nil
	}
	missing := []string{}
	for name, v := range map[string]string{
		"gmail.ios_client_id (HASALA_GOOGLE_IOS_CLIENT_ID)":            g.IOSClientID,
		"gmail.pubsub_topic (HASALA_GMAIL_PUBSUB_TOPIC)":               g.PubSubTopic,
		"gmail.pubsub_subscription (HASALA_GMAIL_PUBSUB_SUBSCRIPTION)": g.PubSubSubscription,
		"gmail.pubsub_audience (HASALA_GMAIL_PUBSUB_AUDIENCE)":         g.PubSubAudience,
		"gmail.pubsub_service_account (HASALA_GMAIL_PUBSUB_SA_EMAIL)":  g.PubSubServiceAccount,
		"HASALA_MAILBOX_ROUTE_KEY_FILE":                                g.RouteKeyFile,
	} {
		if v == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("the [gmail] group is all or nothing; missing: %s", strings.Join(sortedCopy(missing), ", "))
	}
	if !strings.HasSuffix(g.IOSClientID, ".apps.googleusercontent.com") {
		return fmt.Errorf("gmail.ios_client_id %q is not a Google client id", g.IOSClientID)
	}
	if !strings.HasPrefix(g.PubSubTopic, "projects/") || !strings.Contains(g.PubSubTopic, "/topics/") {
		return fmt.Errorf("gmail.pubsub_topic %q: want projects/<P>/topics/<t>", g.PubSubTopic)
	}
	if !strings.HasPrefix(g.PubSubSubscription, "projects/") || !strings.Contains(g.PubSubSubscription, "/subscriptions/") {
		return fmt.Errorf("gmail.pubsub_subscription %q: want projects/<P>/subscriptions/<s>", g.PubSubSubscription)
	}
	if u, err := url.Parse(g.PubSubAudience); err != nil || u.Scheme != "https" || u.Host == "" {
		return fmt.Errorf("gmail.pubsub_audience %q: want the https URL of the hook", g.PubSubAudience)
	}
	return nil
}

func (c Config) validateWeb() error {
	w := c.Web
	for _, o := range w.Origins {
		u, err := url.Parse(o)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("HASALA_WEB_ORIGINS entry %q: want an https origin with no path", o)
		}
	}
	if u, err := url.Parse(w.DoneURL); err != nil || u.Scheme != "https" || u.Host != "hasala.app" || u.RawQuery != "" {
		return fmt.Errorf("HASALA_WEB_WAITLIST_DONE_URL is %q: it must be an https URL on hasala.app", w.DoneURL)
	}
	switch {
	case w.WaitlistMax < 1 || w.WaitlistPendingMax < 1:
		return errors.New("HASALA_WAITLIST_MAX and HASALA_WAITLIST_PENDING_MAX must be positive")
	case w.WaitlistRetention < 24*time.Hour:
		return errors.New("HASALA_WAITLIST_RETENTION must be at least 24h")
	case w.RateWaitlist < 1 || w.RateBulk < 1:
		return errors.New("HASALA_EMAIL_RATE_WAITLIST and HASALA_EMAIL_RATE_BULK must be positive")
	case w.LogRetention < 168*time.Hour || w.LogRetention > 2160*time.Hour:
		return errors.New("HASALA_EMAIL_LOG_RETENTION must be between 168h and 2160h")
	}
	return nil
}

var cfAccountID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func (c Config) validateEmail(prod bool) error {
	e := c.Email
	if !strings.HasSuffix(e.From, "@hasala.app") || strings.ContainsAny(e.From, " <>\"") ||
		strings.ToLower(e.From) != e.From {
		return fmt.Errorf("email.from is %q: it must be a lowercase address at hasala.app", e.From)
	}
	if e.FromName == "" || strings.ContainsAny(e.FromName, "<>\"\r\n@") {
		return fmt.Errorf("email.from_name is %q: a plain display name is required", e.FromName)
	}
	for name, raw := range map[string]string{"email.freeze_url": e.FreezeURL, "HASALA_WEB_BASE_URL": e.WebBaseURL} {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host != "hasala.app" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("%s is %q: it must be an https URL on hasala.app with no query or fragment", name, raw)
		}
	}
	if e.APIBaseURL != "" {
		u, err := url.Parse(e.APIBaseURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
			u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("HASALA_EMAIL_API_BASE_URL is %q: it must be an http(s) URL with no query or fragment",
				e.APIBaseURL)
		}
		if prod && e.APIBaseURL != DefaultEmailAPIBaseURL {
			return fmt.Errorf("HASALA_EMAIL_API_BASE_URL is %q: with trusted_proxy = cloudflare email goes only to %s",
				e.APIBaseURL, DefaultEmailAPIBaseURL)
		}
	}
	if e.Enabled() {
		if !cfAccountID.MatchString(e.CloudflareAccountID) {
			return errors.New("the [email] group is all or nothing: email.cloudflare_account_id " +
				"(HASALA_EMAIL_CF_ACCOUNT_ID) must be 32 lowercase hex characters")
		}
		if e.APITokenFile == "" {
			return errors.New("the [email] group is all or nothing: HASALA_EMAIL_API_TOKEN_FILE is missing")
		}
	} else if prod {
		return errors.New("the [email] group is required with trusted_proxy = cloudflare " +
			"(HASALA_EMAIL_CF_ACCOUNT_ID and HASALA_EMAIL_API_TOKEN_FILE)")
	}
	return nil
}

var rawSecretName = regexp.MustCompile(`^HASALA_[A-Z0-9_]*_(KEY|TOKEN|SECRET)$`)

// refuseRawSecrets is the production rail of spec 02 §18.1: behind Cloudflare,
// no secret may arrive as a raw environment value (it would be visible in
// /proc and in `systemctl show`), and a DSN may not carry a password (the QA
// host uses peer authentication).
func refuseRawSecrets(c Config, lookup func(string) (string, bool), environ []string) error {
	for _, dsn := range []struct{ name, v string }{{"HASALA_PG_DSN", c.PGDSN}, {"HASALA_MIGRATE_DSN", c.MigrateDSN}} {
		if strings.Contains(strings.ToLower(dsn.v), "password") {
			return fmt.Errorf("%s carries a password; with trusted_proxy = cloudflare the database "+
				"is reached by peer authentication only", dsn.name)
		}
	}
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if rawSecretName.MatchString(name) {
			if v, ok := lookup(name); ok && v != "" {
				return fmt.Errorf("%s is set as a raw value; with trusted_proxy = cloudflare secrets "+
					"come only from %s_FILE paths", name, name)
			}
		}
	}
	return nil
}

// ValidateFor adds the requirements of one mode to what Load checked.
func (c Config) ValidateFor(mode string) error {
	switch mode {
	case "version":
		return nil
	case "migrate":
		// --pending alone accepts the runtime DSN (spec 02 §5.5).
		if c.MigrateDSN == "" && !(c.Migrate.Pending && c.PGDSN != "") {
			return errors.New("migrate needs HASALA_MIGRATE_DSN (it never falls back to HASALA_PG_DSN)")
		}
		return nil
	}
	if c.PGDSN == "" {
		return errors.New("HASALA_PG_DSN is required")
	}
	switch mode {
	case "serve":
		if c.Auth.RPID == "" {
			return errors.New("serve needs auth.rp_id (HASALA_RP_ID) and auth.rp_origins (HASALA_RP_ORIGINS)")
		}
		if c.Headroom.Path == "" {
			return errors.New("serve needs headroom.path (HASALA_HEADROOM_PATH): the filesystem the disk fuse samples")
		}
		if c.Server.TrustedProxy == ProxyCloudflare && (c.Auth.AuthKeyFile == "" || c.Auth.SaltKeyFile == "") {
			return errors.New("serve needs HASALA_AUTH_KEY_FILE and HASALA_SALT_KEY_FILE with trusted_proxy = cloudflare")
		}
	case "console":
		return c.validateConsole()
	}
	return nil
}

// CheckServeEnvironment is fence F7-4's serve half (spec 07 §8.1): serve
// refuses to start while any console or App Store Connect variable is set, so
// a mis-wired unit cannot turn the public process into a console or hand it
// the App Store Connect key.
func CheckServeEnvironment(env []string) error {
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(name, "HASALA_CONSOLE_") || strings.HasPrefix(name, "HASALA_ASC_") ||
			name == "HASALA_TESTFLIGHT_MODE" {
			return fmt.Errorf("serve refuses to start with %s set: it belongs to the operator console", name)
		}
	}
	return nil
}

// CheckConsoleEnvironment is fence F7-4's console half: the console refuses
// serve's secrets.
func CheckConsoleEnvironment(env []string) error {
	refused := map[string]bool{
		"HASALA_TURNSTILE_SECRET_FILE": true, "HASALA_AUTH_KEY_FILE": true, "HASALA_APNS_KEY_FILE": true,
		"HASALA_MAILBOX_ROUTE_KEY_FILE": true, "HASALA_EMAIL_API_TOKEN_FILE": true,
	}
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if refused[name] {
			return fmt.Errorf("console refuses to start with %s set: it is a secret of serve", name)
		}
	}
	return nil
}

func (c Config) validateConsole() error {
	k := c.Console
	if !isLiteralLoopback(k.Listen) {
		return fmt.Errorf("HASALA_CONSOLE_LISTEN is %q: it must be a literal loopback IP:port (127.0.0.1 or ::1)", k.Listen)
	}
	for _, other := range []string{c.Server.HTTPListen, c.Server.MetricsListen, k.MetricsListen} {
		if other != "" && samePort(k.Listen, other) {
			return fmt.Errorf("HASALA_CONSOLE_LISTEN %q shares a port with %q", k.Listen, other)
		}
	}
	if k.MetricsListen != "" && !isLiteralLoopback(k.MetricsListen) {
		return fmt.Errorf("HASALA_CONSOLE_METRICS_LISTEN is %q: it must be a literal loopback IP:port", k.MetricsListen)
	}
	if len(k.Logins) == 0 {
		return errors.New("HASALA_CONSOLE_LOGINS must list at least one login")
	}
	if k.Host == "" {
		return errors.New("HASALA_CONSOLE_HOST is required")
	}
	if c.Auth.RPID != "" && (k.Host == c.Auth.RPID || strings.HasSuffix(k.Host, "."+c.Auth.RPID)) {
		return fmt.Errorf("HASALA_CONSOLE_HOST %q is under the RP ID: the console never lives on a %s name", k.Host, c.Auth.RPID)
	}
	if k.TestFlightMode != "external" && k.TestFlightMode != "manual" {
		return fmt.Errorf("HASALA_TESTFLIGHT_MODE is %q: want external or manual", k.TestFlightMode)
	}
	return nil
}

// CheckSecretFile refuses a secret file that is missing, not a regular file, or
// readable by group or other (spec 02 §18.1).
func CheckSecretFile(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("secret file: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("secret file %s is not a regular file", path)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("secret file %s has mode %v: it must grant no group or other permission", path, fi.Mode().Perm())
	}
	return nil
}

// InCredentialsDirectory reports whether path names a file directly inside
// credDir, the $CREDENTIALS_DIRECTORY systemd gives a unit with
// LoadCredential= (spec 05 §5.5). An empty credDir matches nothing.
func InCredentialsDirectory(path, credDir string) bool {
	if credDir == "" || !filepath.IsAbs(credDir) {
		return false
	}
	return filepath.Dir(filepath.Clean(path)) == filepath.Clean(credDir)
}

// CheckCredentialFile is CheckSecretFile for a file systemd placed in the
// unit's credentials directory (LoadCredential=, spec 05 §5.5). systemd
// writes it root-owned 0400 and grants the unit's user read access through an
// ACL, so stat shows the ACL mask in the group bits (0440) although no group
// can read it; the directory itself is reachable by the unit alone. Any
// permission for other is still refused.
func CheckCredentialFile(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("secret file: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("secret file %s is not a regular file", path)
	}
	if fi.Mode().Perm()&0o027 != 0 {
		return fmt.Errorf("credential file %s has mode %v: it must grant no write or other permission", path, fi.Mode().Perm())
	}
	return nil
}

// IsLoopbackListen reports whether a listen address binds only loopback. An
// address with no host (":8443") binds every interface and is not loopback.
func IsLoopbackListen(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// isLiteralLoopback is the console's stricter rule: 127.0.0.1 or ::1 exactly,
// never a name.
func isLiteralLoopback(addr string) bool {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return false
	}
	return host == "127.0.0.1" || host == "::1"
}

func samePort(a, b string) bool {
	_, pa, errA := net.SplitHostPort(a)
	_, pb, errB := net.SplitHostPort(b)
	return errA == nil && errB == nil && pa == pb
}

func splitCSV(v string) []string {
	fields := strings.Split(v, ",")
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

func sortedCopy(s []string) []string {
	out := append([]string(nil), s...)
	sort.Strings(out)
	return out
}
