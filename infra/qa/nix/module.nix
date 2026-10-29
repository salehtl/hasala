# services.hasala: the Hasala QA backend as a NixOS module (spec 05 §5).
#
# Exported as nixosModules.hasala (and .default) by the repository's flake.
# It is system-agnostic and takes its packages from this flake's own
# packages.<system>, so a host runs exactly the closure the hasala CI built,
# whatever nixpkgs the host itself follows.
#
# What it runs (every unit PartOf hasala.target, in hasala.slice):
#   hasala-postgresql         Hasala's OWN PostgreSQL 17 (never the host's
#                             services.postgresql); unix socket only, peer auth
#   hasala-db-setup           roles and database, idempotent (infra/qa/db/setup.sql)
#   hasala-backup-premigrate  an encrypted dump before a migration that has work to do
#   hasala-migrate            `hasalad migrate` as hasala_migrate, before every start
#   hasala-purge-replay       `hasalad purge-user --replay-ledger`, after every migrate
#   hasalad                   `hasalad serve` on 127.0.0.1 (the API)
#   hasala-console            `hasalad console` on 127.0.0.1, its own OS user (spec 07)
#   cloudflared-hasala        the tunnel; the only path in from the internet
#   hasala-backup(+timer), hasala-backup-offsite, hasala-backup-check(+timer)
#   hasala-health(+timer), hasala-email-token-check(+timer)
#
# Secrets are only ever absolute string paths given as options, never Nix
# path literals and never under the Nix store (M22). Each reaches exactly one
# unit through LoadCredential= and is passed to the process as a *_FILE path
# into $CREDENTIALS_DIRECTORY; no secret is ever in Environment=.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    types
    optional
    optionals
    optionalAttrs
    optionalString
    concatStringsSep
    ;

  cfg = config.services.hasala;
  hp = self.packages.${pkgs.stdenv.hostPlatform.system};
  pgLib = import ./postgresql.nix { inherit lib; };
  ingressLib = import ./ingress.nix { inherit lib; };

  pg = cfg.database.package;
  pgMajor = lib.versions.major pg.version;
  pgRoot = "/var/lib/hasala-postgresql";
  dataDir = "${pgRoot}/${pgMajor}";
  socketDir = "/run/hasala-postgresql";
  ledgerDir = "/var/lib/hasala-ledger";
  maintenanceLock = "/run/hasala-maintenance.lock";

  runtimeDSN = "host=${socketDir} dbname=hasala user=hasala_runtime";
  migrateDSN = "host=${socketDir} dbname=hasala user=hasala_migrate";
  backupDSN = "host=${socketDir} dbname=hasala user=hasala_backup";

  hasalad = lib.getExe cfg.package;
  # The app id the AASA must name (P5): team id + bundle id.
  appId = "${cfg.apns.teamId}.${cfg.apns.topic}";
  loopback = port: "127.0.0.1:${toString port}";

  # ---------------------------------------------------------------- hardening
  # §5.2: every long-running Hasala unit starts from this.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    DevicePolicy = "closed";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    KeyringMode = "private";
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    UMask = "0077";
    RemoveIPC = true;
    Slice = "hasala.slice";
    # No core dump of a process that holds a key (spec 05 §5.2, review 2 F-22).
    LimitCORE = 0;
    # Never reach the neighbours: the host's Postgres, the host's secrets, and
    # whatever the host adds (its other services' state).
    InaccessiblePaths = cfg.hardening.inaccessiblePaths;
  };

  # Loopback and the internet stay reachable; the LAN, the tailnet (CGNAT),
  # link-local and ULA do not.
  denyLanAndTailnet = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "100.64.0.0/10"
    "169.254.0.0/16"
    "fc00::/7"
    "fe80::/10"
  ];

  # ----------------------------------------------------------------- postgres
  hbaFile = pkgs.writeText "hasala-pg_hba.conf" pgLib.hba;
  identFile = pkgs.writeText "hasala-pg_ident.conf" (pgLib.ident { console = cfg.console.enable; });
  pgConf = pkgs.writeText "hasala-postgresql.conf" (
    pgLib.renderConf {
      settings = pgLib.baseSettings // cfg.database.settings;
      inherit socketDir hbaFile identFile;
    }
  );
  setupSql = ../db/setup.sql;

  # ------------------------------------------------------------------- tunnel
  tunnelConfig = pkgs.writeText "cloudflared-hasala.yml" cfg.tunnel.renderedConfig;

  # ---------------------------------------------------------------- hasalad env
  # §5.5: the complete, non-secret environment of `hasalad serve`. Secrets are
  # *_FILE paths into the credentials directory (%d).
  apnsOn = cfg.apns.keyFile != null;
  # The [gmail] group's two parts (M8a, M8b): the mailbox link, and the
  # Pub/Sub push that needs it.
  gmailLinkOn = cfg.google.iosClientId != null;
  gmailPushOn = cfg.gmail.pubsubTopic != null;
  # The [outlook] group's two parts (M8c, M8d), the same shape: the mailbox
  # link (the Entra client id and the shared route key), and the Graph
  # change-notification push that needs it.
  outlookLinkOn = cfg.outlook.clientId != null;
  outlookPushOn = cfg.outlook.notificationUrl != null;
  # The route key keys AddressHMAC for both providers; either link mounts it.
  mailboxRouteKeyOn = gmailLinkOn || outlookLinkOn;
  emailOn = cfg.email.apiTokenFile != null;
  turnstileOn = cfg.web.turnstile.secretFile != null;

  fixedEnv = {
    HASALA_HTTP_LISTEN = "${cfg.listen.address}:${toString cfg.listen.port}";
    HASALA_METRICS_LISTEN = loopback cfg.metrics.port;
    HASALA_PG_DSN = runtimeDSN;
    HASALA_TRUSTED_PROXY = if cfg.tunnel.enable then "cloudflare" else "none";
    HASALA_RP_ID = cfg.rpId;
    HASALA_RP_ORIGINS = concatStringsSep "," cfg.rpOrigins;
    HASALA_RP_DISPLAY_NAME = "Hasala";
    HASALA_HEADROOM_PATH = "/var/lib/hasala";
    HASALA_HEADROOM_FLOOR_BYTES = toString cfg.headroomFloorBytes;
    HASALA_MIN_IOS_BUILD = toString cfg.minIosBuild;
    HASALA_HEADROOM_INTERVAL = "30s";
    HASALA_PASSWORD_HASH_CONCURRENCY = toString cfg.passwordHashConcurrency;
    HASALA_PURGE_LEDGER_PATH = "${ledgerDir}/purged";
    HASALA_LOG_GENERATION_FILE = "${ledgerDir}/generation";
    HASALA_WEB_BASE_URL = cfg.web.baseUrl;
    HASALA_WEB_WAITLIST_DONE_URL = cfg.web.waitlistDoneUrl;
    HASALA_WAITLIST_MAX = "10000";
    HASALA_WAITLIST_PENDING_MAX = "2000";
    HASALA_WAITLIST_RETENTION = "4320h";
    HASALA_EMAIL_RATE_WAITLIST = "60";
    HASALA_EMAIL_RATE_BULK = "120";
    HASALA_EMAIL_LOG_RETENTION = "720h";
    HASALA_INVITE_TTL = "336h";
    GOMEMLIMIT = "600MiB";
    TZ = "UTC";
  }
  // optionalAttrs (cfg.web.origins != [ ]) {
    HASALA_WEB_ORIGINS = concatStringsSep "," cfg.web.origins;
  }
  // optionalAttrs apnsOn {
    HASALA_APNS_ENABLED = "true";
    HASALA_APNS_KEY_FILE = "%d/apns-key.p8";
    HASALA_APNS_KEY_ID = cfg.apns.keyId;
    HASALA_APNS_TEAM_ID = cfg.apns.teamId;
    HASALA_APNS_TOPIC = cfg.apns.topic;
    HASALA_APNS_ENVIRONMENTS = concatStringsSep "," cfg.apns.environments;
  }
  // optionalAttrs mailboxRouteKeyOn {
    HASALA_MAILBOX_ROUTE_KEY_FILE = "%d/mailbox-route-key";
  }
  // optionalAttrs gmailLinkOn {
    HASALA_GOOGLE_IOS_CLIENT_ID = cfg.google.iosClientId;
  }
  // optionalAttrs gmailPushOn {
    HASALA_GMAIL_PUBSUB_TOPIC = cfg.gmail.pubsubTopic;
    HASALA_GMAIL_PUBSUB_AUDIENCE = cfg.gmail.pubsubAudience;
    HASALA_GMAIL_PUBSUB_SA_EMAIL = cfg.gmail.pubsubServiceAccount;
    HASALA_GMAIL_PUBSUB_SUBSCRIPTION = cfg.gmail.pubsubSubscription;
  }
  // optionalAttrs outlookLinkOn {
    HASALA_OUTLOOK_CLIENT_ID = cfg.outlook.clientId;
  }
  // optionalAttrs outlookPushOn {
    HASALA_OUTLOOK_NOTIFICATION_URL = cfg.outlook.notificationUrl;
    HASALA_OUTLOOK_LIFECYCLE_URL = cfg.outlook.lifecycleUrl;
  }
  // optionalAttrs (cfg.authKeyFile != null) {
    HASALA_AUTH_KEY_FILE = "%d/auth-key";
  }
  // optionalAttrs (cfg.saltKeyFile != null) {
    HASALA_SALT_KEY_FILE = "%d/salt-key";
  }
  // optionalAttrs emailOn {
    HASALA_EMAIL_CF_ACCOUNT_ID = cfg.email.cloudflareAccountId;
    HASALA_EMAIL_API_TOKEN_FILE = "%d/email-api-token";
    HASALA_EMAIL_FROM = cfg.email.from;
    HASALA_EMAIL_FROM_NAME = cfg.email.fromName;
    HASALA_EMAIL_REPLY_TO = cfg.email.replyTo;
  }
  // optionalAttrs turnstileOn {
    HASALA_TURNSTILE_SECRET_FILE = "%d/turnstile-secret";
    HASALA_TURNSTILE_REQUIRED = "true";
    HASALA_TURNSTILE_HOSTNAMES = cfg.rpId;
  }
  // optionalAttrs cfg.monitoring.earlyAccessNotice {
    HASALA_OPS_NTFY_URL = cfg.monitoring.ntfyUrl;
  }
  // optionalAttrs (cfg.monitoring.earlyAccessNotice && cfg.console.enable) {
    HASALA_OPS_NTFY_CLICK = "https://${toString cfg.console.host}/";
  };

  hasaladCredentials =
    optional apnsOn "apns-key.p8:${cfg.apns.keyFile}"
    ++ optional (cfg.mailboxRouteKeyFile != null) "mailbox-route-key:${cfg.mailboxRouteKeyFile}"
    ++ optional (cfg.authKeyFile != null) "auth-key:${cfg.authKeyFile}"
    ++ optional (cfg.saltKeyFile != null) "salt-key:${cfg.saltKeyFile}"
    ++ optional emailOn "email-api-token:${cfg.email.apiTokenFile}"
    ++ optional turnstileOn "turnstile-secret:${cfg.web.turnstile.secretFile}";

  # ---------------------------------------------------------------- console env
  # §5.13 / spec 07 §14.1: the console's complete environment. None of serve's
  # secrets; serve never gets any of these (fence F7-4, M20).
  consoleEnv = {
    # Deviates from spec 05 review 2 row 1 (F-10), which moves the console and
    # the CLI to their own role, hasala_console, until spec 02/07's grant split
    # exists: today the baseline migration grants DML to hasala_runtime only,
    # so a hasala_console DSN would leave the console with no table access.
    HASALA_PG_DSN = runtimeDSN;
    HASALA_RP_ID = cfg.rpId;
    # Not in spec 07 §14.1's table, but the server's shared configuration
    # check refuses HASALA_RP_ID without HASALA_RP_ORIGINS in every mode.
    HASALA_RP_ORIGINS = concatStringsSep "," cfg.rpOrigins;
    HASALA_CONSOLE_LISTEN = loopback cfg.console.port;
    HASALA_CONSOLE_METRICS_LISTEN = loopback cfg.console.metricsPort;
    HASALA_CONSOLE_HOST = toString cfg.console.host;
    HASALA_CONSOLE_LOGINS = concatStringsSep "," cfg.console.logins;
    HASALA_CONSOLE_TAILNET = toString cfg.console.tailnet;
    HASALA_PURGE_LEDGER_PATH = "${ledgerDir}/purged";
    HASALA_TESTFLIGHT_MODE = if cfg.asc.enable then "external" else "manual";
    GOMEMLIMIT = "200MiB";
    TZ = "UTC";
  }
  // optionalAttrs cfg.asc.enable {
    HASALA_ASC_KEY_FILE = "%d/asc-key.p8";
    HASALA_ASC_KEY_ID = cfg.asc.keyId;
    HASALA_ASC_KEY_KIND = cfg.asc.keyKind;
    HASALA_ASC_ISSUER_ID = cfg.asc.issuerId;
    HASALA_ASC_BUNDLE_ID = cfg.asc.bundleId;
    HASALA_ASC_BETA_GROUP = cfg.asc.betaGroup;
    HASALA_ASC_TESTER_LIMIT = toString cfg.asc.testerLimit;
    HASALA_ASC_RECONCILE_INTERVAL = "10m";
    HASALA_ASC_REQUEST_BUDGET = "300";
  };

  # ------------------------------------------------------------------- backups
  offsiteFilter = "--filter '- *.part' --filter '+ hasala-*.age*' --filter '- *'";
  ageRecipientFlags = concatStringsSep " " (map (r: "-r ${r}") cfg.backup.ageRecipients);
  backupScript = pkgs.writeShellApplication {
    name = "hasala-backup";
    runtimeInputs = [
      pg
      pkgs.age
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnutar
      pkgs.util-linux
    ];
    text = ''
      # §5.8: an age-encrypted custom-format dump plus the purge ledger, then
      # retention. The plaintext dump is never written to a file: pg_dump
      # streams into age, and a copy of the stream goes through a FIFO to
      # pg_restore --list, whose TOC (no data) is the only thing kept under
      # $RUNTIME_DIRECTORY (tmpfs, 0700). Both are removed on every exit.
      tag="''${1:-daily}"
      case "$tag" in daily | premigrate) ;; *) echo "hasala-backup: unknown tag $tag" >&2; exit 2 ;; esac
      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      dir=${lib.escapeShellArg cfg.backup.dir}
      out="$dir/hasala-$tag-$ts.dump.age"
      led="$dir/hasala-ledger-$tag-$ts.tar.age"
      exec 9< ${maintenanceLock}
      flock 9
      work="$(mktemp -d "$RUNTIME_DIRECTORY/work.XXXXXX")"
      trap 'rm -rf "$work"; rm -f "$out.part" "$led.part"' EXIT
      mkfifo -m 0600 "$work/stream"
      { pg_restore --list > "$work/toc"; cat > /dev/null; } < "$work/stream" &
      toc_pid=$!
      pg_dump --host=${socketDir} --username=hasala_backup --dbname=hasala \
        --format=custom --compress=zstd:6 --no-password \
        | tee "$work/stream" \
        | age ${ageRecipientFlags} -o "$out.part"
      wait "$toc_pid"
      if [ "$tag" = daily ]; then grep -q ' TABLE DATA public op_log ' "$work/toc"; fi
      sync "$out.part"
      mv "$out.part" "$out"
      ( cd "$dir" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
      # The purge ledger and the log generation (§5.8.1), read through the
      # hasala-ledger group; never written here.
      # A missing purge ledger, or one that cannot be read, fails the backup
      # (pipefail), never an empty ledger copy.
      [ -f ${ledgerDir}/purged ] || { echo "hasala-backup: ${ledgerDir}/purged is missing" >&2; exit 1; }
      files=(purged)
      if [ -e ${ledgerDir}/generation ]; then files+=(generation); fi
      tar -C ${ledgerDir} -cf - -T /dev/null "''${files[@]}" \
        | age ${ageRecipientFlags} -o "$led.part"
      sync "$led.part"
      mv "$led.part" "$led"
      # Retention is a hard bound (N-06): every dump, ledger copy and checksum
      # ${toString cfg.backup.retentionDays} days old or older goes, however few remain.
      find "$dir" -maxdepth 1 -name 'hasala-*.age*' -mtime +${
        toString (cfg.backup.retentionDays - 1)
      } -delete
      date +%s > "$STATE_DIRECTORY/last-success-$tag"
      echo "hasala-backup: $tag written"
    '';
  };

  backupServiceConfig = hardening // {
    Type = "oneshot";
    User = "hasala-backup";
    Group = "hasala-backup";
    SupplementaryGroups = [
      "hasala-db"
      "hasala-ledger"
    ];
    PrivateNetwork = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    IPAddressDeny = "any";
    ReadWritePaths = [ cfg.backup.dir ];
    StateDirectory = "hasala-backup";
    StateDirectoryMode = "0700";
    RuntimeDirectory = "hasala-backup";
    RuntimeDirectoryMode = "0700";
    Nice = 10;
    IOSchedulingClass = "idle";
    MemoryMax = cfg.limits.backupMemoryMax;
    CPUQuota = "100%";
  };

  # ------------------------------------------------------------------- admin
  # §5.7: first word of the mode → OS user (→ role through pg_ident). Only the
  # modes this hasalad has; 02 §18.3's later modes join as they are built.
  adminModes = {
    invite = "hasala";
    waitlist = "hasala";
    account = "hasala";
    email = "hasala";
    purge-user = "hasala";
    verify = "hasala";
    version = "hasala";
    migrate = "hasala-migrate";
  };
  hasalaAdmin = pkgs.writeShellApplication {
    name = "hasala-admin";
    runtimeInputs = [
      config.systemd.package
      pkgs.util-linux
    ];
    text = ''
      [ "$(id -u)" -eq 0 ] || { echo "hasala-admin: run it with sudo" >&2; exit 2; }
      mode="''${1:-}"; [ $# -gt 0 ] && shift
      case "$mode" in
        ${concatStringsSep "\n    " (lib.mapAttrsToList (m: u: "${m}) user=${u} ;;") adminModes)}
        *) echo "usage: sudo hasala-admin {${concatStringsSep "|" (lib.attrNames adminModes)}} [flags]" >&2; exit 2 ;;
      esac
      # Every mode except migrate runs as hasala_runtime: spec 02 §5.6 refuses
      # any non-migrate mode whose role owns op_log or key_history. (Spec 05
      # review 2 row 1, F-10, moves these to OS user hasala-cli → role
      # hasala_console; deferred until spec 02/07's grants for that role exist.)
      if [ "$user" = hasala-migrate ]; then
        dsn="HASALA_MIGRATE_DSN=${migrateDSN}"
        groups="hasala-db"
      else
        dsn="HASALA_PG_DSN=${runtimeDSN}"
        groups="hasala-db hasala-ledger"
      fi
      logger -t hasala-admin -- "mode=$mode by=''${SUDO_USER:-root}"   # never the arguments
      io=--pipe; [ -t 0 ] && [ -t 1 ] && io=--pty
      # --description: without it systemd logs "Started <the full command line>",
      # which would put the arguments (a note, an account id) in the journal.
      exec systemd-run --quiet --wait --collect "$io" --service-type=exec \
        --description="hasala-admin $mode" \
        --uid="$user" --gid="$user" -p SupplementaryGroups="$groups" -p Slice=hasala.slice \
        -p NoNewPrivileges=yes -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes \
        -p PrivateDevices=yes -p ProtectKernelTunables=yes -p ProtectControlGroups=yes \
        -p PrivateNetwork=yes -p RestrictAddressFamilies=AF_UNIX -p CapabilityBoundingSet= \
        -p LimitCORE=0 \
        ${concatStringsSep " " (map (p: "-p InaccessiblePaths=${p}") cfg.hardening.inaccessiblePaths)} \
        -p SyslogIdentifier=hasala-admin -p ReadWritePaths=${ledgerDir} -p UMask=0077 \
        -E "$dsn" -E TZ=UTC -E HASALA_PURGE_LEDGER_PATH=${ledgerDir}/purged \
        -E "HASALA_ADMIN_ACTOR=cli:''${SUDO_USER:-root}" \
        ${hasalad} "$mode" "$@"
    '';
  };

  # ------------------------------------------------------------------ health
  # §5.9.3, the probes this build can answer: P1 (local API), P2–P4 and P9
  # (through Cloudflare, when the tunnel is on), P5 (the AASA, headers and
  # body), and with the console on P8 (its /healthz) and P10 (the kernel rule
  # still resets a non-nginx connection to the console port, on 127.0.0.1 and
  # ::1; this unit runs as hasala-health, never nginx). P6 (mail metrics) and P7
  # (apex token pages) need the metrics listener and the website's live
  # checks; they join when those land.
  healthScript = pkgs.writeShellApplication {
    name = "hasala-health";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      fail=0
      note() { echo "hasala-health: $*"; fail=1; }
      code() { curl -s -o "$RUNTIME_DIRECTORY/body" -D "$RUNTIME_DIRECTORY/headers" -w '%{http_code}' --max-time 10 "$1" || true; }

      c=$(code ${lib.escapeShellArg "http://${loopback cfg.listen.port}/api/v1/healthz"})
      { [ "$c" = 200 ] && [ "$(jq -r .status "$RUNTIME_DIRECTORY/body" 2>/dev/null)" = ok ]; } || note "P1 local healthz answered $c"
      ${optionalString cfg.tunnel.enable ''
        c=$(code ${lib.escapeShellArg "https://${cfg.publicHostname}/api/v1/healthz"})
        { [ "$c" = 200 ] && [ "$(jq -r .status "$RUNTIME_DIRECTORY/body" 2>/dev/null)" = ok ]; } || note "P2 public healthz answered $c"
        for p in metrics admin/; do
          c=$(code ${lib.escapeShellArg "https://${cfg.publicHostname}/"}"$p")
          case "$c" in 403 | 404) ;; *) note "P3/P4 /$p answered $c (want 403 or 404)" ;; esac
        done
        c=$(code ${lib.escapeShellArg "https://${cfg.publicHostname}/api/v1/console"})
        [ "$c" = 404 ] || note "P9 /api/v1/console answered $c (want 404)"
        c=$(code ${lib.escapeShellArg cfg.monitoring.healthCheck.aasaUrl})
        if [ "$c" != 200 ] || grep -qi '^location:' "$RUNTIME_DIRECTORY/headers" \
          || ! grep -qi '^content-type: application/json' "$RUNTIME_DIRECTORY/headers"; then
          note "P5 AASA answered $c"
        elif ! jq -e --arg app ${lib.escapeShellArg appId} \
          '.webcredentials.apps == [$app] and ([.applinks.details[0].components[] | .["/"]] == ["/i/*"])' \
          "$RUNTIME_DIRECTORY/body" >/dev/null 2>&1; then
          note "P5 AASA body does not claim exactly webcredentials and /i/*"
        fi
      ''}
      ${optionalString cfg.console.enable ''
        c=$(code ${lib.escapeShellArg "http://${loopback cfg.console.metricsPort}/healthz"})
        { [ "$c" = 200 ] && [ "$(jq -r .status "$RUNTIME_DIRECTORY/body" 2>/dev/null)" = ok ]; } || note "P8 console healthz answered $c"
        for u in ${lib.escapeShellArg "http://127.0.0.1:${toString cfg.console.port}/"} ${lib.escapeShellArg "http://[::1]:${toString cfg.console.port}/"}; do
          rc=0
          curl -sg -o /dev/null --max-time 5 "$u" || rc=$?
          [ "$rc" = 7 ] || note "P10 $u: curl exit $rc, want 7 (the console's kernel rule must reset this user)"
        done
      ''}
      rm -f "$RUNTIME_DIRECTORY/body" "$RUNTIME_DIRECTORY/headers"

      # Alert on the second consecutive failing run only, then stay quiet until
      # a passing run (which posts one recovery notice).
      f="$STATE_DIRECTORY/failures"
      n=$(cat "$f" 2>/dev/null || echo 0)
      if [ "$fail" = 0 ]; then
        ${optionalString (cfg.monitoring.ntfyUrl != null) ''
          if [ "$n" -ge 2 ]; then
            curl -s --max-time 10 -d "hasala: recovered" ${lib.escapeShellArg cfg.monitoring.ntfyUrl} >/dev/null || true
          fi
        ''}
        echo 0 > "$f"
        exit 0
      fi
      n=$((n + 1)); echo "$n" > "$f"
      [ "$n" -eq 2 ] && exit 1
      exit 0
    '';
  };

  emailTokenCheck = pkgs.writeShellApplication {
    name = "hasala-email-token-check";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      # §5.9.4: fail when the send token is inactive or expires within 30
      # days. The token is read from the credential and never printed.
      code=$(curl -s -o "$RUNTIME_DIRECTORY/r.json" -w '%{http_code}' --max-time 20 \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$CREDENTIALS_DIRECTORY/token")") \
        ${lib.escapeShellArg "https://api.cloudflare.com/client/v4/accounts/${toString cfg.email.cloudflareAccountId}/tokens/verify"})
      status=$(jq -r '.result.status // "unknown"' "$RUNTIME_DIRECTORY/r.json")
      exp=$(jq -r '.result.expires_on // empty' "$RUNTIME_DIRECTORY/r.json")
      rm -f "$RUNTIME_DIRECTORY/r.json"
      echo "Cloudflare answered $code, token status $status, expires ''${exp:-never}"
      { [ "$code" = 200 ] && [ "$status" = active ]; } || exit 1
      if [ -n "$exp" ] && [ "$(date -d "$exp" +%s)" -lt "$(( $(date +%s) + 30*86400 ))" ]; then
        echo "email send token expires within 30 days: rotate it"; exit 1
      fi
    '';
  };

  backupCheck = pkgs.writeShellApplication {
    name = "hasala-backup-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.rclone
    ];
    text = ''
      # §5.8: freshness AND retention. Fails (→ onFailure) every day until fixed.
      fail=0
      last=$(cat "$STATE_DIRECTORY/last-success-daily" 2>/dev/null || echo 0)
      if [ $(( $(date +%s) - last )) -gt $(( 26 * 3600 )) ]; then
        echo "hasala-backup-check: no successful daily backup in 26 h"; fail=1
      fi
      old=$(find ${lib.escapeShellArg cfg.backup.dir} -maxdepth 1 -name 'hasala-*.age*' -mtime +29 | wc -l)
      if [ "$old" -gt 0 ]; then
        echo "hasala-backup-check: $old local backup file(s) older than 30 days"; fail=1
      fi
      ${optionalString cfg.backup.offsite.enable ''
        rc=(--config "$CREDENTIALS_DIRECTORY/rclone.conf" --cache-dir "$RUNTIME_DIRECTORY")
        if [ -z "$(rclone "''${rc[@]}" lsf --max-age 26h ${lib.escapeShellArg cfg.backup.offsite.remote})" ]; then
          echo "hasala-backup-check: nothing off-site in 26 h"; fail=1
        fi
        if [ -n "$(rclone "''${rc[@]}" lsf --min-age 30d ${lib.escapeShellArg cfg.backup.offsite.remote})" ]; then
          echo "hasala-backup-check: off-site copies older than 30 days"; fail=1
        fi
      ''}
      exit "$fail"
    '';
  };

  # --------------------------------------------------------------- assertions
  uuidRe = "[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}";
  matches = re: s: s != null && builtins.match re s != null;
  firewallPorts =
    config.networking.firewall.allowedTCPPorts
    ++ lib.concatMap (i: i.allowedTCPPorts or [ ]) (
      lib.attrValues config.networking.firewall.interfaces
    );
  hasalaPorts = [
    cfg.listen.port
    cfg.metrics.port
    cfg.tunnel.metricsPort
  ];
  consolePorts = [
    cfg.console.port
    cfg.console.metricsPort
  ];
  allPorts = hasalaPorts ++ optionals cfg.console.enable consolePorts;
  distinct = l: lib.length (lib.unique l) == lib.length l;

  forbiddenEnv =
    k:
    lib.any (p: lib.hasPrefix p k) [
      "HASALA_ADMIN_"
      "HASALA_CONSOLE_"
      "HASALA_ASC_"
      "HASALA_TESTFLIGHT_"
      "HASALA_DEV_"
      "HASALA_SMTP_"
      "HASALA_VAPID_"
    ]
    || lib.elem k [
      "HASALA_DICT_HMAC_KEY"
      "HASALA_CORPUS_DB"
    ]
    || lib.any (s: lib.hasSuffix s k) [
      "_KEY"
      "_TOKEN"
      "_SECRET"
      "_PASSWORD"
    ]
    || lib.hasInfix "SMTP" k
    || lib.hasInfix "VAPID" k
    || fixedEnv ? ${k};

  outlookPushValues = [
    cfg.outlook.notificationUrl
    cfg.outlook.lifecycleUrl
  ];
  # The Graph hook routes (WP3b). The subscription's URLs must be these, on
  # the tunnel's host: the ingress allowlist routes nothing else.
  outlookNotificationUrl = "https://${cfg.publicHostname}/hooks/outlook/graph";
  outlookLifecycleUrl = "https://${cfg.publicHostname}/hooks/outlook/graph/lifecycle";
  gmailPushValues = [
    cfg.gmail.pubsubTopic
    cfg.gmail.pubsubAudience
    cfg.gmail.pubsubServiceAccount
    cfg.gmail.pubsubSubscription
  ];
  allOrNone = vs: lib.all (v: v == null) vs || lib.all (v: v != null) vs;

  ingressRules = cfg.tunnel.ingress;
  expectedRules = ingressLib.rules {
    hostname = cfg.publicHostname;
    port = cfg.listen.port;
  };

  # M19: a virtual host "reaches the console" when any of its proxy text
  # names the console port on any host (127.0.0.1, localhost, [::1], ...) or
  # names an upstream that does. nginx is the one user the kernel rule lets
  # through, so every such vhost must be the tailnet-gated one.
  namesConsolePort =
    text: text != null && builtins.match ".*:${toString cfg.console.port}([^0-9].*)?" text != null;
  consoleUpstreams = lib.attrNames (
    lib.filterAttrs (_: u: lib.any namesConsolePort (lib.attrNames (u.servers or { }))) (
      config.services.nginx.upstreams or { }
    )
  );
  reachesConsole =
    text:
    namesConsolePort text
    || (text != null && lib.any (u: lib.hasInfix "://${u}" text) consoleUpstreams);
  nginxConsoleVhosts = lib.filterAttrs (
    _: vh:
    reachesConsole (vh.extraConfig or null)
    || lib.any (
      loc:
      reachesConsole (loc.proxyPass or null)
      || reachesConsole (loc.uwsgiPass or null)
      || reachesConsole (loc.extraConfig or null)
    ) (lib.attrValues (vh.locations or { }))
  ) config.services.nginx.virtualHosts;
  nginxGlobalReachesConsole = lib.any (o: reachesConsole (config.services.nginx.${o} or null)) [
    "config"
    "prependConfig"
    "eventsConfig"
    "commonHttpConfig"
    "httpConfig"
    "appendHttpConfig"
    "streamConfig"
    "appendConfig"
  ];
  authOff = text: text != null && builtins.match ".*auth_request[[:space:]]+off.*" text != null;
  locationGated =
    loc:
    lib.hasInfix "auth_request /auth;" (loc.extraConfig or "") && !authOff (loc.extraConfig or null);
  vhostGated =
    vh:
    !authOff (vh.extraConfig or null)
    && lib.all locationGated (
      lib.attrValues (lib.filterAttrs (n: _: n != "/auth") (vh.locations or { }))
    );

  limitOption =
    default: description:
    mkOption {
      type = types.str;
      inherit default description;
    };

  portOption =
    default: description:
    mkOption {
      type = types.port;
      inherit default description;
    };

  nullStr =
    description:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description;
    };

  # Spec 05 §5.1, M22 (review 2 F-22): a string, never types.path, so a Nix
  # path literal (which would copy the secret into the world-readable store)
  # is a type error, and M22 refuses any string under the store.
  secretPath =
    description:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      description =
        description
        + " An absolute path to a root-only file outside the Nix store (a string, never a Nix path literal; M22). It reaches the unit through LoadCredential=.";
    };

  secretFiles = {
    "apns.keyFile" = cfg.apns.keyFile;
    inherit (cfg) mailboxRouteKeyFile authKeyFile saltKeyFile;
    "email.apiTokenFile" = cfg.email.apiTokenFile;
    "web.turnstile.secretFile" = cfg.web.turnstile.secretFile;
    "asc.keyFile" = cfg.asc.keyFile;
    "tunnel.credentialsFile" = cfg.tunnel.credentialsFile;
    "backup.offsite.rcloneConfigFile" = cfg.backup.offsite.rcloneConfigFile;
  };
  outsideStore =
    p:
    p == null
    || (lib.hasPrefix "/" p && !lib.hasPrefix "${builtins.storeDir}/" p && p != builtins.storeDir);
  secretsInStore = lib.attrNames (lib.filterAttrs (_: p: !outsideStore p) secretFiles);
