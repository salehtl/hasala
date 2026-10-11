# The host-side change that deploys `services.hasala`

This file describes, file by file, the pull requests the owner applies to the
QA host's NixOS flake (its system configuration) to run Hasala's QA backend
from this repository's `nixosModules.default`. Nothing here is applied
automatically, and nothing in this repository changes the host.

Every value in angle brackets is a placeholder the owner fills from his own
records when opening the PR. None of them belongs in this public repository:
the console's host name, the tailnet name, the owner's tailnet login, the
tunnel UUID, the Cloudflare account id, the APNs key id, the Google client and
project ids, the age recipients and the App Store Connect key ids. An opened PR
must contain no placeholder (spec 05 AT-K3).

The host repository's own rules apply to each PR: an agent works in its own
clone and branch, runs `nix fmt`, builds the toplevel, attaches
`nix store diff-closures`, runs the guarded activation test, opens the PR and
stops. The owner merges.

## Before anything: what has changed since spec 05 §8 was written

- **This repository is public.** Spec 05 §8.1's PR A (a read-only GitHub token
  so root can fetch a private flake input, plus its daily check and the CI
  secret) is no longer needed. Skip it, and skip `hasala/nix_access_tokens`.
- **The console is not built yet** (spec 07 §8, WS-19). `hasalad console`
  validates its environment and exits 2. PR C below waits until a hasala
  release has a console that serves.
- **The metrics listener is not served yet.** `HASALA_METRICS_LISTEN` is
  validated but nothing listens, so the `hasala` Prometheus job will show the
  target down until WS-5's metrics land in the server. `hasala-health` does not
  probe it (P6 is left out for that reason).
- **`trusted_proxy = cloudflare` needs a release with spec 02 §16.1's
  client-IP code** (`internal/api/clientip.go`). Before it, every request
  arrives from loopback through the tunnel and each per-IP limit is one global
  limit; older builds say so at start. Do not open the tunnel to testers on a
  build that still warns.

## PR B: "hasala: QA backend at api.hasala.app (own Postgres, own tunnel)"

| File | Change |
| --- | --- |
| `flake.nix` | New input `hasala` (below); add `hasala` to the `outputs` arguments and `hasala.nixosModules.default` to the host's `modules` |
| `flake.lock` | `nix flake lock` (adds `hasala`, its `nixpkgs` and its `nixpkgs-unstable`) |
| `modules/services/hasala.nix` | New: the instance below |
| `hosts/<host>/default.nix` | Import `../../modules/services/hasala.nix` |
| `modules/sops.nix` | The six secrets below |
| `secrets/hasala.yaml` | New; the owner fills the six keys with `sops` (agents never see them) |
| `<the host's taken-ports list>` | Add `8471`, `9471` and `9472` |
| `CLAUDE.md` | An architecture bullet for `modules/services/hasala.nix`, and the "no public ingress" paragraph becomes: the host's only public ingress is Hasala's own tunnel (`cloudflared-hasala.service`, outbound only), `api.hasala.app` with a path allowlist to `127.0.0.1:8471`, everything else 404; no other app may be added to that tunnel |

### `flake.nix` input

```nix
    # Hasala's QA backend. Pinned to a branch that moves only when a CI-green
    # commit of hasala main is released to QA, so the weekly lock bump never
    # deploys unreleased work. Deliberately NO `follows`: the host runs exactly
    # the closure hasala's CI built and tested (its own nixos-26.05 lock, Go
    # 1.27 from nixos-unstable).
    hasala.url = "github:salehtl/hasala/<release branch, e.g. qa>";
```

### `modules/services/hasala.nix`

