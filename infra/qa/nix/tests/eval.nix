# checks.x86_64-linux.module-eval (spec 05 §14, AT-E1–E3).
#
# Everything here happens at evaluation time: a failure throws with the case's
# name, so `nix flake check --no-build` (which is all a Mac can run of the
# Linux checks) already enforces it. The derivation only records the result.
#
#   AT-E1  a minimal system, a fully configured one, one with the Gmail
#          mailbox link but no Pub/Sub push and one with the Outlook mailbox
#          link alone evaluate their toplevel with no failed assertion;
#   AT-E2  each misuse fails the named module assertion (M1–M23), and each
#          ill-typed value (a Nix path literal for a secret, an unknown key
#          kind, a tester limit of 0) fails the option's type, via tryEval;
#   AT-E3  the rendered units carry exactly the environment and credentials the
#          specs fix, and no secret reaches an Environment= line.
{
  self,
  nixpkgs,
  pkgs,
}:
let
  inherit (nixpkgs) lib;
  t = import ./lib.nix { inherit self nixpkgs; };

  # Paths only: nothing is read at evaluation, and none of these exist.
  secret = name: "/run/secrets/hasala/${name}";
  recipient = "age1uqtdju3geshs2ad6fc6jj0eg22g8xwhe74w09vdwlp5vpfqazpnq779v4u";
  # Not a real account: the module checks the shape (32 lowercase hex).
  accountId = lib.fixedWidthString 32 "0" "";
  consoleHost = "console.example.test";

  publicReady = {
    authKeyFile = secret "auth_key";
    saltKeyFile = secret "salt_key";
    email = {
      cloudflareAccountId = accountId;
      apiTokenFile = secret "email_api_token";
    };
  };
  tunnelOn = publicReady // {
    tunnel = {
      enable = true;
      id = t.testTunnelId;
      credentialsFile = secret "tunnel_credentials";
    };
  };
  consoleOn = {
    console = {
      enable = true;
      host = consoleHost;
      logins = [ "tester@example" ];
      tailnet = "example-tailnet.ts.net";
    };
  };

  # The [gmail] group's two parts.
  gmailLink = {
    google.iosClientId = "000000000000-test.apps.googleusercontent.com";
    mailboxRouteKeyFile = secret "mailbox_route_key";
  };
  gmailPush = {
    gmail = {
      pubsubTopic = "projects/test-project/topics/hasala-gmail-qa";
      pubsubAudience = "https://api.hasala.app/hooks/gmail/pubsub";
      pubsubServiceAccount = "push@test-project.iam.gserviceaccount.com";
      pubsubSubscription = "projects/test-project/subscriptions/hasala-gmail-qa";
    };
  };

  # The [outlook] group's two parts. The client id is a made-up UUID.
  outlookLink = {
    outlook.clientId = "00000000-0000-4000-8000-0000000000aa";
    mailboxRouteKeyFile = secret "mailbox_route_key";
  };
  outlookPushUrls = {
    notificationUrl = "https://api.hasala.app/hooks/outlook/graph";
    lifecycleUrl = "https://api.hasala.app/hooks/outlook/graph/lifecycle";
  };
  outlookOn = lib.recursiveUpdate outlookLink { outlook = outlookPushUrls; };

  # Every option group set: the shape of the QA host's configuration.
  full = {
    services.hasala =
      lib.recursiveUpdate (tunnelOn // consoleOn // gmailLink // gmailPush // outlookOn)
        {
          apns = {
            keyFile = secret "apns_key_p8";
            keyId = "ABCDE12345";
          };
          web.turnstile.secretFile = secret "turnstile_secret";
          backup = {
            enable = true;
            ageRecipients = [ recipient ];
            offsite = {
              enable = true;
              rcloneConfigFile = secret "backup_rclone_conf";
              remote = "r2:test-bucket/daily";
            };
          };
          monitoring = {
            onFailure = [ "notify-failure@%n.service" ];
            healthCheck.enable = true;
            ntfyUrl = "http://127.0.0.1:2586/test";
            earlyAccessNotice = true;
          };
          asc = {
            enable = true;
            keyFile = secret "asc_key_p8";
            keyId = "ZYXWV98765";
            issuerId = "00000000-0000-4000-8000-000000000001";
            refusedKeyIds = [ "AAAAA11111" ];
          };
          hardening.inaccessiblePaths = [
            "-/var/lib/postgresql"
            "-/run/postgresql"
            "-/run/secrets"
            "-/var/lib/neighbour"
          ];
        };
    # The console behind a tailnet-gated nginx vhost (M19's positive case).
    services.tailscale.enable = true;
    services.nginx = {
      enable = true;
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ consoleHost ];
      };
      virtualHosts.${consoleHost}.locations."/".proxyPass = "http://127.0.0.1:8472";
    };
  };

  hasala = extra: { services.hasala = extra; };

  # AT-E2: name → the assertion that must fail, and the configuration.
  negatives = {
    "listen.address 0.0.0.0" = [
      "M1"
      (hasala { listen.address = "0.0.0.0"; })
    ];
    "listen.port = metrics.port" = [
      "M2"
      (hasala { listen.port = 9471; })
    ];
    "API port in the firewall" = [
      "M3"
      { networking.firewall.allowedTCPPorts = [ 8471 ]; }
    ];
    "metrics port open on one interface" = [
      "M3"
      { networking.firewall.interfaces.eth0.allowedTCPPorts = [ 9471 ]; }
    ];
    "extraEnvironment HASALA_ADMIN_TOKEN" = [
      "M4"
      (hasala { extraEnvironment.HASALA_ADMIN_TOKEN = "x"; })
    ];
    "extraEnvironment FOO_SECRET" = [
      "M4"
      (hasala { extraEnvironment.FOO_SECRET = "x"; })
    ];
    "extraEnvironment overrides a fixed key" = [
      "M4"
      (hasala { extraEnvironment.HASALA_HTTP_LISTEN = "0.0.0.0:8471"; })
    ];
    "tunnel id not a UUID" = [
      "M5"
      (hasala (
        tunnelOn
        // {
          tunnel = tunnelOn.tunnel // {
            id = "not-a-uuid";
          };
        }
      ))
    ];
    "tunnel without credentials" = [
      "M5"
      (hasala (
        tunnelOn
        // {
          tunnel = tunnelOn.tunnel // {
            credentialsFile = null;
          };
        }
      ))
    ];
    "wildcard publicHostname" = [
      "M5"
      (hasala { publicHostname = "*.hasala.app"; })
    ];
    "publicHostname outside rpId" = [
      "M5"
      (hasala { publicHostname = "api.example.com"; })
    ];
    "hand-edited ingress (extra rule)" = [
      "M6"
      (hasala {
        tunnel.ingress = lib.mkForce [
          {
            hostname = "api.hasala.app";
            service = "http://127.0.0.1:8471";
          }
          { service = "http_status:404"; }
        ];
      })
    ];
    "backup without recipients" = [
      "M7"
      (hasala { backup.enable = true; })
    ];
    "backup to a plugin recipient" = [
      "M7"
      (hasala {
        backup = {
          enable = true;
          ageRecipients = [ "age1yubikey1qwt50d05nh5vutpdzmlg5wn80xq5negm4uj9ghv0snvdd3yysf5yw3rhl3t" ];
        };
      })
    ];
    "off-site without backups" = [
      "M7"
      (hasala {
        backup.offsite = {
          enable = true;
          rcloneConfigFile = secret "backup_rclone_conf";
          remote = "r2:test-bucket/daily";
        };
      })
    ];
    "client id without the route key" = [
      "M8a"
      (hasala { inherit (gmailLink) google; })
    ];
    "route key without the client id" = [
      "M8a"
      (hasala { inherit (gmailLink) mailboxRouteKeyFile; })
    ];
    "client id not a Google client id" = [
      "M8a"
      (hasala (gmailLink // { google.iosClientId = "not-a-client-id"; }))
    ];
    "one Pub/Sub value only" = [
      "M8b"
      (hasala { gmail.pubsubTopic = "projects/p/topics/t"; })
    ];
    "three Pub/Sub values with the link" = [
      "M8b"
      (hasala (gmailLink // { gmail = removeAttrs gmailPush.gmail [ "pubsubServiceAccount" ]; }))
    ];
    "the Pub/Sub push without the link" = [
      "M8b"
      (hasala gmailPush)
    ];
    "Pub/Sub service account not a service account email" = [
      "M8b"
      (hasala (
        lib.recursiveUpdate (gmailLink // gmailPush) {
          gmail.pubsubServiceAccount = "push@test-project.gserviceaccount.com";
        }
      ))
    ];
    "Outlook client id without the route key" = [
      "M8c"
      (hasala { inherit (outlookLink) outlook; })
    ];
    "Outlook client id not a UUID" = [
      "M8c"
      (hasala (outlookLink // { outlook.clientId = "not-a-client-id"; }))
    ];
    "Outlook client id in upper case" = [
      "M8c"
      (hasala (outlookLink // { outlook.clientId = "00000000-0000-4000-8000-0000000000AA"; }))
    ];
    "one Graph URL only" = [
      "M8d"
      (hasala (
        lib.recursiveUpdate outlookLink { outlook = { inherit (outlookPushUrls) notificationUrl; }; }
      ))
    ];
    "the Graph push without the link" = [
      "M8d"
      (hasala { outlook = outlookPushUrls; })
    ];
    "the Graph push with only the Gmail link" = [
      "M8d"
      (hasala (gmailLink // { outlook = outlookPushUrls; }))
    ];
    "Graph notification URL over http" = [
      "M8d"
      (hasala (
        lib.recursiveUpdate outlookOn {
          outlook.notificationUrl = "http://api.hasala.app/hooks/outlook/graph";
        }
      ))
    ];
    "Graph notification URL on another host" = [
      "M8d"
      (hasala (
        lib.recursiveUpdate outlookOn {
          outlook.notificationUrl = "https://hooks.example.test/hooks/outlook/graph";
        }
      ))
    ];
    "Graph notification URL on the lifecycle path" = [
      "M8d"
      (hasala (lib.recursiveUpdate outlookOn { outlook.notificationUrl = outlookPushUrls.lifecycleUrl; }))
    ];
    "Graph lifecycle URL on the notification path" = [
      "M8d"
      (hasala (lib.recursiveUpdate outlookOn { outlook.lifecycleUrl = outlookPushUrls.notificationUrl; }))
    ];
    "Graph lifecycle URL with a trailing slash" = [
      "M8d"
      (hasala (
        lib.recursiveUpdate outlookOn { outlook.lifecycleUrl = outlookPushUrls.lifecycleUrl + "/"; }
      ))
    ];
    "Graph notification URL with a query" = [
      "M8d"
      (hasala (
        lib.recursiveUpdate outlookOn {
          outlook.notificationUrl = outlookPushUrls.notificationUrl + "?x=1";
        }
      ))
    ];
    "database listen_addresses" = [
      "M9"
      (hasala { database.settings.listen_addresses = "*"; })
    ];
    "database log_statement" = [
      "M9"
      (hasala { database.settings.log_statement = "all"; })
    ];
    "API host on nginx" = [
      "M10"
      { services.nginx.virtualHosts."api.hasala.app" = { }; }
    ];
    "email account id without token" = [
      "M11"
      (hasala { email.cloudflareAccountId = accountId; })
    ];
    "email account id malformed" = [
      "M11"
      (hasala {
        email = {
          cloudflareAccountId = "not-hex";
          apiTokenFile = secret "email_api_token";
        };
      })
    ];
    "tunnel without email" = [
      "M11"
      (hasala (tunnelOn // { email = { }; }))
    ];
    "email.from outside rpId" = [
      "M11"
      (hasala { email.from = "no-reply@example.com"; })
    ];
    "email.replyTo outside rpId" = [
      "M11"
      (hasala { email.replyTo = "support@example.com"; })
    ];
    "tunnel without authKeyFile" = [
      "M12"
      (hasala (tunnelOn // { authKeyFile = null; }))
    ];
    "tunnel without saltKeyFile" = [
      "M12"
      (hasala (tunnelOn // { saltKeyFile = null; }))
    ];
    "saltKeyFile is authKeyFile" = [
      "M12"
      (hasala (tunnelOn // { saltKeyFile = secret "auth_key"; }))
    ];
    "passwordHashConcurrency 4" = [
      "M12"
      (hasala { passwordHashConcurrency = 4; })
    ];
    "retentionDays 30" = [
      "M13"
      (hasala { backup.retentionDays = 30; })
    ];
    "console on the API port" = [
      "M14"
      (hasala (lib.recursiveUpdate consoleOn { console.port = 8471; }))
    ];
    "console port in the firewall" = [
      "M15"
      (lib.recursiveUpdate (hasala consoleOn) { networking.firewall.allowedTCPPorts = [ 8472 ]; })
    ];
    "console metrics port in the firewall (even with the console off)" = [
      "M15"
      { networking.firewall.allowedTCPPorts = [ 9473 ]; }
    ];
    "hand-edited ingress naming :9473" = [
      "M16"
      (hasala {
        tunnel.ingress = lib.mkForce [
          {
            hostname = "api.hasala.app";
            path = "^/(api/v1/.*|hooks/gmail/pubsub|hooks/outlook/graph(/lifecycle)?)$";
            service = "http://127.0.0.1:9473";
          }
          { service = "http_status:404"; }
        ];
      })
    ];
    "console without logins" = [
      "M17"
      (hasala (lib.recursiveUpdate consoleOn { console.logins = [ ]; }))
    ];
    "console login without a domain" = [
      "M17"
      (hasala (lib.recursiveUpdate consoleOn { console.logins = [ "tester" ]; }))
    ];
    "console without a tailnet" = [
      "M17"
      (hasala (lib.recursiveUpdate consoleOn { console.tailnet = null; }))
    ];
    "console under rpId" = [
      "M18"
      (hasala (lib.recursiveUpdate consoleOn { console.host = "x.hasala.app"; }))
    ];
    "console vhost not tailnet-gated" = [
      "M19"
      (lib.recursiveUpdate (hasala consoleOn) {
        services.nginx = {
          enable = true;
          virtualHosts.${consoleHost}.locations."/".proxyPass = "http://127.0.0.1:8472";
        };
      })
    ];
    "extraEnvironment HASALA_ASC_KEY_ID" = [
      "M20"
      (hasala { extraEnvironment.HASALA_ASC_KEY_ID = "ABCDEFGHIJ"; })
    ];
    "asc without the console" = [
      "M20"
      (hasala {
        asc = {
          enable = true;
          keyFile = secret "asc_key_p8";
          keyId = "ZYXWV98765";
          issuerId = "00000000-0000-4000-8000-000000000001";
        };
      })
    ];
    "asc with a refused key id" = [
      "M20"
      (hasala (
        lib.recursiveUpdate consoleOn {
          asc = {
            enable = true;
            keyFile = secret "asc_key_p8";
            keyId = "AAAAA11111";
            issuerId = "00000000-0000-4000-8000-000000000001";
            refusedKeyIds = [ "AAAAA11111" ];
          };
        }
      ))
    ];
    "asc with no refused key ids" = [
      "M20"
      (hasala (
        lib.recursiveUpdate consoleOn {
          asc = {
            enable = true;
            keyFile = secret "asc_key_p8";
            keyId = "ZYXWV98765";
            issuerId = "00000000-0000-4000-8000-000000000001";
          };
        }
      ))
    ];
    "console on an nftables host" = [
      "M21"
      (lib.recursiveUpdate (hasala consoleOn) { networking.nftables.enable = true; })
    ];
    "console with the firewall off" = [
      "M21"
      (lib.recursiveUpdate (hasala consoleOn) { networking.firewall.enable = false; })
    ];
    # M19: nginx is the one user the kernel rule lets through, so a second,
    # ungated vhost reaching the console by any loopback spelling is refused.
    "second vhost to localhost:8472" = [
      "M19"
      (lib.recursiveUpdate full {
        services.nginx.virtualHosts."other.example.test".locations."/".proxyPass = "http://localhost:8472";
      })
    ];
    "second vhost to [::1]:8472" = [
      "M19"
      (lib.recursiveUpdate full {
        services.nginx.virtualHosts."other.example.test".locations."/".proxyPass = "http://[::1]:8472";
      })
    ];
    "second vhost with proxy_pass in extraConfig" = [
      "M19"
      (lib.recursiveUpdate full {
        services.nginx.virtualHosts."other.example.test".locations."/x".extraConfig =
          "proxy_pass http://127.0.0.1:8472;";
      })
    ];
    "second vhost through an upstream" = [
      "M19"
      (lib.recursiveUpdate full {
        services.nginx.upstreams.console.servers."127.0.0.1:8472" = { };
        services.nginx.virtualHosts."other.example.test".locations."/".proxyPass = "http://console";
      })
    ];
    # M22 (review 2 F-22): a secret under the Nix store is world-readable.
    "authKeyFile under the Nix store" = [
      "M22"
      (hasala { authKeyFile = "${builtins.storeDir}/x-auth-key"; })
    ];
    "asc.keyFile under the Nix store" = [
      "M22"
      (lib.recursiveUpdate full {
        services.hasala.asc.keyFile = "${builtins.storeDir}/0000000000000000000000000000000-asc.p8";
      })
    ];
    "relative secret path" = [
      "M22"
      (hasala { apns.keyFile = "secrets/apns.p8"; })
    ];
    "earlyAccessNotice without ntfyUrl" = [
      "M23"
      (hasala { monitoring.earlyAccessNotice = true; })
    ];
  };

  # AT-E2, type errors: name → [ the option to force, the configuration ].
  # Forcing the option itself (not the toplevel) proves the type, not an
  # assertion, refused it.
  typeErrors = {
    "asc.keyKind developer" = [
      (c: c.asc.keyKind)
      (hasala { asc.keyKind = "developer"; })
    ];
    "asc.testerLimit 0" = [
      (c: c.asc.testerLimit)
      (hasala { asc.testerLimit = 0; })
    ];
    # A path literal would be copied into the store; the type refuses it.
    "authKeyFile as a Nix path literal" = [
      (c: c.authKeyFile)
      (hasala { authKeyFile = ./lib.nix; })
    ];
    "tunnel.credentialsFile as a Nix path literal" = [
      (c: c.tunnel.credentialsFile)
      (hasala { tunnel.credentialsFile = ./lib.nix; })
    ];
  };
  typeErrorErrors = lib.concatLists (
    lib.mapAttrsToList (
      name: c:
      let
        get = lib.elemAt c 0;
        sys = t.evalSystem (lib.elemAt c 1);
      in
      lib.optional (builtins.tryEval (builtins.deepSeq (get sys.config.services.hasala) true)).success "AT-E2 \"${name}\": the option's type accepted it"
    ) typeErrors
  );

  failedHasala =
    sys:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "services.hasala " a.message) sys.config.assertions
    );
  failedAny = sys: map (a: a.message) (lib.filter (a: !a.assertion) sys.config.assertions);

  negativeErrors = lib.concatLists (
    lib.mapAttrsToList (
      name: c:
      let
        code = lib.elemAt c 0;
        msgs = failedHasala (t.evalSystem (lib.elemAt c 1));
      in
      lib.optional (
        !lib.any (lib.hasPrefix "services.hasala ${code}:") msgs
      ) "AT-E2 \"${name}\": ${code} did not fire (failed: ${builtins.toJSON msgs})"
    ) negatives
  );

  minimal = t.evalSystem { };
  fullSys = t.evalSystem full;
  # The QA host before its Pub/Sub push exists: the mailbox link alone.
  linkOnlySys = t.evalSystem (hasala gmailLink);
  # Outlook's link alone: the route key without a Google client id.
  outlookLinkOnlySys = t.evalSystem (hasala outlookLink);
  manualSys = t.evalSystem (lib.recursiveUpdate full { services.hasala.asc.enable = false; });

  positiveErrors =
    lib.optional (failedAny minimal != [ ]) "AT-E1 minimal: ${builtins.toJSON (failedAny minimal)}"
    ++ lib.optional (failedAny fullSys != [ ]) "AT-E1 full: ${builtins.toJSON (failedAny fullSys)}"
    ++ lib.optional (
      failedAny linkOnlySys != [ ]
    ) "AT-E1 gmail link only: ${builtins.toJSON (failedAny linkOnlySys)}"
    ++ lib.optional (
      failedAny outlookLinkOnlySys != [ ]
    ) "AT-E1 outlook link only: ${builtins.toJSON (failedAny outlookLinkOnlySys)}";

  svc = sys: name: sys.config.systemd.services.${name};
  # NixOS adds PATH to every unit; it is not part of the contract.
  envOf = sys: name: removeAttrs (svc sys name).environment [ "PATH" ];
  credsOf =
    sys: name:
    lib.sort lib.lessThan (
      map (c: lib.head (lib.splitString ":" c)) (
        lib.toList ((svc sys name).serviceConfig.LoadCredential or [ ])
      )
    );
  check = cond: msg: lib.optional (!cond) msg;
  keysWith =
    prefixes: env: lib.filter (k: lib.any (p: lib.hasPrefix p k) prefixes) (lib.attrNames env);
  secretValues = map secret [
    "auth_key"
    "salt_key"
    "email_api_token"
    "apns_key_p8"
    "mailbox_route_key"
    "turnstile_secret"
    "asc_key_p8"
    "tunnel_credentials"
    "backup_rclone_conf"
  ];
  hasaladEnv = envOf fullSys "hasalad";
  linkOnlyEnv = envOf linkOnlySys "hasalad";
  outlookLinkOnlyEnv = envOf outlookLinkOnlySys "hasalad";
  mailboxKeys =
    env: keysWith [ "HASALA_GOOGLE_" "HASALA_GMAIL_" "HASALA_OUTLOOK_" "HASALA_MAILBOX_" ] env;
  consoleEnv = envOf fullSys "hasala-console";
  manualConsoleEnv = envOf manualSys "hasala-console";
  allEnvValues = lib.concatMap (s: map toString (lib.attrValues (s.environment or { }))) (
    lib.attrValues fullSys.config.systemd.services
  );
  # §5.5: the fixed keys of `serve` (the [gmail], [outlook], [email], APNs,
  # auth-key and Turnstile ones included, since `full` sets every group).
  serveKeys = [
    "HASALA_HTTP_LISTEN"
    "HASALA_METRICS_LISTEN"
    "HASALA_PG_DSN"
    "HASALA_TRUSTED_PROXY"
    "HASALA_RP_ID"
    "HASALA_RP_ORIGINS"
    "HASALA_RP_DISPLAY_NAME"
    "HASALA_HEADROOM_PATH"
    "HASALA_HEADROOM_FLOOR_BYTES"
    "HASALA_HEADROOM_INTERVAL"
    "HASALA_APNS_KEY_FILE"
    "HASALA_APNS_KEY_ID"
    "HASALA_APNS_TEAM_ID"
    "HASALA_APNS_TOPIC"
    "HASALA_APNS_ENABLED"
    "HASALA_APNS_ENVIRONMENTS"
    "HASALA_GOOGLE_IOS_CLIENT_ID"
    "HASALA_GMAIL_PUBSUB_TOPIC"
    "HASALA_GMAIL_PUBSUB_AUDIENCE"
    "HASALA_GMAIL_PUBSUB_SA_EMAIL"
    "HASALA_GMAIL_PUBSUB_SUBSCRIPTION"
    "HASALA_OUTLOOK_CLIENT_ID"
    "HASALA_OUTLOOK_NOTIFICATION_URL"
    "HASALA_OUTLOOK_LIFECYCLE_URL"
    "HASALA_MAILBOX_ROUTE_KEY_FILE"
    "HASALA_AUTH_KEY_FILE"
    "HASALA_SALT_KEY_FILE"
    "HASALA_EMAIL_CF_ACCOUNT_ID"
    "HASALA_EMAIL_API_TOKEN_FILE"
    "HASALA_EMAIL_FROM"
    "HASALA_EMAIL_FROM_NAME"
    "HASALA_EMAIL_REPLY_TO"
    "HASALA_PASSWORD_HASH_CONCURRENCY"
    "HASALA_PURGE_LEDGER_PATH"
    "HASALA_LOG_GENERATION_FILE"
    "HASALA_WEB_BASE_URL"
    "HASALA_WEB_ORIGINS"
    "HASALA_WEB_WAITLIST_DONE_URL"
    "HASALA_TURNSTILE_SECRET_FILE"
    "HASALA_TURNSTILE_REQUIRED"
    "HASALA_TURNSTILE_HOSTNAMES"
    "HASALA_WAITLIST_MAX"
    "HASALA_WAITLIST_PENDING_MAX"
    "HASALA_WAITLIST_RETENTION"
    "HASALA_EMAIL_RATE_WAITLIST"
    "HASALA_EMAIL_RATE_BULK"
    "HASALA_EMAIL_LOG_RETENTION"
    "HASALA_INVITE_TTL"
    "HASALA_OPS_NTFY_URL"
    "HASALA_OPS_NTFY_CLICK"
    "GOMEMLIMIT"
    "TZ"
  ];
  consoleKeysManual = [
    "HASALA_PG_DSN"
    "HASALA_RP_ID"
    "HASALA_RP_ORIGINS"
    "HASALA_CONSOLE_LISTEN"
    "HASALA_CONSOLE_METRICS_LISTEN"
    "HASALA_CONSOLE_HOST"
    "HASALA_CONSOLE_LOGINS"
    "HASALA_CONSOLE_TAILNET"
    "HASALA_PURGE_LEDGER_PATH"
    "HASALA_TESTFLIGHT_MODE"
    "GOMEMLIMIT"
    "TZ"
  ];
  consoleKeysExternal = consoleKeysManual ++ [
    "HASALA_ASC_KEY_FILE"
    "HASALA_ASC_KEY_ID"
    "HASALA_ASC_KEY_KIND"
    "HASALA_ASC_ISSUER_ID"
    "HASALA_ASC_BUNDLE_ID"
    "HASALA_ASC_BETA_GROUP"
    "HASALA_ASC_TESTER_LIMIT"
    "HASALA_ASC_RECONCILE_INTERVAL"
    "HASALA_ASC_REQUEST_BUDGET"
  ];
  sameSet = a: b: lib.sort lib.lessThan a == lib.sort lib.lessThan b;
  # The long-running units and every oneshot: each takes the §5.2 hardening.
  hardenedUnits = [
    "hasala-postgresql"
    "hasala-db-setup"
    "hasala-migrate"
    "hasalad"
    "hasala-console"
    "cloudflared-hasala"
    "hasala-backup"
    "hasala-backup-premigrate"
    "hasala-backup-offsite"
    "hasala-backup-check"
    "hasala-health"
    "hasala-email-token-check"
  ];
  hardeningOf = name: (svc fullSys name).serviceConfig;

  envErrors =
    check (sameSet (lib.attrNames hasaladEnv) serveKeys) "AT-E3 hasalad environment is ${builtins.toJSON (lib.attrNames hasaladEnv)}"
    ++ check (
      keysWith [ "HASALA_CONSOLE_" "HASALA_ASC_" "HASALA_TESTFLIGHT_" "HASALA_ADMIN_" ] hasaladEnv == [ ]
    ) "AT-E3 hasalad has console/ASC/admin keys"
    ++ check (
      hasaladEnv.HASALA_HTTP_LISTEN == "127.0.0.1:8471"
    ) "AT-E3 hasalad listens on ${hasaladEnv.HASALA_HTTP_LISTEN}"
    ++ check (
      hasaladEnv.HASALA_TRUSTED_PROXY == "cloudflare"
    ) "AT-E3 hasalad behind the tunnel must trust cloudflare"
    ++ check (
      hasaladEnv.HASALA_AUTH_KEY_FILE == "%d/auth-key"
    ) "AT-E3 HASALA_AUTH_KEY_FILE is not a credential path"
    ++ check (
      hasaladEnv.HASALA_SALT_KEY_FILE == "%d/salt-key"
    ) "AT-E3 HASALA_SALT_KEY_FILE is not a credential path"
    ++ check (
      credsOf fullSys "hasalad" == [
        "apns-key.p8"
        "auth-key"
        "email-api-token"
        "mailbox-route-key"
        "salt-key"
        "turnstile-secret"
      ]
    ) "AT-E3 hasalad LoadCredential is ${builtins.toJSON (credsOf fullSys "hasalad")}"
    ++ check (
      hasaladEnv.HASALA_OUTLOOK_NOTIFICATION_URL == "https://api.hasala.app/hooks/outlook/graph"
      && hasaladEnv.HASALA_OUTLOOK_LIFECYCLE_URL == "https://api.hasala.app/hooks/outlook/graph/lifecycle"
    ) "AT-E3 the [outlook] push URLs"
    ++ check (
      hasaladEnv.HASALA_OPS_NTFY_URL == "http://127.0.0.1:2586/test"
      && hasaladEnv.HASALA_OPS_NTFY_CLICK == "https://${consoleHost}/"
      && !(linkOnlyEnv ? HASALA_OPS_NTFY_URL)
    ) "AT-E3 the early-access notice"
    ++
      check
        (sameSet (mailboxKeys outlookLinkOnlyEnv) [
          "HASALA_OUTLOOK_CLIENT_ID"
          "HASALA_MAILBOX_ROUTE_KEY_FILE"
        ])
        "AT-E3 hasalad's mailbox keys with the Outlook link only are ${builtins.toJSON (mailboxKeys outlookLinkOnlyEnv)}"
    ++ check (
      outlookLinkOnlyEnv.HASALA_MAILBOX_ROUTE_KEY_FILE or null == "%d/mailbox-route-key"
      && outlookLinkOnlyEnv.HASALA_OUTLOOK_CLIENT_ID or null == "00000000-0000-4000-8000-0000000000aa"
    ) "AT-E3 the Outlook-link-only values"
    ++
      check (credsOf outlookLinkOnlySys "hasalad" == [ "mailbox-route-key" ])
        "AT-E3 hasalad LoadCredential with the Outlook link only is ${builtins.toJSON (credsOf outlookLinkOnlySys "hasalad")}"
    ++ check (sameSet (mailboxKeys linkOnlyEnv)
      [
        "HASALA_GOOGLE_IOS_CLIENT_ID"
        "HASALA_MAILBOX_ROUTE_KEY_FILE"
      ]
    ) "AT-E3 hasalad's [gmail] keys with the link only are ${builtins.toJSON (mailboxKeys linkOnlyEnv)}"
    ++ check (
      linkOnlyEnv.HASALA_MAILBOX_ROUTE_KEY_FILE or null == "%d/mailbox-route-key"
      && linkOnlyEnv.HASALA_GOOGLE_IOS_CLIENT_ID or null == "000000000000-test.apps.googleusercontent.com"
    ) "AT-E3 the link-only [gmail] values"
    ++
      check (credsOf linkOnlySys "hasalad" == [ "mailbox-route-key" ])
        "AT-E3 hasalad LoadCredential with the link only is ${builtins.toJSON (credsOf linkOnlySys "hasalad")}"
    ++ check (
      mailboxKeys (envOf minimal "hasalad") == [ ]
    ) "AT-E3 hasalad has [gmail] or [outlook] keys with none configured"
    ++ check (sameSet (lib.attrNames consoleEnv) consoleKeysExternal) "AT-E3 console environment (external) is ${builtins.toJSON (lib.attrNames consoleEnv)}"
    ++ check (
      consoleEnv.HASALA_TESTFLIGHT_MODE == "external"
    ) "AT-E3 console TESTFLIGHT_MODE with asc on"
    ++ check (
      credsOf fullSys "hasala-console" == [ "asc-key.p8" ]
    ) "AT-E3 console LoadCredential is ${builtins.toJSON (credsOf fullSys "hasala-console")}"
    ++ check (sameSet (lib.attrNames manualConsoleEnv) consoleKeysManual) "AT-E3 console environment (manual) is ${builtins.toJSON (lib.attrNames manualConsoleEnv)}"
    ++ check (
      manualConsoleEnv.HASALA_TESTFLIGHT_MODE == "manual"
    ) "AT-E3 console TESTFLIGHT_MODE with asc off"
    ++ check (credsOf manualSys "hasala-console" == [ ]) "AT-E3 console holds a credential with asc off"
    ++ check (lib.elem "-/run/credentials/hasala-console.service" (hardeningOf "hasalad").InaccessiblePaths) "AT-E3 hasalad can read the console's credentials"
    ++ check (lib.elem "-/run/credentials/hasalad.service" (hardeningOf "hasala-console").InaccessiblePaths) "AT-E3 the console can read hasalad's credentials"
    ++ check (
      credsOf fullSys "cloudflared-hasala" == [ "tunnel.json" ]
    ) "AT-E3 cloudflared LoadCredential"
    ++ check (
      !lib.any (v: lib.any (s: lib.hasInfix s v) secretValues) allEnvValues
    ) "AT-E3 a secret's path reached an Environment= line"
    ++ lib.concatMap (
      u:
      let
        c = hardeningOf u;
      in
      check (
        c.NoNewPrivileges or false
        && (c.ProtectSystem or "") == "strict"
        && (c.CapabilityBoundingSet or null) == ""
        && (c.PrivateTmp or false)
        && lib.elem "-/var/lib/neighbour" (c.InaccessiblePaths or [ ])
        && (c.Slice or "") == "hasala.slice"
      ) "AT-E3 ${u} lacks the §5.2 hardening"
      ++ check (
        c ? IPAddressDeny || c.PrivateNetwork or false
      ) "AT-E3 ${u} has neither IPAddressDeny nor PrivateNetwork"
      ++ check ((c.LimitCORE or null) == 0) "AT-E3 ${u} lacks LimitCORE = 0"
      ++ check (lib.elem "hasala.target" (
        (svc fullSys u).partOf or [ ]
      )) "AT-E3 ${u} is not PartOf hasala.target"
    ) hardenedUnits
    ++ check (
      lib.hasInfix "ip6tables -w -I OUTPUT -o lo -p tcp -d ::1 --dport 8472" fullSys.config.networking.firewall.extraCommands
      && lib.hasInfix "ip6tables -w -X hasala-console-out" fullSys.config.networking.firewall.extraStopCommands
    ) "AT-E3 the kernel rule has no ::1 twin"
    ++ check (
      (hardeningOf "hasala-postgresql").PrivateNetwork
      && (hardeningOf "hasala-postgresql").RestrictAddressFamilies == [ "AF_UNIX" ]
    ) "AT-E3 postgres must be unix-socket only"
    ++ check (
      lib.hasInfix "--uid-owner nginx" fullSys.config.networking.firewall.extraCommands
      && lib.hasInfix "--dport 8472" fullSys.config.networking.firewall.extraCommands
    ) "AT-E3 the console's kernel rule is missing"
    ++ check (
      !lib.hasInfix "hasala-console" minimal.config.networking.firewall.extraCommands
    ) "AT-E3 the kernel rule is installed with the console off"
    ++ check (
      !(minimal.config.systemd.services ? hasala-console)
    ) "AT-E3 the console unit exists with the console off"
    ++ check (
      !(minimal.config.systemd.services ? cloudflared-hasala)
    ) "AT-E3 the tunnel unit exists with the tunnel off"
    ++ check (
      (envOf minimal "hasalad").HASALA_TRUSTED_PROXY == "none"
    ) "AT-E3 no tunnel must mean trusted_proxy none";

  errors = negativeErrors ++ typeErrorErrors ++ positiveErrors ++ envErrors;

  # AT-E1: both toplevels evaluate. The paths are recorded without their
  # context, so the check builds nothing of either system.
  toplevels = map (s: builtins.unsafeDiscardStringContext s.config.system.build.toplevel.drvPath) [
    minimal
    fullSys
    linkOnlySys
  ];
in
if errors != [ ] then
  throw ("services.hasala module-eval failed:\n  " + lib.concatStringsSep "\n  " errors)
else
  pkgs.runCommand "hasala-module-eval" { } ''
    {
      echo "AT-E1 toplevels: ${lib.concatStringsSep " " toplevels}"
      echo "AT-E2 ${toString (lib.length (lib.attrNames negatives))} misuse cases, each refused by its assertion"
      echo "AT-E2 ${toString (lib.length (lib.attrNames typeErrors))} ill-typed values, each refused by its option type"
      echo "AT-E3 environment, credential and hardening checks passed"
    } > "$out"
  ''
