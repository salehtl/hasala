package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// env is a fake environment for LoadEnv.
type env map[string]string

func (e env) lookup(k string) (string, bool) { v, ok := e[k]; return v, ok }

func (e env) list() []string {
	out := make([]string, 0, len(e))
	for k, v := range e {
		out = append(out, k+"="+v)
	}
	return out
}

func load(t *testing.T, e env) (Config, error) {
	t.Helper()
	return LoadEnv("", e.lookup, e.list())
}

func mustLoad(t *testing.T, e env) Config {
	t.Helper()
	c, err := load(t, e)
	if err != nil {
		t.Fatalf("LoadEnv: %v", err)
	}
	return c
}

func wantErr(t *testing.T, e env, contains string) {
	t.Helper()
	_, err := load(t, e)
	if err == nil {
		t.Fatalf("LoadEnv accepted %v; want an error mentioning %q", e, contains)
	}
	if !strings.Contains(err.Error(), contains) {
		t.Fatalf("LoadEnv error %q does not mention %q", err, contains)
	}
}

// secretFile writes a 0600 file and returns its path.
func secretFile(t *testing.T, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDefaultsAreSpec02s(t *testing.T) {
	c := mustLoad(t, env{})
	if c.Server.HTTPListen != "127.0.0.1:8443" || c.Server.TrustedProxy != ProxyNone || c.Server.LogLevel != "info" {
		t.Errorf("server defaults = %+v", c.Server)
	}
	if c.Auth.SessionIdle != 720*time.Hour || c.Auth.SessionMax != 2160*time.Hour || c.Auth.InviteTTL != 336*time.Hour ||
		c.Auth.PasswordHashConcurrency != 1 || c.Auth.RPDisplayName != "Hasala" {
		t.Errorf("auth defaults = %+v", c.Auth)
	}
	if c.APNs.Enabled || c.APNs.Topic != "app.hasala.ios" || strings.Join(c.APNs.AllowedEnvironments, ",") != "production,sandbox" {
		t.Errorf("apns defaults = %+v", c.APNs)
	}
	if c.Email.From != "no-reply@hasala.app" || c.Email.FromName != "Hasala" || c.Email.FreezeURL != "https://hasala.app/freeze" ||
		c.Email.WebBaseURL != "https://hasala.app" || c.Email.Enabled() || c.Gmail.LinkEnabled() || c.Gmail.PushEnabled() {
		t.Errorf("email/gmail defaults = %+v / %+v", c.Email, c.Gmail)
	}
}

func TestEveryKeyHasAnEnvironmentName(t *testing.T) {
	key := secretFile(t, 0o600)
	c := mustLoad(t, env{
		"HASALA_PG_DSN": "host=/run/x dbname=hasala user=hasala_runtime", "HASALA_MIGRATE_DSN": "m",
		"HASALA_HTTP_LISTEN": "127.0.0.1:8471", "HASALA_METRICS_LISTEN": "127.0.0.1:9471",
		"HASALA_MIN_IOS_BUILD": "42", "HASALA_LOG_LEVEL": "warn",
		"HASALA_RP_ID": "hasala.app", "HASALA_RP_ORIGINS": "https://hasala.app, https://www.hasala.app",
		"HASALA_SESSION_IDLE": "24h", "HASALA_SESSION_MAX": "48h", "HASALA_INVITE_TTL": "1h",
		"HASALA_PASSWORD_HASH_CONCURRENCY": "2", "HASALA_AUTH_KEY_FILE": key, "HASALA_SALT_KEY_FILE": key,
		"HASALA_HEADROOM_PATH": "/var/lib/hasala", "HASALA_HEADROOM_FLOOR_BYTES": "5", "HASALA_HEADROOM_INTERVAL": "1m",
		"HASALA_APNS_ENABLED": "true", "HASALA_APNS_TEAM_ID": "ABCDE12345", "HASALA_APNS_KEY_ID": "KEY1234567",
		"HASALA_APNS_KEY_FILE": key, "HASALA_APNS_ENVIRONMENTS": "sandbox",
	})
	if c.PGDSN == "" || c.MigrateDSN != "m" || c.Server.HTTPListen != "127.0.0.1:8471" || c.Server.MinIOSBuild != 42 ||
		c.Auth.RPID != "hasala.app" || len(c.Auth.RPOrigins) != 2 || c.Auth.SessionIdle != 24*time.Hour ||
		c.Auth.PasswordHashConcurrency != 2 || c.Auth.SaltKeyFile != key || c.Headroom.FloorBytes != 5 || !c.APNs.Enabled ||
		strings.Join(c.APNs.AllowedEnvironments, ",") != "sandbox" {
		t.Fatalf("environment not applied: %+v", c)
	}
}

func TestATOMLFileIsReadAndUnknownKeysAreRefused(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.toml")
	if err := os.WriteFile(good, []byte("[server]\nhttp_listen = \"127.0.0.1:9000\"\n[auth]\nrp_id = \"hasala.app\"\nrp_origins = [\"https://hasala.app\"]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := LoadEnv(good, env{}.lookup, nil)
	if err != nil || c.Server.HTTPListen != "127.0.0.1:9000" || c.Auth.RPID != "hasala.app" {
		t.Fatalf("toml not applied: %+v, %v", c.Server, err)
	}
	// HASALA_CONFIG names the file when --config does not.
	c, err = LoadEnv("", env{"HASALA_CONFIG": good}.lookup, nil)
	if err != nil || c.Server.HTTPListen != "127.0.0.1:9000" {
		t.Fatalf("HASALA_CONFIG not honoured: %v", err)
	}
	for name, body := range map[string]string{
		"a secret":      "[auth]\nauth_key_file = \"/x\"\n",
		"a typo":        "[server]\nhttp_lisen = \"127.0.0.1:1\"\n",
		"a retired key": "[mail]\ndomain = \"example.test\"\n",
		"the dsn":       "[server]\ndsn = \"postgres://x\"\n",
	} {
		p := filepath.Join(dir, strings.ReplaceAll(name, " ", "_")+".toml")
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadEnv(p, env{}.lookup, nil); err == nil || !strings.Contains(err.Error(), "unrecognized") {
			t.Errorf("%s: accepted (%v)", name, err)
		}
	}
}

// There is no TLS code in hasalad (F3): the listener is plain HTTP and must be
// loopback, whatever else is configured.
func TestTheListenerIsLoopbackOnly(t *testing.T) {
	for _, addr := range []string{":8443", "0.0.0.0:8443", "[::]:8443", "192.0.2.1:8443", "example.test:8443", "nonsense"} {
		wantErr(t, env{"HASALA_HTTP_LISTEN": addr}, "loopback")
	}
	for _, addr := range []string{"127.0.0.1:8471", "[::1]:8471", "localhost:8471"} {
		mustLoad(t, env{"HASALA_HTTP_LISTEN": addr})
	}
	wantErr(t, env{"HASALA_METRICS_LISTEN": "0.0.0.0:9471"}, "loopback")
	wantErr(t, env{"HASALA_METRICS_LISTEN": "127.0.0.1:8443"}, "different ports")
}

func TestValuesAreValidated(t *testing.T) {
	wantErr(t, env{"HASALA_TRUSTED_PROXY": "nginx"}, "trusted_proxy")
	wantErr(t, env{"HASALA_LOG_LEVEL": "loud"}, "log_level")
	wantErr(t, env{"HASALA_MIN_IOS_BUILD": "-1"}, "min_ios_build")
	wantErr(t, env{"HASALA_MIN_IOS_BUILD": "seven"}, "not an integer")
	wantErr(t, env{"HASALA_SESSION_IDLE": "0s"}, "session_idle")
	wantErr(t, env{"HASALA_SESSION_IDLE": "48h", "HASALA_SESSION_MAX": "24h"}, "session_max")
	wantErr(t, env{"HASALA_SESSION_IDLE": "forever"}, "not a duration")
	wantErr(t, env{"HASALA_PASSWORD_HASH_CONCURRENCY": "9"}, "1–8")
	wantErr(t, env{"HASALA_HEADROOM_FLOOR_BYTES": "0"}, "floor_bytes")
	wantErr(t, env{"HASALA_RP_ORIGINS": "https://hasala.app"}, "rp_id is empty")
	wantErr(t, env{"HASALA_RP_ID": "https://hasala.app", "HASALA_RP_ORIGINS": "https://hasala.app"}, "bare domain")
	wantErr(t, env{"HASALA_RP_ID": "hasala.app"}, "rp_origins is empty")
	wantErr(t, env{"HASALA_RP_ID": "hasala.app", "HASALA_RP_ORIGINS": "hasala.app"}, "absolute origin")
	wantErr(t, env{"HASALA_EMAIL_LOG_RETENTION": "100h"}, "HASALA_EMAIL_LOG_RETENTION")
	wantErr(t, env{"HASALA_EMAIL_LOG_RETENTION": "2161h"}, "HASALA_EMAIL_LOG_RETENTION")
	if c := mustLoad(t, env{"HASALA_EMAIL_LOG_RETENTION": "168h"}); c.Web.LogRetention != 168*time.Hour {
		t.Fatalf("HASALA_EMAIL_LOG_RETENTION not applied: %v", c.Web.LogRetention)
	}
	if c := mustLoad(t, env{}); c.Web.LogRetention != 720*time.Hour {
		t.Fatalf("the email log's default retention is %v, want 720h", c.Web.LogRetention)
	}
}

func TestTheOptionalGroupsAreAllOrNothing(t *testing.T) {
	key := secretFile(t, 0o600)
	// APNs: enabled needs its three values.
	wantErr(t, env{"HASALA_APNS_ENABLED": "true"}, "team_id")
	wantErr(t, env{"HASALA_APNS_ENABLED": "true", "HASALA_APNS_TEAM_ID": "ABCDE12345", "HASALA_APNS_KEY_ID": "KEY1234567"}, "HASALA_APNS_KEY_FILE")
	wantErr(t, env{"HASALA_APNS_ENVIRONMENTS": "staging"}, "production or sandbox")
	// Gmail: TestTheGmailGroupIsALinkAndAnOptionalPush.
	// Email: account id without the token, and a bad account id.
	wantErr(t, env{"HASALA_EMAIL_CF_ACCOUNT_ID": strings.Repeat("a", 32)}, "API_TOKEN_FILE")
	wantErr(t, env{"HASALA_EMAIL_CF_ACCOUNT_ID": "nothex", "HASALA_EMAIL_API_TOKEN_FILE": key}, "32 lowercase hex")
	wantErr(t, env{"HASALA_EMAIL_FROM": "no-reply@example.test"}, "hasala.app")
	wantErr(t, env{"HASALA_FREEZE_URL": "http://hasala.app/freeze"}, "https URL on hasala.app")
	wantErr(t, env{"HASALA_WEB_BASE_URL": "https://evil.test"}, "https URL on hasala.app")
}

// The [gmail] group is two parts: the mailbox link (the iOS client id and the
// route key, both or neither) and the Pub/Sub push (four values, all or none,
// and only with the link). The link alone is a valid configuration.
func TestTheGmailGroupIsALinkAndAnOptionalPush(t *testing.T) {
	key := secretFile(t, 0o600)
	link := env{
		"HASALA_GOOGLE_IOS_CLIENT_ID":   "1-abc.apps.googleusercontent.com",
		"HASALA_MAILBOX_ROUTE_KEY_FILE": key,
	}
	push := env{
		"HASALA_GMAIL_PUBSUB_TOPIC":        "projects/p/topics/t",
		"HASALA_GMAIL_PUBSUB_SUBSCRIPTION": "projects/p/subscriptions/s",
		"HASALA_GMAIL_PUBSUB_AUDIENCE":     "https://api.hasala.app/hooks/gmail/pubsub",
		"HASALA_GMAIL_PUBSUB_SA_EMAIL":     "push@p.iam.gserviceaccount.com",
	}
	merge := func(es ...env) env {
		out := env{}
		for _, e := range es {
			for k, v := range e {
				out[k] = v
			}
		}
		return out
	}
	without := func(e env, k string) env {
		out := merge(e)
		delete(out, k)
		return out
	}

	// The link alone: mounted, with no push.
	if c := mustLoad(t, link); !c.Gmail.LinkEnabled() || c.Gmail.PushEnabled() {
		t.Fatalf("link only: link %v push %v", c.Gmail.LinkEnabled(), c.Gmail.PushEnabled())
	}
	// Both parts.
	if c := mustLoad(t, merge(link, push)); !c.Gmail.LinkEnabled() || !c.Gmail.PushEnabled() {
		t.Fatalf("link and push: link %v push %v", c.Gmail.LinkEnabled(), c.Gmail.PushEnabled())
	}

	// Half a link, with or without the push.
	wantErr(t, without(link, "HASALA_MAILBOX_ROUTE_KEY_FILE"), "missing: HASALA_MAILBOX_ROUTE_KEY_FILE")
	wantErr(t, without(link, "HASALA_GOOGLE_IOS_CLIENT_ID"), "missing: gmail.ios_client_id")
	wantErr(t, merge(without(link, "HASALA_MAILBOX_ROUTE_KEY_FILE"), push), "missing: HASALA_MAILBOX_ROUTE_KEY_FILE")

	// Partial push settings are refused, each one named, with the link or without.
	for k := range push {
		wantErr(t, merge(link, without(push, k)), k)
		wantErr(t, merge(link, env{k: push[k]}), "all or nothing")
		wantErr(t, env{k: push[k]}, "all or nothing")
	}
	// The whole push without the link.
	wantErr(t, push, "needs the mailbox link")
	wantErr(t, merge(push, without(link, "HASALA_GOOGLE_IOS_CLIENT_ID")), "missing: gmail.ios_client_id")

	// Shapes.
	wantErr(t, merge(link, env{"HASALA_GOOGLE_IOS_CLIENT_ID": "not-a-client"}), "not a Google client id")
	wantErr(t, merge(link, push, env{"HASALA_GMAIL_PUBSUB_TOPIC": "t"}), "pubsub_topic")
	wantErr(t, merge(link, push, env{"HASALA_GMAIL_PUBSUB_SUBSCRIPTION": "projects/p/topics/t"}), "pubsub_subscription")
	wantErr(t, merge(link, push, env{"HASALA_GMAIL_PUBSUB_AUDIENCE": "http://api.hasala.app/hooks/gmail/pubsub"}), "pubsub_audience")
	wantErr(t, merge(link, env{"HASALA_MAILBOX_ROUTE_KEY_FILE": secretFile(t, 0o640)}), "no group or other permission")
}

func TestSecretFilesMustBePrivate(t *testing.T) {
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": secretFile(t, 0o640)}, "no group or other permission")
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": filepath.Join(t.TempDir(), "absent")}, "secret file")
	mustLoad(t, env{"HASALA_AUTH_KEY_FILE": secretFile(t, 0o400)})
	wantErr(t, env{"HASALA_SALT_KEY_FILE": secretFile(t, 0o640)}, "no group or other permission")
	mustLoad(t, env{"HASALA_SALT_KEY_FILE": secretFile(t, 0o400)})
}

// systemd's LoadCredential= files show 0440 (the ACL mask that grants the
// unit's user read access): accepted inside $CREDENTIALS_DIRECTORY only, and
// still refused when other may read them.
func TestCredentialFilesFromSystemd(t *testing.T) {
	cred := secretFile(t, 0o440)
	dir := filepath.Dir(cred)
	mustLoad(t, env{"HASALA_AUTH_KEY_FILE": cred, "CREDENTIALS_DIRECTORY": dir})
	mustLoad(t, env{"HASALA_AUTH_KEY_FILE": cred, "CREDENTIALS_DIRECTORY": dir + "/"})
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": cred}, "no group or other permission")
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": cred, "CREDENTIALS_DIRECTORY": t.TempDir()}, "no group or other permission")
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": cred, "CREDENTIALS_DIRECTORY": "relative"}, "no group or other permission")
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": secretFile(t, 0o444), "CREDENTIALS_DIRECTORY": dir}, "no group or other permission")
	other := secretFile(t, 0o444)
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": other, "CREDENTIALS_DIRECTORY": filepath.Dir(other)}, "no write or other permission")
	writable := secretFile(t, 0o460)
	wantErr(t, env{"HASALA_AUTH_KEY_FILE": writable, "CREDENTIALS_DIRECTORY": filepath.Dir(writable)}, "no write or other permission")
}

// Behind Cloudflare (the QA host) the production rails apply: mail is
// required, debug logging is refused, and no secret may arrive as a raw value.
func TestTheCloudflarePostureIsStricter(t *testing.T) {
	key := secretFile(t, 0o600)
	prod := func(extra env) env {
		e := env{
			"HASALA_TRUSTED_PROXY":        ProxyCloudflare,
			"HASALA_EMAIL_CF_ACCOUNT_ID":  strings.Repeat("0", 32),
			"HASALA_EMAIL_API_TOKEN_FILE": key,
		}
		for k, v := range extra {
			e[k] = v
		}
		return e
	}
	mustLoad(t, prod(nil))
	wantErr(t, env{"HASALA_TRUSTED_PROXY": ProxyCloudflare}, "required with trusted_proxy = cloudflare")
	wantErr(t, prod(env{"HASALA_LOG_LEVEL": "debug"}), "debug")
	wantErr(t, prod(env{"HASALA_PG_DSN": "host=/run/x user=hasala_runtime password=hunter2"}), "password")
	wantErr(t, prod(env{"HASALA_SOMETHING_TOKEN": "raw"}), "raw value")
	wantErr(t, prod(env{"HASALA_RP_ID": "localhost", "HASALA_RP_ORIGINS": "https://localhost"}), "localhost")
	wantErr(t, prod(env{"HASALA_RP_ID": "hasala.app", "HASALA_RP_ORIGINS": "http://hasala.app"}), "https")
	// The same raw value is tolerated off Cloudflare (local runs and tests).
	mustLoad(t, env{"HASALA_SOMETHING_TOKEN": "raw"})
	// HASALA_EMAIL_API_BASE_URL (a local run's mail capture): behind
	// Cloudflare only the default is accepted; off it, any http(s) root.
	capture := "http://127.0.0.1:18444/client/v4"
	wantErr(t, prod(env{"HASALA_EMAIL_API_BASE_URL": capture}), "HASALA_EMAIL_API_BASE_URL")
	wantErr(t, prod(env{"HASALA_EMAIL_API_BASE_URL": DefaultEmailAPIBaseURL + "/"}), "HASALA_EMAIL_API_BASE_URL")
	if c := mustLoad(t, prod(env{"HASALA_EMAIL_API_BASE_URL": DefaultEmailAPIBaseURL})); c.Email.APIBaseURL != DefaultEmailAPIBaseURL {
		t.Fatalf("the default base: %q", c.Email.APIBaseURL)
	}
	if c := mustLoad(t, env{"HASALA_EMAIL_API_BASE_URL": capture}); c.Email.APIBaseURL != capture {
		t.Fatalf("a local capture base: %q", c.Email.APIBaseURL)
	}
	for _, bad := range []string{"ftp://127.0.0.1/x", "127.0.0.1:18444", "http://u:p@127.0.0.1/x", "http://127.0.0.1/x?y=1"} {
		wantErr(t, env{"HASALA_EMAIL_API_BASE_URL": bad}, "HASALA_EMAIL_API_BASE_URL")
	}
}

func TestModesHaveTheirOwnRequirements(t *testing.T) {
	c := mustLoad(t, env{})
	if err := c.ValidateFor("version"); err != nil {
		t.Fatalf("version needs nothing: %v", err)
	}
	if err := c.ValidateFor("verify"); err == nil || !strings.Contains(err.Error(), "HASALA_PG_DSN") {
		t.Fatalf("verify without a DSN: %v", err)
	}
	if err := c.ValidateFor("migrate"); err == nil || !strings.Contains(err.Error(), "never falls back") {
		t.Fatalf("migrate without HASALA_MIGRATE_DSN: %v", err)
	}
	c.PGDSN = "runtime"
	c.Migrate.Pending = true
	if err := c.ValidateFor("migrate"); err != nil {
		t.Fatalf("migrate --pending accepts the runtime DSN: %v", err)
	}
	if err := c.ValidateFor("serve"); err == nil || !strings.Contains(err.Error(), "rp_id") {
		t.Fatalf("serve without a relying party: %v", err)
	}
	c = mustLoad(t, env{"HASALA_PG_DSN": "x", "HASALA_RP_ID": "hasala.app", "HASALA_RP_ORIGINS": "https://hasala.app"})
	if err := c.ValidateFor("serve"); err == nil || !strings.Contains(err.Error(), "headroom.path") {
		t.Fatalf("serve without a headroom path: %v", err)
	}
	c.Headroom.Path = "/var/lib/hasala"
	if err := c.ValidateFor("serve"); err != nil {
		t.Fatalf("serve: %v", err)
	}
	// Behind Cloudflare serve needs both server keys (review 2 F-04).
	c.Server.TrustedProxy = ProxyCloudflare
	c.Auth.AuthKeyFile = "/run/credentials/hasalad.service/auth-key"
	if err := c.ValidateFor("serve"); err == nil || !strings.Contains(err.Error(), "HASALA_SALT_KEY_FILE") {
		t.Fatalf("serve behind Cloudflare without the salt key: %v", err)
	}
	c.Auth.SaltKeyFile = "/run/credentials/hasalad.service/salt-key"
	if err := c.ValidateFor("serve"); err != nil {
		t.Fatalf("serve with both keys: %v", err)
	}
}

// Fence F7-4 (spec 07 §8.1): serve refuses the console's and App Store
// Connect's variables, and the console refuses serve's secrets.
func TestServeAndConsoleRefuseEachOthersEnvironment(t *testing.T) {
	for _, kv := range []string{"HASALA_CONSOLE_LISTEN=127.0.0.1:8472", "HASALA_ASC_KEY_ID=X", "HASALA_TESTFLIGHT_MODE=manual"} {
		if err := CheckServeEnvironment([]string{"PATH=/bin", kv}); err == nil {
			t.Errorf("serve accepted %s", kv)
		}
	}
	if err := CheckServeEnvironment([]string{"HASALA_PG_DSN=x"}); err != nil {
		t.Errorf("serve refused its own variable: %v", err)
	}
	for _, kv := range []string{"HASALA_AUTH_KEY_FILE=/x", "HASALA_APNS_KEY_FILE=/x", "HASALA_MAILBOX_ROUTE_KEY_FILE=/x",
		"HASALA_EMAIL_API_TOKEN_FILE=/x", "HASALA_TURNSTILE_SECRET_FILE=/x"} {
		if err := CheckConsoleEnvironment([]string{kv}); err == nil {
			t.Errorf("console accepted %s", kv)
		}
	}
}

func TestTheConsoleConfigurationIsChecked(t *testing.T) {
	base := env{
		"HASALA_PG_DSN": "x", "HASALA_RP_ID": "hasala.app", "HASALA_RP_ORIGINS": "https://hasala.app",
		"HASALA_CONSOLE_LISTEN": "127.0.0.1:8472", "HASALA_CONSOLE_METRICS_LISTEN": "127.0.0.1:9473",
		"HASALA_CONSOLE_HOST": "console.example.test", "HASALA_CONSOLE_LOGINS": "operator@github",
		"HASALA_TESTFLIGHT_MODE": "manual",
	}
	if err := mustLoad(t, base).ValidateFor("console"); err != nil {
		t.Fatalf("a good console configuration: %v", err)
	}
	for k, v := range map[string]string{
		"HASALA_CONSOLE_LISTEN":  "localhost:8472",
		"HASALA_CONSOLE_HOST":    "admin.hasala.app",
		"HASALA_CONSOLE_LOGINS":  " , ",
		"HASALA_TESTFLIGHT_MODE": "internal",
	} {
		e := env{}
		for kk, vv := range base {
			e[kk] = vv
		}
		e[k] = v
		if err := mustLoad(t, e).ValidateFor("console"); err == nil {
			t.Errorf("console accepted %s=%q", k, v)
		}
	}
	e := env{}
	for k, v := range base {
		e[k] = v
	}
	e["HASALA_CONSOLE_LISTEN"] = "127.0.0.1:8443" // serve's default port
	if err := mustLoad(t, e).ValidateFor("console"); err == nil {
		t.Error("console accepted a listener on serve's port")
	}
}

func TestModesAreAdvertised(t *testing.T) {
	got := strings.Join(Modes(), ",")
	for _, m := range []string{"serve", "migrate", "verify", "purge-user", "invite", "account", "console", "version"} {
		if !strings.Contains(","+got+",", ","+m+",") {
			t.Errorf("Modes() = %s lacks %s", got, m)
		}
	}
}

// The committed example is a real configuration: it loads, it validates for
// serve with only the runtime DSN added, and its values are the defaults
// wherever it does not say "example".
func TestTheExampleConfigLoads(t *testing.T) {
	e := env{"HASALA_PG_DSN": "host=/tmp dbname=x"}
	cfg, err := LoadEnv("../../config.example.toml", e.lookup, e.list())
	if err != nil {
		t.Fatalf("config.example.toml: %v", err)
	}
	if err := cfg.ValidateFor("serve"); err != nil {
		t.Fatalf("config.example.toml does not validate for serve: %v", err)
	}
	d := defaults()
	if cfg.Server != d.Server || cfg.Auth.SessionIdle != d.Auth.SessionIdle ||
		cfg.Auth.SessionMax != d.Auth.SessionMax || cfg.Headroom.Interval != d.Headroom.Interval ||
		cfg.Headroom.FloorBytes != d.Headroom.FloorBytes {
		t.Fatalf("config.example.toml disagrees with the defaults it claims to show:\n%+v\n%+v", cfg, d)
	}
}

// Spec 02 §15.5: absent is 1; anything but one decimal integer >= 1 refuses.
func TestReadLogGeneration(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	for _, c := range []struct {
		path string
		want int
	}{
		{"", 1},
		{filepath.Join(dir, "absent"), 1},
		{write("one", "1\n"), 1},
		{write("seven", "  7 \n"), 7},
	} {
		got, err := ReadLogGeneration(c.path)
		if err != nil || got != c.want {
			t.Errorf("ReadLogGeneration(%q) = %d, %v; want %d", c.path, got, err, c.want)
		}
	}
	for _, body := range []string{"", "0", "-1", "+2", "two", "1.5", "1 2", "0x10"} {
		p := write("bad", body)
		if n, err := ReadLogGeneration(p); err == nil {
			t.Errorf("ReadLogGeneration(%q) = %d, want an error", body, n)
		}
	}
	if _, err := ReadLogGeneration(dir); err == nil {
		t.Error("a directory was read as a generation")
	}
	c := mustLoad(t, env{"HASALA_LOG_GENERATION_FILE": "/srv/generation"})
	if c.Server.LogGenerationFile != "/srv/generation" {
		t.Fatalf("HASALA_LOG_GENERATION_FILE was not applied: %q", c.Server.LogGenerationFile)
	}
}