```nix
# Hasala: the QA backend for the Hasala iOS beta. The module is the hasala
# flake's nixosModules.default (infra/qa/nix/module.nix); this file is this
# host's instance of it.
#
# Ingress:  PUBLIC through its OWN Cloudflare Tunnel (cloudflared-hasala.service,
#           outbound only; no port opened): api.hasala.app +
#           ^/(api/v1/.*|hooks/gmail/pubsub)$ → 127.0.0.1:8471, everything else
#           404. Rendered and asserted by the module, linted by hasala's CI.
#           The API (8471) is never behind the host's LAN reverse proxy.
# Database: its OWN PostgreSQL 17 (hasala-postgresql.service), unix socket only
#           at /run/hasala-postgresql, data /var/lib/hasala-postgresql/17.
#           NOT services.postgresql.
# Backups:  03:15 age-encrypted pg_dump + purge ledger → <backup dir>
#           (29 days) → off-site bucket; no decryption key is on this host.
# Admin:    `sudo hasala-admin <mode>` over SSH.
# Secrets:  secrets/hasala.yaml (modules/sops.nix), all through LoadCredential.
# Ports:    127.0.0.1 only: API 8471, metrics 9471, cloudflared metrics 9472.
{ config, lib, ... }:
let
  cfg = config.services.hasala;
  # The host's taken-ports list, as of the PR.
  taken = [ <the ports already taken on the host> ];
  secret = name: config.sops.secrets."hasala/${name}".path;
in
{
  services.hasala = {
    enable = true;
    apns = {
      keyFile = secret "apns_key_p8";
      keyId = "<APNS_KEY_ID>"; # not secret
    };
    google.iosClientId = "<CLIENT_ID>.apps.googleusercontent.com";
    gmail = {
      pubsubTopic = "projects/<PROJECT>/topics/<TOPIC>";
      pubsubAudience = "https://api.hasala.app/hooks/gmail/pubsub";
      pubsubServiceAccount = "<SA>@<PROJECT>.iam.gserviceaccount.com";
      pubsubSubscription = "projects/<PROJECT>/subscriptions/<SUBSCRIPTION>";
    };
    mailboxRouteKeyFile = secret "mailbox_route_key";
    authKeyFile = secret "auth_key"; # spec 01 §4.11; generated once, never rotated in the beta
    saltKeyFile = secret "salt_key"; # spec 01 §4.11; the password salt key: never rotated, never equal to auth_key
    email = {
      cloudflareAccountId = "<CF_ACCOUNT_ID>"; # not secret
      apiTokenFile = secret "email_api_token"; # Email Sending: Edit only
    };
    tunnel = {
      enable = true;
      id = "<TUNNEL_UUID>"; # not secret (it is in the public CNAME)
      credentialsFile = secret "tunnel_credentials";
    };
    backup = {
      enable = true;
      dir = "<backup dir on the second disk>";
      ageRecipients = [
        "<age1… backup-mac>" # identity: the owner's Mac + password manager
        "<age1… backup-offline>" # identity: printed, offline
      ];
      offsite = {
        enable = true;
        rcloneConfigFile = secret "backup_rclone_conf";
        remote = "<remote>:<bucket>/daily";
      };
    };
    monitoring = {
      onFailure = [ "notify-failure@%n.service" ];
      ntfyUrl = "<the host's ntfy topic URL on loopback>";
      healthCheck.enable = true;
    };
    # Every Hasala unit, and the hasala-admin sandbox, gets these on top of the
    # module's own (/var/lib/postgresql, /run/postgresql, /run/secrets): the
    # state of every other service on the host, any other finance app's
    # database and backups first.
    hardening.inaccessiblePaths = [
      "-/var/lib/postgresql"
      "-/run/postgresql"
      "-/run/secrets"
      "<-/var/lib/… of each other service>"
    ];
  };

  assertions = [
    {
      assertion = lib.all (p: !(lib.elem p taken)) [
        cfg.listen.port
        cfg.metrics.port
        cfg.tunnel.metricsPort
      ];
      message = "hasala: a port collides with one this host already uses.";
    }
  ];
}
```

The module itself adds `RequiresMountsFor=` on the backup directory to every
backup unit (`hasala-backup`, `-premigrate`, `-offsite` and `-check`), so dumps
can never land on `/` behind an unmounted disk. Because `hasala-migrate`
requires the pre-migration dump, a missing backup disk also stops `hasalad`
and the console from starting, even with nothing pending: deliberate, fail
closed, and alerted through `onFailure`.

Every secret option is a **string** path (the `config.sops.secrets.….path`
above), never a Nix path literal: M22 refuses any value under the Nix store,
where a secret would be world-readable.