in
{
  options.services.hasala = {
    enable = mkEnableOption "the Hasala QA backend (spec 05)";

    package = mkOption {
      type = types.package;
      default = hp.hasalad;
      defaultText = lib.literalExpression "hasala.packages.\${system}.hasalad";
      description = "The hasalad package.";
    };

    listen.address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "API bind address. Asserted to be 127.0.0.1 (M1): cloudflared is the only ingress.";
    };
    listen.port = portOption 8471 "API port.";
    metrics.port = portOption 9471 "Prometheus metrics port, always on 127.0.0.1.";

    publicHostname = mkOption {
      type = types.str;
      default = "api.hasala.app";
      description = "The API's public host name: the tunnel's only ingress host.";
    };
    rpId = mkOption {
      type = types.str;
      default = "hasala.app";
      description = "WebAuthn relying party id; a suffix of publicHostname.";
    };
    rpOrigins = mkOption {
      type = types.listOf types.str;
      default = [ "https://hasala.app" ];
      description = "WebAuthn origins.";
    };

    apns = {
      keyFile = secretPath "The APNs .p8 signing key.";
      keyId = nullStr "APNs key id (not secret).";
      teamId = mkOption {
        type = types.str;
        default = "8CFG28JHP3";
        description = "Apple team id (public: it is in the AASA file).";
      };
      topic = mkOption {
        type = types.str;
        default = "app.hasala.ios";
        description = "APNs topic (the bundle id).";
      };
      environments = mkOption {
        type = types.listOf (
          types.enum [
            "production"
            "sandbox"
          ]
        );
        default = [
          "production"
          "sandbox"
        ];
        description = "APNs environments the server accepts device tokens for.";
      };
    };

    google.iosClientId = nullStr "The iOS OAuth client id (<n>-<x>.apps.googleusercontent.com), the audience of the app's Google ID token. With mailboxRouteKeyFile it is the [gmail] mailbox link (M8a): the link routes are mounted, and without gmail.* the app fetches mail without wakes (no watch topic, no Pub/Sub hook).";
    # The Pub/Sub push: all four or none, and only with the link (M8b).
    gmail = {
      pubsubTopic = nullStr "projects/<P>/topics/<topic>; offered to the app as the watch topic. Part of the Pub/Sub push (M8b).";
      pubsubAudience = nullStr "The push subscription's OIDC audience (the hook URL). Part of the Pub/Sub push (M8b).";
      pubsubServiceAccount = nullStr "The push subscription's service account email (<name>@<P>.iam.gserviceaccount.com); the hook refuses a push token whose email differs. Part of the Pub/Sub push (M8b).";
      pubsubSubscription = nullStr "projects/<P>/subscriptions/<name>. Part of the Pub/Sub push (M8b).";
    };
    # The Graph change-notification push: both or none, and only with the
    # link (M8d).
    outlook = {
      clientId = nullStr "The Entra app's client id (a UUID; not secret, it ships in the app), the audience of the app's Microsoft ID token (personal accounts only). With mailboxRouteKeyFile it is the [outlook] mailbox link (M8c): the link routes accept provider \"outlook\", and without the URLs the app fetches mail without wakes (no Graph subscription, no hook).";
      notificationUrl = nullStr "The Graph subscription's notificationUrl, exactly https://<publicHostname>/hooks/outlook/graph; offered to the app in /api/v1/meta. Part of the Graph push (M8d).";
      lifecycleUrl = nullStr "The Graph subscription's lifecycleNotificationUrl, exactly https://<publicHostname>/hooks/outlook/graph/lifecycle; offered to the app in /api/v1/meta. Part of the Graph push (M8d).";
    };
    mailboxRouteKeyFile = secretPath "The mailbox route key (64 lowercase hex), shared by both providers; with google.iosClientId it is the [gmail] mailbox link (M8a), with outlook.clientId the [outlook] one (M8c), and it needs at least one of them.";
    authKeyFile = secretPath "auth_key (spec 01 §4.11, 64 lowercase hex). Required with the tunnel (M12).";
    saltKeyFile = secretPath "salt_key (spec 01 §4.11, 64 lowercase hex): keys only the public password salt, generated once and never rotated; a different key from auth_key. Required with the tunnel (M12): without both key files serve mounts no signup, password, recovery, reset, email-change or freeze route.";

    email = {
      cloudflareAccountId = nullStr "The Cloudflare account that sends mail (32 lowercase hex; not secret).";
      apiTokenFile = secretPath "The Cloudflare Email Sending token (send-only).";
      from = mkOption {
        type = types.str;
        default = "no-reply@hasala.app";
        description = "Sender address; asserted to be at rpId.";
      };
      fromName = mkOption {
        type = types.str;
        default = "Hasala";
        description = "Sender display name.";
      };
      replyTo = mkOption {
        type = types.str;
        default = "support@hasala.app";
        description = "Reply-To address; asserted to be at rpId.";
      };
    };

    passwordHashConcurrency = mkOption {
      type = types.int;
      default = 1;
      description = "Concurrent server-side PBKDF2 verifications (1 or 2, M12).";
    };
    headroomFloorBytes = mkOption {
      type = types.ints.positive;
      default = 17179869184;
      description = "Free bytes below which the server refuses durable writes.";
    };
    minIosBuild = mkOption {
      type = types.ints.unsigned;
      default = 0;
      example = 26102911530;
      description = "Oldest iOS CFBundleVersion, dots removed, that the server serves; older builds get 426 and the app asks for an update. 0 serves every build.";
    };
    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra non-secret environment for hasalad serve (asserted, M4).";
    };

    database = {
      package = mkOption {
        type = types.package;
        default = hp.postgresql;
        defaultText = lib.literalExpression "hasala.packages.\${system}.postgresql";
        description = "PostgreSQL for Hasala's own cluster. Its major version selects the data directory.";
      };
      settings = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.str
            types.int
            types.bool
          ]
        );
        default = { };
        description = "Merged over the module's postgresql.conf; no socket, auth-file or log_* keys (M9).";
      };
    };

    tunnel = {
      enable = mkEnableOption "the cloudflared tunnel for publicHostname";
      id = mkOption {
        type = types.str;
        default = "";
        description = "The tunnel's UUID (not secret: it is in the public CNAME).";
      };
      credentialsFile = secretPath "The tunnel credentials JSON.";
      metricsPort = portOption 9472 "cloudflared metrics port, on 127.0.0.1.";
      ingress = mkOption {
        type = types.listOf (types.attrsOf types.str);
        internal = true;
        default = expectedRules;
        description = "The ingress rules (spec 05 §7.3). Internal: asserted equal to the module's own (M6).";
      };
      renderedConfig = mkOption {
        type = types.str;
        internal = true;
        readOnly = true;
        default = ingressLib.render {
          tunnelId = cfg.tunnel.id;
          credentialsFile = "/run/credentials/cloudflared-hasala.service/tunnel.json";
          metricsPort = cfg.tunnel.metricsPort;
          rules = cfg.tunnel.ingress;
        };
        description = "The exact cloudflared config the tunnel runs; the ingress lint reads it.";
      };
    };

    backup = {
      enable = mkEnableOption "encrypted daily backups";
      dir = mkOption {
        type = types.str;
        default = "/var/lib/hasala-backup/dumps";
        description = "Where the age-encrypted dumps go (0700 hasala-backup).";
      };
      ageRecipients = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "age X25519 recipients (native, no plugins). No identity is ever on the host.";
      };
      onCalendar = mkOption {
        type = types.str;
        default = "*-*-* 03:15:00";
        description = "When the daily backup runs (local time).";
      };
      retentionDays = mkOption {
        type = types.ints.positive;
        default = 29;
        description = "Local copies are deleted once this many days old (≤ 29, M13).";
      };
      offsite = {
        enable = mkEnableOption "the off-site copy (rclone)";
        rcloneConfigFile = secretPath "rclone.conf for the off-site remote.";
        remote = mkOption {
          type = types.str;
          default = "";
          description = "rclone remote:path, e.g. r2:<bucket>/daily.";
        };
      };
    };

    monitoring = {
      prometheus = mkOption {
        type = types.bool;
        default = true;
        description = "Add scrape jobs when services.prometheus is enabled.";
      };
      onFailure = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "OnFailure= units for every Hasala unit, e.g. [ \"notify-failure@%n.service\" ].";
      };
      ntfyUrl = nullStr "Where hasala-health posts its recovery notice, and hasalad its early-access notice.";
      earlyAccessNotice = mkEnableOption "an ntfy notice to monitoring.ntfyUrl for each new early-access request (a waitlist entry that confirmed its address, now waiting in the console). It names nobody; it opens the console when that is enabled";
      healthCheck.enable = mkEnableOption "the hasala-health probes (every 2 minutes)";
      healthCheck.aasaUrl = mkOption {
        type = types.str;
        default = "https://hasala.app/.well-known/apple-app-site-association";
        description = "The AASA URL probe P5 reads.";
      };
    };

    web = {
      baseUrl = mkOption {
        type = types.str;
        default = "https://hasala.app";
        description = "Base of every link in emails.";
      };
      origins = mkOption {
        type = types.listOf types.str;
        default = [ "https://hasala.app" ];
        description = "CORS origins for the website's public routes; [ ] = off.";
      };
      waitlistDoneUrl = mkOption {
        type = types.str;
        default = "https://hasala.app/joined";
        description = "303 target of a script-free waitlist form.";
      };
      turnstile.secretFile = secretPath "The optional Turnstile secret.";
    };

    console = {
      enable = mkEnableOption "the operator console (spec 07; tailnet only, behind the host's nginx)";
      port = portOption 8472 "Console port, always on 127.0.0.1.";
      metricsPort = portOption 9473 "Console metrics and /healthz port, always on 127.0.0.1.";
      host = nullStr "The console's host name (required when enabled; never under rpId, M18).";
      logins = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Tailnet logins allowed in; non-empty when enabled (M17).";
      };
      tailnet = nullStr "The tailnet name the identity header must carry (required when enabled).";
      restrictToUser = mkOption {
        type = types.str;
        default = "nginx";
        description = "The only user the kernel rule lets connect to the console port (§5.14).";
      };
    };

    asc = {
      enable = mkEnableOption "App Store Connect automation in the console (else manual TestFlight mode)";
      keyFile = secretPath "The dedicated App Manager .p8 key; reaches hasala-console only.";
      keyId = nullStr "The key's id (not secret).";
      keyKind = mkOption {
        type = types.enum [
          "individual"
          "team"
        ];
        default = "team";
        description = "Individual or team key (spec 07 §7.2).";
      };
      issuerId = nullStr "The team key issuer id (a UUID; not secret).";
      refusedKeyIds = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Key ids that must never run on this host (the owner's upload key, PQ-16; M20).";
      };
      bundleId = mkOption {
        type = types.str;
        default = "app.hasala.ios";
        description = "The app's bundle id.";
      };
      betaGroup = mkOption {
        type = types.str;
        default = "Hasala Beta";
        description = "The external TestFlight group.";
      };
      testerLimit = mkOption {
        type = types.ints.between 1 10000;
        default = 10000;
        description = "Apple's external tester cap.";
      };
    };

    hardening.inaccessiblePaths = mkOption {
      type = types.listOf types.str;
      default = [
        "-/var/lib/postgresql"
        "-/run/postgresql"
        "-/run/secrets"
      ];
      description = "InaccessiblePaths= of every Hasala unit. A host appends its neighbours' state.";
    };
    hardening.distrustedCARoots = mkOption {
      type = types.listOf types.str;
      default = [
        "Comodo AAA Services root"
        "emSign ECC Root CA - G3"
      ];
      description = "Root certificates, by their label in the system CA bundle, that the host stops trusting (security.pki.caCertificateBlacklist; system-wide). A CA distrust stopgap until the pinned nixpkgs ships the fixed CA bundle.";
    };

    limits = {
      hasaladMemoryHigh = limitOption "512M" "hasalad MemoryHigh=.";
      hasaladMemoryMax = limitOption "768M" "hasalad MemoryMax=.";
      postgresMemoryHigh = limitOption "896M" "hasala-postgresql MemoryHigh=.";
      postgresMemoryMax = limitOption "1G" "hasala-postgresql MemoryMax=.";
      tunnelMemoryMax = limitOption "256M" "cloudflared-hasala MemoryMax=.";
      consoleMemoryHigh = limitOption "192M" "hasala-console MemoryHigh=.";
      consoleMemoryMax = limitOption "256M" "hasala-console MemoryMax=.";
      backupMemoryMax = limitOption "512M" "hasala-backup* MemoryMax=.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # ------------------------------------------------------------- §5.12
      assertions =
        let
          a = n: assertion: message: {
            inherit assertion;
            message = "services.hasala ${n}: ${message}";
          };
        in
        [
          (a "M1" (
            cfg.listen.address == "127.0.0.1"
          ) "listen.address must be 127.0.0.1: cloudflared and the health probe reach the API there.")
          (a "M2" (distinct hasalaPorts) "listen.port, metrics.port and tunnel.metricsPort must differ.")
          (a "M3" (
            !lib.any (p: lib.elem p firewallPorts) hasalaPorts
          ) "never open a Hasala port in the firewall.")
          (a "M4" (!lib.any forbiddenEnv (lib.attrNames cfg.extraEnvironment))
            "extraEnvironment may not carry a secret-like, admin, console, App Store Connect, TestFlight, dev, SMTP, VAPID, dictionary or corpus key, nor override a fixed key."
          )
          (a "M5"
            (
              matches "[a-z0-9.-]+" cfg.publicHostname
              && lib.hasSuffix ".${cfg.rpId}" cfg.publicHostname
              && (!cfg.tunnel.enable || matches uuidRe cfg.tunnel.id)
              && (!cfg.tunnel.enable || cfg.tunnel.credentialsFile != null)
            )
            "publicHostname must be a plain host name under rpId, and the tunnel needs a UUID id and a credentials file."
          )
          (a "M6" (ingressRules == expectedRules)
            "the tunnel ingress must be exactly the API rule (publicHostname, the path allowlist, 127.0.0.1:listen.port) and a 404 catch-all."
          )
          (a "M7"
            (
              (
                !cfg.backup.enable
                || (
                  cfg.backup.ageRecipients != [ ]
                  && lib.all (matches "age1[02-9ac-hj-np-z]{58}") cfg.backup.ageRecipients
                )
              )
              && (!cfg.backup.offsite.enable || cfg.backup.enable)
              && (
                !cfg.backup.offsite.enable
                || (cfg.backup.offsite.rcloneConfigFile != null && cfg.backup.offsite.remote != "")
              )
            )
            "backups need native age X25519 recipients; off-site needs backups, an rclone config and a remote."
          )
          (a "M8a"
            (
              (gmailLinkOn -> cfg.mailboxRouteKeyFile != null)
              && (cfg.mailboxRouteKeyFile != null -> mailboxRouteKeyOn)
              && (!gmailLinkOn || lib.hasSuffix ".apps.googleusercontent.com" cfg.google.iosClientId)
            )
            "the [gmail] mailbox link is google.iosClientId (a Google client id, <n>-<x>.apps.googleusercontent.com) and mailboxRouteKeyFile; mailboxRouteKeyFile needs google.iosClientId or outlook.clientId."
          )
          (a "M8b"
            (
              allOrNone gmailPushValues
              && (gmailPushOn -> gmailLinkOn)
              && (
                cfg.gmail.pubsubServiceAccount == null
                || matches "[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com" cfg.gmail.pubsubServiceAccount
              )
            )
            "the [gmail] Pub/Sub push (gmail.pubsubTopic, pubsubAudience, pubsubServiceAccount, pubsubSubscription) is all or nothing, needs the mailbox link (M8a), and pubsubServiceAccount is <name>@<P>.iam.gserviceaccount.com."
          )
          (a "M8c"
            (
              (outlookLinkOn -> cfg.mailboxRouteKeyFile != null)
              && (!outlookLinkOn || matches uuidRe cfg.outlook.clientId)
            )
            "the [outlook] mailbox link is outlook.clientId (the Entra app's client id, a lowercase UUID) and mailboxRouteKeyFile."
          )
          (a "M8d"
            (
              allOrNone outlookPushValues
              && (outlookPushOn -> outlookLinkOn)
              && (cfg.outlook.notificationUrl == null || cfg.outlook.notificationUrl == outlookNotificationUrl)
              && (cfg.outlook.lifecycleUrl == null || cfg.outlook.lifecycleUrl == outlookLifecycleUrl)
            )
            "the [outlook] Graph push (outlook.notificationUrl, outlook.lifecycleUrl) is both or neither, needs the mailbox link (M8c), and the URLs are exactly ${outlookNotificationUrl} and ${outlookLifecycleUrl}."
          )
          (a "M9" (!lib.any pgLib.forbiddenSetting (lib.attrNames cfg.database.settings))
            "database.settings may not set listen_addresses, unix_socket_*, hba_file, ident_file or any log_* key."
          )
          (a "M10" (
            !(config.services.nginx.virtualHosts ? ${cfg.publicHostname})
          ) "the API is public through its tunnel only, never through the host's nginx.")
          (a "M11"
            (
              (cfg.email.cloudflareAccountId == null) == (cfg.email.apiTokenFile == null)
              && (cfg.email.cloudflareAccountId == null || matches "[0-9a-f]{32}" cfg.email.cloudflareAccountId)
              && lib.hasSuffix "@${cfg.rpId}" cfg.email.from
              && lib.hasSuffix "@${cfg.rpId}" cfg.email.replyTo
              && (!cfg.tunnel.enable || emailOn)
            )
            "email.cloudflareAccountId (32 hex) and email.apiTokenFile are both set or both null, required with the tunnel; email.from and email.replyTo must be at rpId."
          )
          (a "M12"
            (
              (!cfg.tunnel.enable || (cfg.authKeyFile != null && cfg.saltKeyFile != null))
              && (cfg.authKeyFile == null || cfg.saltKeyFile == null || cfg.authKeyFile != cfg.saltKeyFile)
              && lib.elem cfg.passwordHashConcurrency [
                1
                2
              ]
            )
            "the tunnel needs authKeyFile and saltKeyFile, two different files; passwordHashConcurrency is 1 or 2."
          )
          (a "M13" (
            cfg.backup.retentionDays <= 29
          ) "backup.retentionDays is at most 29 (the 30-day disclosure is a hard bound).")
          (a "M14" (!cfg.console.enable || distinct (hasalaPorts ++ consolePorts))
            "console.port, console.metricsPort, listen.port, metrics.port and tunnel.metricsPort must all differ."
          )
          (a "M15" (
            !lib.any (p: lib.elem p firewallPorts) consolePorts
          ) "never open a console port in the firewall; nginx reaches it on loopback.")
          (a "M16" (
            !lib.any (p: lib.hasInfix ":${toString p}" cfg.tunnel.renderedConfig) (
              consolePorts ++ [ cfg.metrics.port ]
            )
          ) "the tunnel ingress may never name a console or metrics port.")
          (a "M17" (
            !cfg.console.enable
            || (
              cfg.console.logins != [ ]
              && lib.all (matches "[^[:space:]@*]+@[^[:space:]@*]+") cfg.console.logins
              && cfg.console.host != null
              && cfg.console.tailnet != null
            )
          ) "the console needs host, tailnet and a non-empty list of logins (no \"any tailnet member\").")
          (a "M18" (
            !cfg.console.enable
            || (
              cfg.console.host != cfg.publicHostname
              && cfg.console.host != cfg.rpId
              && !lib.hasSuffix ".${cfg.rpId}" (toString cfg.console.host)
            )
          ) "the console never lives on a name under rpId.")
          (a "M19"
            (
              !(cfg.console.enable && config.services.nginx.enable)
              || (
                let
                  names = lib.attrNames nginxConsoleVhosts;
                  vh = nginxConsoleVhosts.${lib.head names};
                in
                !nginxGlobalReachesConsole
                && lib.length names == 1
                && lib.elem (lib.head names) (config.services.nginx.tailscaleAuth.virtualHosts or [ ])
                && vh.locations ? "/"
                && vhostGated vh
              )
            )
            "exactly one nginx virtual host may proxy to the console, it must be in services.nginx.tailscaleAuth.virtualHosts, every location of it other than /auth must run auth_request /auth (never auth_request off), and no http, stream or top-level nginx config may name the console port."
          )
          (a "M20"
            (
              (
                !cfg.asc.enable
                || (
                  cfg.console.enable
                  && cfg.asc.keyFile != null
                  && matches "[A-Z0-9]{10}" cfg.asc.keyId
                  && cfg.asc.refusedKeyIds != [ ]
                  && !lib.elem cfg.asc.keyId cfg.asc.refusedKeyIds
                  && matches uuidRe cfg.asc.issuerId
                )
              )
              && !lib.any (
                k:
                lib.hasPrefix "HASALA_CONSOLE_" k
                || lib.hasPrefix "HASALA_ASC_" k
                || lib.hasPrefix "HASALA_TESTFLIGHT_" k
              ) (lib.attrNames (fixedEnv // cfg.extraEnvironment))
            )
            "App Store Connect needs the console, the dedicated key (file, 10-character id not in a non-empty refusedKeyIds) and a UUID issuer; serve never gets a console, ASC or TestFlight variable."
          )
          (a "M21"
            (!cfg.console.enable || (config.networking.firewall.enable && !config.networking.nftables.enable))
            "the console's kernel rule lives in the iptables firewall: it must be enabled, and an nftables host would silently drop the rule."
          )
          (a "M22" (secretsInStore == [ ])
            "every secret-file option is an absolute path outside ${builtins.storeDir} (a secret in the store is world-readable); offending: ${concatStringsSep ", " secretsInStore}."
          )
          (a "M23" (
            !cfg.monitoring.earlyAccessNotice || cfg.monitoring.ntfyUrl != null
          ) "monitoring.earlyAccessNotice posts to monitoring.ntfyUrl: set it too.")
        ];

      # ------------------------------------------------------------- §5.11
      systemd.targets.hasala = {
        description = "Hasala QA backend";
        wantedBy = [ "multi-user.target" ];
      };
      systemd.slices.hasala = {
        description = "Hasala QA";
        sliceConfig = {
          MemoryHigh = "1792M";
          MemoryMax = "2G";
          CPUWeight = 50;
          IOWeight = 50;
          CPUQuota = "400%";
          TasksMax = 1024;
        };
      };

      users.groups = lib.genAttrs (
        [
          "hasala"
          "hasala-migrate"
          "hasala-backup"
          "hasala-pg"
          "hasala-db"
          "hasala-ledger"
        ]
        ++ optional cfg.console.enable "hasala-console"
      ) (_: { });
      users.users = {
        hasala = {
          isSystemUser = true;
          group = "hasala";
          extraGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
        };
        hasala-migrate = {
          isSystemUser = true;
          group = "hasala-migrate";
          extraGroups = [ "hasala-db" ];
        };
        hasala-backup = {
          isSystemUser = true;
          group = "hasala-backup";
          extraGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
        };
        hasala-pg = {
          isSystemUser = true;
          group = "hasala-pg";
          extraGroups = [ "hasala-db" ];
          home = pgRoot;
        };
      }
      // optionalAttrs cfg.console.enable {
        hasala-console = {
          isSystemUser = true;
          group = "hasala-console";
          extraGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
        };
      };

      # §5.8.1: setgid, so every file in it keeps the hasala-ledger group.
      systemd.tmpfiles.settings.hasala-ledger = {
        ${ledgerDir}.d = {
          user = "hasala";
          group = "hasala-ledger";
          mode = "2770";
        };
        "${ledgerDir}/purged".f = {
          user = "hasala";
          group = "hasala-ledger";
          mode = "0660";
        };
        "${ledgerDir}/purged.lock".f = {
          user = "hasala";
          group = "hasala-ledger";
          mode = "0660";
        };
      };
      systemd.tmpfiles.settings.hasala-maintenance.${maintenanceLock}.f = {
        user = "root";
        group = "hasala-db";
        mode = "0440";
      };

      environment.systemPackages = [ hasalaAdmin ];
      security.pki.caCertificateBlacklist = cfg.hardening.distrustedCARoots;
      services.journald.extraConfig = lib.mkDefault "SystemMaxUse=1G";

      # ----------------------------------------------------------- §5.3.6
      systemd.services.hasala-postgresql = {
        description = "Hasala PostgreSQL ${pgMajor} (own cluster, unix socket only)";
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        after = [ "local-fs.target" ];
        onFailure = cfg.monitoring.onFailure;
        path = [ pg ];
        # A major-version change can never silently start an empty cluster:
        # the data directory is named after the major, and an older one present
        # stops the start until it is dumped and restored.
        preStart = ''
          set -euo pipefail
          shopt -s nullglob
          for v in ${pgRoot}/*/PG_VERSION; do
            d="''${v%/PG_VERSION}"
            if [ "$d" != "${dataDir}" ] && [ ! -e ${pgRoot}/ALLOW_MAJOR_CHANGE ]; then
              echo "hasala-postgresql: a cluster exists at $d but this build runs PostgreSQL ${pgMajor}." >&2
              echo "Dump and restore first (spec 05 §11.7, 'PostgreSQL major upgrade')." >&2
              exit 1
            fi
          done
          if [ ! -s ${dataDir}/PG_VERSION ]; then
            if [ -n "$(ls -A ${dataDir})" ]; then
              echo "hasala-postgresql: ${dataDir} is not empty but has no PG_VERSION; refusing initdb" >&2
              exit 1
            fi
            initdb --pgdata=${dataDir} --username=hasala_su --auth-local=peer --auth-host=reject \
              --encoding=UTF8 --locale=C --locale-provider=builtin --builtin-locale=C.UTF-8 \
              --data-checksums
          fi
        '';
        serviceConfig = hardening // {
          Type = "notify";
          User = "hasala-pg";
          Group = "hasala-db";
          ExecStart = "${pg}/bin/postgres -D ${dataDir} -c config_file=${pgConf}";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          KillMode = "mixed";
          KillSignal = "SIGINT";
          TimeoutSec = 120;
          StateDirectory = [
            "hasala-postgresql"
            "hasala-postgresql/${pgMajor}"
          ];
          StateDirectoryMode = "0700";
          RuntimeDirectory = "hasala-postgresql";
          RuntimeDirectoryMode = "0750";
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          IPAddressDeny = "any";
          MemoryHigh = cfg.limits.postgresMemoryHigh;
          MemoryMax = cfg.limits.postgresMemoryMax;
          CPUQuota = "200%";
          TasksMax = 128;
          LimitNOFILE = 4096;
        };
        restartTriggers = [ pgConf ];
      };

      # ----------------------------------------------------------- §5.3.7
      systemd.services.hasala-db-setup = {
        description = "Hasala database roles and database (idempotent)";
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        requires = [ "hasala-postgresql.service" ];
        after = [ "hasala-postgresql.service" ];
        restartTriggers = [ setupSql ];
        onFailure = cfg.monitoring.onFailure;
        serviceConfig = hardening // {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "hasala-pg";
          Group = "hasala-db";
          ExecStart = "${pg}/bin/psql --no-psqlrc -v ON_ERROR_STOP=1 --host=${socketDir} --username=hasala_su --dbname=postgres --file=${setupSql}";
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          IPAddressDeny = "any";
        };
      };

      # ------------------------------------------------------------- §5.4
      # No RemainAfterExit: every start of hasalad (or the console) enqueues a
      # fresh run, so migrations always run first, as the schema owner.
      systemd.services.hasala-migrate = {
        description = "Hasala schema migrations (as hasala_migrate)";
        requires = [
          "hasala-db-setup.service"
        ]
        ++ optional cfg.backup.enable "hasala-backup-premigrate.service";
        after = [
          "hasala-db-setup.service"
        ]
        ++ optional cfg.backup.enable "hasala-backup-premigrate.service";
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        # Spec 02 §5.5: migrate never reads HASALA_PG_DSN.
        environment = {
          HASALA_MIGRATE_DSN = migrateDSN;
          TZ = "UTC";
        };
        serviceConfig = hardening // {
          Type = "oneshot";
          User = "hasala-migrate";
          Group = "hasala-migrate";
          SupplementaryGroups = [ "hasala-db" ];
          ExecStart = "${pkgs.util-linux}/bin/flock --no-fork ${maintenanceLock} ${hasalad} migrate";
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          IPAddressDeny = "any";
          TimeoutStartSec = "10min";
        };
      };

      systemd.services.hasala-purge-replay = {
        description = "Hasala purge ledger replay (spec 02 §15.5)";
        requires = [
          "hasala-migrate.service"
          "hasala-postgresql.service"
        ];
        after = [
          "hasala-migrate.service"
          "hasala-postgresql.service"
        ];
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        environment = {
          HASALA_PG_DSN = runtimeDSN;
          HASALA_PURGE_LEDGER_PATH = "${ledgerDir}/purged";
          TZ = "UTC";
        };
        serviceConfig = hardening // {
          Type = "oneshot";
          User = "hasala";
          Group = "hasala";
          SupplementaryGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
          ExecStart = "${hasalad} purge-user --replay-ledger";
          ReadWritePaths = [ ledgerDir ];
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          IPAddressDeny = "any";
          TimeoutStartSec = "10min";
        };
      };

      # ------------------------------------------------------------- §5.5
      systemd.services.hasalad = {
        description = "Hasala API (blind sync server)";
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        requires = [
          "hasala-migrate.service"
          "hasala-purge-replay.service"
          "hasala-postgresql.service"
        ];
        after = [
          "hasala-migrate.service"
          "hasala-purge-replay.service"
          "hasala-postgresql.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        onFailure = cfg.monitoring.onFailure;
        environment = fixedEnv // cfg.extraEnvironment;
        serviceConfig = hardening // {
          Type = "exec";
          User = "hasala";
          Group = "hasala";
          SupplementaryGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
          ExecStart = "${hasalad} serve";
          LoadCredential = hasaladCredentials;
          # serve never sees the console's credentials (App Store Connect key).
          InaccessiblePaths = hardening.InaccessiblePaths ++ [ "-/run/credentials/hasala-console.service" ];
          StateDirectory = "hasala";
          StateDirectoryMode = "0700";
          ReadWritePaths = [ ledgerDir ];
          Restart = "on-failure";
          RestartSec = "5s";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressDeny = denyLanAndTailnet;
          MemoryHigh = cfg.limits.hasaladMemoryHigh;
          MemoryMax = cfg.limits.hasaladMemoryMax;
          CPUQuota = "200%";
          TasksMax = 256;
          LimitNOFILE = 8192;
        };
        unitConfig = {
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
      };

      # --------------------------------------------------------- §5.9.1
      services.prometheus.scrapeConfigs =
        mkIf (cfg.monitoring.prometheus && config.services.prometheus.enable)
          (
            [
              {
                job_name = "hasala";
                static_configs = [ { targets = [ (loopback cfg.metrics.port) ]; } ];
              }
            ]
            ++ optional cfg.tunnel.enable {
              job_name = "hasala-cloudflared";
              static_configs = [ { targets = [ (loopback cfg.tunnel.metricsPort) ]; } ];
            }
            ++ optional cfg.console.enable {
              job_name = "hasala-console";
              static_configs = [ { targets = [ (loopback cfg.console.metricsPort) ]; } ];
            }
          );
    }

    # --------------------------------------------------------------- §5.6
    (mkIf cfg.tunnel.enable {
      systemd.services.cloudflared-hasala = {
        description = "Cloudflare Tunnel for ${cfg.publicHostname} (to ${loopback cfg.listen.port} only)";
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        after = [
          "network-online.target"
          "hasalad.service"
        ];
        wants = [ "network-online.target" ];
        onFailure = cfg.monitoring.onFailure;
        restartTriggers = [ tunnelConfig ];
        serviceConfig = hardening // {
          Type = "notify";
          User = "hasala-tunnel";
          Group = "hasala-tunnel";
          ExecStart = "${hp.cloudflared}/bin/cloudflared tunnel --no-autoupdate --config ${tunnelConfig} run";
          LoadCredential = [ "tunnel.json:${cfg.tunnel.credentialsFile}" ];
          Restart = "always";
          RestartSec = "5s";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
            "AF_NETLINK"
          ];
          IPAddressDeny = denyLanAndTailnet;
          MemoryMax = cfg.limits.tunnelMemoryMax;
          CPUQuota = "100%";
          TasksMax = 128;
        };
      };

      users.groups.hasala-tunnel = { };
      users.users.hasala-tunnel = {
        isSystemUser = true;
        group = "hasala-tunnel";
      };

      networking.firewall.extraCommands = ''
        iptables -w -N hasala-api-out 2>/dev/null || true
        iptables -w -F hasala-api-out
        iptables -w -A hasala-api-out -m owner --uid-owner 0 -j RETURN
        iptables -w -A hasala-api-out -m owner --uid-owner hasala-tunnel -j RETURN
        ${optionalString cfg.monitoring.healthCheck.enable "iptables -w -A hasala-api-out -m owner --uid-owner hasala-health -j RETURN"}
        iptables -w -A hasala-api-out -p tcp -j REJECT --reject-with tcp-reset
        iptables -w -C OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.listen.port} -j hasala-api-out 2>/dev/null \
          || iptables -w -I OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.listen.port} -j hasala-api-out
      '';
      networking.firewall.extraStopCommands = ''
        iptables -w -D OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.listen.port} -j hasala-api-out 2>/dev/null || true
        iptables -w -F hasala-api-out 2>/dev/null || true
        iptables -w -X hasala-api-out 2>/dev/null || true
      '';
    })

    # ------------------------------------------------------- §5.13, §5.14
    (mkIf cfg.console.enable {
      systemd.services.hasala-console = {
        description = "Hasala operator console (tailnet only, through the host's nginx)";
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        requires = [
          "hasala-migrate.service"
          "hasala-purge-replay.service"
          "hasala-postgresql.service"
        ];
        after = [
          "hasala-migrate.service"
          "hasala-purge-replay.service"
          "hasala-postgresql.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        onFailure = cfg.monitoring.onFailure;
        environment = consoleEnv;
        serviceConfig = hardening // {
          Type = "exec";
          User = "hasala-console";
          Group = "hasala-console";
          SupplementaryGroups = [
            "hasala-db"
            "hasala-ledger"
          ];
          ExecStart = "${hasalad} console";
          LoadCredential = optional cfg.asc.enable "asc-key.p8:${cfg.asc.keyFile}";
          # The console never sees serve's credentials (auth key, email token,
          # APNs key, route key, Turnstile secret).
          InaccessiblePaths = hardening.InaccessiblePaths ++ [ "-/run/credentials/hasalad.service" ];
          ReadWritePaths = [ ledgerDir ];
          Restart = "on-failure";
          RestartSec = "5s";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressDeny = denyLanAndTailnet;
          MemoryHigh = cfg.limits.consoleMemoryHigh;
          MemoryMax = cfg.limits.consoleMemoryMax;
          CPUQuota = "100%";
          TasksMax = 64;
        };
        unitConfig = {
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
      };

      # Only restrictToUser (the host's nginx) may open a TCP connection to the
      # console port; every other local process, root included, gets a reset.
      # It filters locally generated packets to one loopback port and opens
      # nothing. The metrics port is not filtered (it serves no console route).
      # The ip6tables twin covers ::1 (spec 05 §5.14, review 2 F-11): the
      # console always listens on 127.0.0.1, so it is defence in depth.
      networking.firewall.extraCommands = ''
        iptables -w -N hasala-console-out 2>/dev/null || true
        iptables -w -F hasala-console-out
        iptables -w -A hasala-console-out -m owner --uid-owner ${cfg.console.restrictToUser} -j RETURN
        iptables -w -A hasala-console-out -p tcp -j REJECT --reject-with tcp-reset
        iptables -w -C OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.console.port} -j hasala-console-out 2>/dev/null \
          || iptables -w -I OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.console.port} -j hasala-console-out
        ip6tables -w -N hasala-console-out 2>/dev/null || true
        ip6tables -w -F hasala-console-out
        ip6tables -w -A hasala-console-out -m owner --uid-owner ${cfg.console.restrictToUser} -j RETURN
        ip6tables -w -A hasala-console-out -p tcp -j REJECT --reject-with tcp-reset
        ip6tables -w -C OUTPUT -o lo -p tcp -d ::1 --dport ${toString cfg.console.port} -j hasala-console-out 2>/dev/null \
          || ip6tables -w -I OUTPUT -o lo -p tcp -d ::1 --dport ${toString cfg.console.port} -j hasala-console-out
      '';
      networking.firewall.extraStopCommands = ''
        iptables -w -D OUTPUT -o lo -p tcp -d 127.0.0.1 --dport ${toString cfg.console.port} -j hasala-console-out 2>/dev/null || true
        iptables -w -F hasala-console-out 2>/dev/null || true
        iptables -w -X hasala-console-out 2>/dev/null || true
        ip6tables -w -D OUTPUT -o lo -p tcp -d ::1 --dport ${toString cfg.console.port} -j hasala-console-out 2>/dev/null || true
        ip6tables -w -F hasala-console-out 2>/dev/null || true
        ip6tables -w -X hasala-console-out 2>/dev/null || true
      '';
    })

    # --------------------------------------------------------------- §5.8
    (mkIf cfg.backup.enable {
      systemd.tmpfiles.settings.hasala-backup.${cfg.backup.dir}.d = {
        user = "hasala-backup";
        group = "hasala-backup";
        mode = "0700";
      };

      systemd.services.hasala-backup = {
        description = "Hasala encrypted backup (pg_dump + purge ledger, age)";
        partOf = [ "hasala.target" ];
        requires = [ "hasala-postgresql.service" ];
        after = [
          "hasala-postgresql.service"
          "hasala-migrate.service"
        ];
        onFailure = cfg.monitoring.onFailure;
        onSuccess = optional cfg.backup.offsite.enable "hasala-backup-offsite.service";
        unitConfig.RequiresMountsFor = [ cfg.backup.dir ];
        serviceConfig = backupServiceConfig // {
          ExecStart = "${lib.getExe backupScript} daily";
        };
      };
      systemd.timers.hasala-backup = {
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        timerConfig = {
          OnCalendar = cfg.backup.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };

      # §5.4: a dump before a migration that has work to do. A failed dump
      # fails hasala-migrate, so the new binary never starts on an unbacked-up
      # schema change. `migrate --pending` is read-only and prints 0 for a
      # fresh cluster.
      #
      # RequiresMountsFor on the backup disk is deliberate, and it means a
      # missing backup disk stops hasalad (and the console) from starting even
      # when nothing is pending: the unit cannot know that before the mount
      # dependency is resolved, and failing closed (with onFailure alerting)
      # beats a migration that could not be backed up. Mount the disk, or
      # set backup.enable = false, to start without it.
      systemd.services.hasala-backup-premigrate = {
        description = "Hasala encrypted backup before pending migrations";
        requires = [ "hasala-db-setup.service" ];
        after = [ "hasala-db-setup.service" ];
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        unitConfig.RequiresMountsFor = [ cfg.backup.dir ];
        environment = {
          HASALA_PG_DSN = backupDSN;
          TZ = "UTC";
        };
        script = ''
          n=$(${hasalad} migrate --pending)
          if [ "$n" = 0 ]; then
            echo "hasala-backup-premigrate: no pending migrations, no dump"
            exit 0
          fi
          echo "hasala-backup-premigrate: $n pending migration(s), dumping first"
          exec ${lib.getExe backupScript} premigrate
        '';
        serviceConfig = backupServiceConfig // {
          RuntimeDirectory = "hasala-backup-premigrate";
        };
      };

      systemd.services.hasala-backup-check = {
        description = "Hasala backup freshness and retention check";
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        # Like every backup unit: an unmounted backup disk is a failure, never
        # an empty directory on / that looks fresh or clean.
        unitConfig.RequiresMountsFor = [ cfg.backup.dir ];
        serviceConfig =
          hardening
          // {
            Type = "oneshot";
            User = "hasala-backup";
            Group = "hasala-backup";
            ExecStart = lib.getExe backupCheck;
            StateDirectory = "hasala-backup";
            StateDirectoryMode = "0700";
            RuntimeDirectory = "hasala-backup-check";
            ReadOnlyPaths = [ cfg.backup.dir ];
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            IPAddressDeny = denyLanAndTailnet;
            LoadCredential = optional cfg.backup.offsite.enable "rclone.conf:${cfg.backup.offsite.rcloneConfigFile}";
          }
          // optionalAttrs (!cfg.backup.offsite.enable) {
            PrivateNetwork = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
      };
      systemd.timers.hasala-backup-check = {
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 09:00:00";
          Persistent = true;
        };
      };
    })

    (mkIf (cfg.backup.enable && cfg.backup.offsite.enable) {
      systemd.services.hasala-backup-offsite = {
        description = "Hasala off-site copy of the encrypted backups";
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        unitConfig.RequiresMountsFor = [ cfg.backup.dir ];
        serviceConfig = hardening // {
          Type = "oneshot";
          User = "hasala-backup";
          Group = "hasala-backup";
          LoadCredential = [ "rclone.conf:${cfg.backup.offsite.rcloneConfigFile}" ];
          RuntimeDirectory = "hasala-backup-offsite";
          ReadOnlyPaths = [ cfg.backup.dir ];
          ExecStart = [
            (concatStringsSep " " [
              (lib.getExe pkgs.rclone)
              "copy --immutable --max-age 48h ${offsiteFilter}"
              "--config %d/rclone.conf --cache-dir %t/hasala-backup-offsite"
              (lib.escapeShellArg cfg.backup.dir)
              (lib.escapeShellArg cfg.backup.offsite.remote)
            ])
            (concatStringsSep " " [
              (lib.getExe pkgs.rclone)
              "delete --min-age ${toString cfg.backup.retentionDays}d ${offsiteFilter}"
              "--config %d/rclone.conf --cache-dir %t/hasala-backup-offsite"
              (lib.escapeShellArg cfg.backup.offsite.remote)
            ])
          ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressDeny = denyLanAndTailnet;
          Nice = 10;
          IOSchedulingClass = "idle";
          MemoryMax = cfg.limits.backupMemoryMax;
          CPUQuota = "100%";
        };
      };
    })

    # ------------------------------------------------------------- §5.9.3
    (mkIf cfg.monitoring.healthCheck.enable {
      systemd.services.hasala-health = {
        description = "Hasala health probes";
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        serviceConfig = hardening // {
          Type = "oneshot";
          User = "hasala-health";
          Group = "hasala-health";
          StateDirectory = "hasala-health";
          RuntimeDirectory = "hasala-health";
          ExecStart = lib.getExe healthScript;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          # ntfy may live on loopback; the LAN and the tailnet stay out of reach.
          IPAddressDeny = denyLanAndTailnet;
        };
      };
      users.groups.hasala-health = { };
      users.users.hasala-health = {
        isSystemUser = true;
        group = "hasala-health";
      };
      systemd.timers.hasala-health = {
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "2min";
        };
      };
    })

    # ------------------------------------------------------------- §5.9.4
    (mkIf (cfg.monitoring.healthCheck.enable && emailOn) {
      systemd.services.hasala-email-token-check = {
        description = "Fail if the Cloudflare email send token is inactive or about to expire";
        partOf = [ "hasala.target" ];
        onFailure = cfg.monitoring.onFailure;
        serviceConfig = hardening // {
          Type = "oneshot";
          DynamicUser = true;
          RuntimeDirectory = "hasala-email-token-check";
          LoadCredential = [ "token:${cfg.email.apiTokenFile}" ];
          ExecStart = lib.getExe emailTokenCheck;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressDeny = denyLanAndTailnet;
        };
      };
      systemd.timers.hasala-email-token-check = {
        wantedBy = [ "hasala.target" ];
        partOf = [ "hasala.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 09:05:00";
          Persistent = true;
        };
      };
    })
  ]);
}