### `modules/sops.nix`

```nix
secrets."hasala/apns_key_p8"        = { sopsFile = ../secrets/hasala.yaml; key = "hasala/apns_key_p8";        restartUnits = [ "hasalad.service" ]; };
secrets."hasala/mailbox_route_key"  = { sopsFile = ../secrets/hasala.yaml; key = "hasala/mailbox_route_key";  restartUnits = [ "hasalad.service" ]; };
secrets."hasala/auth_key"           = { sopsFile = ../secrets/hasala.yaml; key = "hasala/auth_key";           restartUnits = [ "hasalad.service" ]; };
secrets."hasala/salt_key"           = { sopsFile = ../secrets/hasala.yaml; key = "hasala/salt_key";           restartUnits = [ "hasalad.service" ]; };
secrets."hasala/email_api_token"    = { sopsFile = ../secrets/hasala.yaml; key = "hasala/email_api_token";    restartUnits = [ "hasalad.service" ]; };
secrets."hasala/tunnel_credentials" = { sopsFile = ../secrets/hasala.yaml; key = "hasala/tunnel_credentials"; restartUnits = [ "cloudflared-hasala.service" ]; };
secrets."hasala/backup_rclone_conf" = { sopsFile = ../secrets/hasala.yaml; key = "hasala/backup_rclone_conf"; }; # read per run
```

All stay at the sops-nix default (root, 0400). Units receive them only through
`LoadCredential=`; the module never puts a secret or a secret's path in
`Environment=`, and the server refuses a secret file readable by group or other.

| Secret | Unit | Seen by the process as |
| --- | --- | --- |
| `apns_key_p8` | `hasalad` | `HASALA_APNS_KEY_FILE=%d/apns-key.p8` |
| `mailbox_route_key` | `hasalad` | `HASALA_MAILBOX_ROUTE_KEY_FILE=%d/mailbox-route-key` |
| `auth_key` | `hasalad` | `HASALA_AUTH_KEY_FILE=%d/auth-key` |
| `salt_key` | `hasalad` | `HASALA_SALT_KEY_FILE=%d/salt-key` |
| `email_api_token` | `hasalad`, `hasala-email-token-check` | `HASALA_EMAIL_API_TOKEN_FILE=%d/email-api-token` |
| `tunnel_credentials` | `cloudflared-hasala` | `credentials-file: /run/credentials/cloudflared-hasala.service/tunnel.json` |
| `backup_rclone_conf` | `hasala-backup-offsite`, `hasala-backup-check` | `rclone --config %d/rclone.conf` |

How the owner generates each value is spec 05 §6.1 (the route key, the auth
key and the salt key are generated and encrypted in one pipe and never
displayed). `auth_key` and `salt_key` are two separate 32-byte values (64
lowercase hex each, for example `openssl rand -hex 32` twice): serve refuses
equal keys behind Cloudflare, records each key's fingerprint on first start
and refuses a different key later (spec 02 O9), and the module refuses the
tunnel without both (M12). The salt key is never rotated: a different one makes
every password fail.

### The tunnel (out of band, once, on the owner's Mac)

```sh
nix run github:salehtl/hasala#cloudflared -- tunnel login        # pick the hasala.app zone
nix run github:salehtl/hasala#cloudflared -- tunnel create hasala-qa
nix run github:salehtl/hasala#cloudflared -- tunnel route dns hasala-qa api.hasala.app
# put ~/.cloudflared/<UUID>.json into secrets/hasala.yaml as hasala/tunnel_credentials, then
rm ~/.cloudflared/<UUID>.json ~/.cloudflared/cert.pem
```

The tunnel stays **locally managed**: never "Migrate" it to remote management
in the dashboard, which would take the ingress from the dashboard and bypass
the module's rendered config, its assertions and the CI lint.

### Verification for the PR body

After the guarded activation:

```sh
systemctl is-active hasala.target hasala-postgresql hasalad cloudflared-hasala
systemctl show -P Result hasala-migrate                      # success
curl -s http://127.0.0.1:8471/api/v1/healthz                 # {"status":"ok","db":"ok"}
ss -ltnH | grep -E ':(8471|9471|9472)\b'                     # 127.0.0.1 only
ss -ltnpH | grep postgres                                    # nothing: no TCP
sudo hasala-admin version
sudo systemctl start hasala-backup && ls -l <backup dir>     # a .dump.age, .sha256 and ledger .tar.age
# From outside the host (any network):
curl -s -o /dev/null -w '%{http_code}\n' https://api.hasala.app/api/v1/healthz      # 200
for p in / /admin/ /metrics /debug/pprof/ /api/v1/console; do
  curl -s -o /dev/null -w "$p %{http_code}\n" "https://api.hasala.app$p"          # 403 or 404, never 2xx/3xx
done
# Both internet-facing binaries are built with Go 1.27.N or newer (R-09):
for u in hasalad cloudflared-hasala; do
  bin=$(systemctl show -P ExecStart "$u" | grep -o '/nix/store/[^ ;]*/bin/[a-z]*' | head -1)
  nix run nixpkgs#go -- version -m "$bin" | head -1
done
```

## Bumping a running QA host to the accounts release

The QA host already runs `services.hasala` at a release whose database has
only `00001_baseline.sql`. The accounts release applies `00010`, `00020`,
`00021` and `00022` on top of it, in one `hasala-migrate` run, and it needs one
new secret, `salt_key` (above: `modules/sops.nix`, `secrets/hasala.yaml` and
`saltKeyFile`), in the same host PR as the `flake.lock` bump.

**Pre-flight, before the bump, on the running host.** `00010` adds NOT NULL
columns with no default to `webauthn_credentials` and `writers` and refuses any
`register` or `add` ceremony without its new columns; `00022` adds NOT NULL
columns to `users` and `sessions`. Any such row makes `hasala-migrate` fail
part-way and leaves `hasalad` down (the pre-migration dump is taken first, so
nothing is lost). Check, as the schema owner, with the PostgreSQL 17 client
(`psql`, for example from `nix shell nixpkgs#postgresql_17`):

```sh
sudo -u hasala-migrate psql --no-psqlrc -h /run/hasala-postgresql -d hasala -U hasala_migrate -Atc "
  SELECT (SELECT count(*) FROM users)                                       AS users,
         (SELECT count(*) FROM sessions)                                    AS sessions,
         (SELECT count(*) FROM writers)                                     AS writers,
         (SELECT count(*) FROM webauthn_credentials)                        AS credentials,
         (SELECT count(*) FROM webauthn_ceremonies WHERE kind <> 'login')   AS ceremonies"
# want: 0|0|0|0|0
```

If any count is not 0, clear it with the **old** binary, still deployed:

```sh
# every account (sessions, writers and credentials go with it)
sudo -u hasala-migrate psql --no-psqlrc -h /run/hasala-postgresql -d hasala -U hasala_migrate -Atc "SELECT id FROM users"
sudo hasala-admin purge-user <ACCOUNT_ID> --confirm <ACCOUNT_ID>    # once per id
# ceremonies live 5 minutes and belong to no account yet
sudo -u hasala-migrate psql --no-psqlrc -h /run/hasala-postgresql -d hasala -U hasala_migrate -Atc "DELETE FROM webauthn_ceremonies"
```

Then run the check again: all five must be 0 before the bump is merged. Do
nothing on the host between the check and the activation that could create an
account (the API is not open to testers before this release).

**After the activation**, besides PR B's verification:

```sh
systemctl show -P Result hasala-migrate                      # success
journalctl -u hasala-migrate -o cat | grep 00022             # OK 00022_accounts.sql
journalctl -u hasalad -o cat | grep 'NOT mounted'            # nothing: both key files reached serve
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"invite_code":"ABCDEFGHIJKLMNOPQRSTUVWX","email":"probe@example.com","display_name":"Probe"}' \
  http://127.0.0.1:8471/api/v1/auth/signup/begin             # {"error":"not_invited"}, not a 404
```

## PR C: "hasala: operator console (tailnet only)"

Open it only after PR B is merged and running **and** a hasala release has a
console that serves (spec 07 §8). Until then, enabling it leaves
`hasala-console.service` failed with "not built yet" (harmless, but noisy).

| File | Change |
| --- | --- |
| `<the host's LAN reverse-proxy module>` | Its tailnet-only list gains the entry below; that module's own assertions then cover it (gated names, `Expected-Tailnet` on `/auth`, only `/` and `/auth` locations) |
| `modules/services/hasala.nix` | The `console`, `asc` and `web` settings below, and the taken-ports assertion also checks `console.port` and `console.metricsPort` |
| `<the host's taken-ports list>` | Gains `8472` and `9473` |
| `CLAUDE.md` | The Hasala bullet gains: the console at `https://<console host>`, tailnet-only, identity from tailscale-nginx-auth's `X-Webauth-User`, and the kernel rule that lets only nginx connect to 8472 |

```nix
  # the host's LAN reverse-proxy module, inside its tailnet-only list
    # Hasala's operator console (waitlist, invites, TestFlight, accounts, email
    # log). It trusts X-Webauth-User, which tailscale-nginx-auth sets on this
    # vhost, and the hasala module's kernel rule lets only nginx's UID connect
    # to it. The Hasala API (8471) is public through its own tunnel and must
    # never be listed here.
    <console vhost name> = config.services.hasala.console.port;

  # modules/services/hasala.nix, inside services.hasala
    console = {
      enable = true;
      host = "<console host>";            # never a name under hasala.app (M18)
      logins = [ "<owner's tailnet login>" ];
      tailnet = "<tailnet name>";
    };
    # Manual TestFlight mode until the dedicated App Manager key exists; a
    # follow-up PR adds hasala/asc_key_p8 to sops and switches it on:
    #   asc = {
    #     enable = true;
    #     keyFile = secret "asc_key_p8";
    #     keyId = "<APP_MANAGER_KEY_ID>";
    #     keyKind = "team";                       # or "individual"
    #     issuerId = "<ISSUER_ID>";
    #     refusedKeyIds = [ "<the Mac's upload key id>" ];   # never runs here (PQ-16)
    #   };
    asc.refusedKeyIds = [ "<the Mac's upload key id>" ];
```

What the module adds by itself when `console.enable`:

- `hasala-console.service`: `hasalad console` as its own OS user
  `hasala-console` (peer-mapped to `hasala_runtime` for now; spec 05 review 2's
  own `hasala_console` role waits for the server's grant split),
  `127.0.0.1:8472`, metrics
  and `/healthz` on `127.0.0.1:9473`, no access to `hasalad`'s credentials (and
  `hasalad` none to the console's).
- The kernel rule in `networking.firewall.extraCommands`: locally generated TCP
  to `127.0.0.1:8472` (and its `ip6tables` twin, `[::1]:8472`) is reset unless
  its owner is `console.restrictToUser` (`nginx`). The host's firewall must be
  the iptables one and enabled (M21 refuses nftables and a disabled firewall).
  `hasala-health`'s probe P10 checks every two minutes that the rule still
  resets a non-nginx connection.
- Assertions M14–M19: distinct ports, neither console port in the firewall or
  the tunnel ingress, a non-empty login list, a host outside `hasala.app`, and
  exactly one nginx vhost proxying to the console (by any loopback spelling,
  in `proxyPass`, `extraConfig` or through an upstream), which must be in
  `services.nginx.tailscaleAuth.virtualHosts` with `auth_request /auth;` on `/`.
  M20 also needs a non-empty `asc.refusedKeyIds` whenever `asc.enable`.
- A Prometheus job `hasala-console` (127.0.0.1:9473) and health probe P8.

PR C's body adds the LAN DNS result for the console's name, the closure
diff (the hasala units, nginx's regenerated config, the firewall script) and,
while `asc.enable = false`, the line "TestFlight is manual until the App Store
Connect server key exists".

## Rollback and kill switch

- `sudo systemctl stop hasala.target` stops the API, the console, the tunnel
  and the database together (every unit is `PartOf` it). Clients then see
  Cloudflare's tunnel error.
- A binary rollback is a revert of the `flake.lock` bump; migrations are
  expand-only within a release, so the previous `hasalad` keeps working.
- A PostgreSQL major change refuses to start the cluster until it is dumped and
  restored (the data directory is named after the major).
