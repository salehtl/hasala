# checks.x86_64-linux.qa-vm (spec 05 §4.2, §14, AT-V*): boots services.hasala in
# a NixOS VM with dummy secrets, the tunnel off (the VM has no route to
# Cloudflare), backups on (to a deterministic test recipient) and the console on.
#
# Needs KVM, so it runs in CI's nixos-vm job, never on a Mac; there,
# `nix flake check --no-build` evaluates it.
#
# The console (spec 07 §8) is not built yet: `hasalad console` validates its
# whole environment and then refuses, exit 2, "not built yet". Until it is, the
# test asserts exactly that refusal (so the module's console environment is
# proven to pass the server's own checks), proves the kernel rule with a
# stand-in listener on the console port, and logs the header checks as skipped.
# The day the console serves, the same test runs the header checks against it
# without any edit here.
self:
{ lib, ... }:
let
  apiPort = 8471;
  consolePort = 8472;
  consoleMetricsPort = 9473;
  consoleHost = "console.vm.test";
  consoleLogin = "tester@example";
  consoleTailnet = "vm-test.ts.net";
  # The public half of the test identity the script derives at run time from
  # sha256("hasala-vm-test-identity"); no secret key is in the repository.
  testRecipient = "age1uqtdju3geshs2ad6fc6jj0eg22g8xwhe74w09vdwlp5vpfqazpnq779v4u";
in
{
  name = "qa-vm";

  nodes.machine =
    { config, pkgs, ... }:
    let
      # Dummy secrets: well-formed, derived from fixed labels, never used for
      # anything real. M22 refuses a secret under the Nix store, so they are
      # written at boot (hasala-vm-secrets below), root-only, outside it, and
      # reach the units through LoadCredential= like the host's sops files do.
      secretDir = "/var/lib/hasala-vm-secrets";
      dummy = name: "${secretDir}/${name}";
      hex64 = label: builtins.hashString "sha256" "hasala-vm-test-${label}";
    in
    {
      imports = [ self.nixosModules.hasala ];

      virtualisation = {
        memorySize = 3072;
        cores = 2;
        diskSize = 4096;
      };

      services.hasala = {
        enable = true;
        # The VM's disk is a few GiB: the default 16 GiB floor would trip the
        # disk fuse and refuse every write.
        headroomFloorBytes = 64 * 1024 * 1024;
        authKeyFile = dummy "auth-key";
        email = {
          cloudflareAccountId = builtins.substring 0 32 (hex64 "cf-account");
          apiTokenFile = dummy "email-token";
        };
        apns = {
          keyFile = dummy "apns.p8";
          keyId = "ABCDE12345";
        };
        backup = {
          enable = true;
          ageRecipients = [ testRecipient ];
        };
        console = {
          enable = true;
          host = consoleHost;
          logins = [ consoleLogin ];
          tailnet = consoleTailnet;
        };
        # The test starts hasala-health by hand (P10); its timer stays off.
        monitoring.healthCheck.enable = true;
        # A stand-in for a neighbour's state that no Hasala unit may read.
        hardening.inaccessiblePaths = [
          "-/var/lib/postgresql"
          "-/run/postgresql"
          "-/run/secrets"
          "-/var/lib/neighbour"
        ];
      };

      systemd.timers.hasala-health.wantedBy = lib.mkForce [ ];
      systemd.timers.hasala-email-token-check.wantedBy = lib.mkForce [ ];

      # Before any service (sysinit), so every LoadCredential= finds its file.
      systemd.services.hasala-vm-secrets = {
        description = "Dummy Hasala secrets for the VM test, written at boot outside the store";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
        ];
        after = [ "local-fs.target" ];
        conflicts = [ "shutdown.target" ];
        unitConfig.DefaultDependencies = false;
        path = [
          pkgs.coreutils
          pkgs.openssl
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = ''
          d=${secretDir}
          install -d -m 0700 "$d"
          hex() { printf '%s' "hasala-vm-test-$1" | sha256sum | cut -c1-64; }
          printf '%s' "$(hex auth-key)" > "$d/auth-key"
          printf '%s' dummy-email-send-token > "$d/email-token"
          # serve refuses anything but a PKCS#8 EC P-256 key; this one is
          # throwaway and never reaches APNs (the VM has no egress).
          openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$d/apns.p8"
          chmod 0400 "$d"/*
        '';
      };

      # AT-V13: an egress probe the test runs inside hasalad's own cgroup,
      # where IPAddressDeny's BPF filter applies.
      environment.etc."hasala-vm/egress.py".text = ''
        import socket
        import sys

        host = sys.argv[1]
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            u.sendto(b"x", (host, 443))
            print("udp=sent")
        except PermissionError:
            print("udp=EPERM")
        except OSError as e:
            print(f"udp=errno{e.errno}")
        t = socket.socket()
        t.settimeout(3)
        try:
            t.connect((host, 443))
            print("tcp=connected")
        except PermissionError:
            print("tcp=EPERM")
        except OSError as e:
            print(f"tcp=errno{e.errno}")
      '';

      # The kernel rule lets only this user reach the console port. The VM has
      # no nginx; the test acts as the nginx user directly.
      users.users.nginx = {
        isSystemUser = true;
        group = "nginx";
      };
      users.groups.nginx = { };
      users.users.alice.isNormalUser = true;

      systemd.tmpfiles.rules = [
        "d /var/lib/neighbour 0755 root root -"
        "f /var/lib/neighbour/data 0644 root root - neighbour"
      ];

      environment.systemPackages = [
        pkgs.age
        pkgs.curl
        pkgs.jq
        pkgs.iproute2
        pkgs.python3
        pkgs.util-linux
        config.networking.firewall.package
        config.services.hasala.database.package
      ];
    };

  testScript =
    { nodes, ... }:
    let
      hasalad = lib.getExe nodes.machine.services.hasala.package;
    in
    ''
      import hashlib
      import json
      import re

      API = "http://127.0.0.1:${toString apiPort}"
      CONSOLE_PORT = ${toString consolePort}
      CONSOLE_METRICS_PORT = ${toString consoleMetricsPort}
      HASALAD = "${hasalad}"
      PSQL = "psql --no-psqlrc -h /run/hasala-postgresql -d hasala -Atc"
      BACKUP_DIR = "/var/lib/hasala-backup/dumps"


      def bech32(hrp, data):
          charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
          gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

          def polymod(values):
              chk = 1
              for v in values:
                  b = chk >> 25
                  chk = (chk & 0x1FFFFFF) << 5 ^ v
                  for i in range(5):
                      chk ^= gen[i] if (b >> i) & 1 else 0
              return chk

          acc, bits = 0, 0
          five: list[int] = []
          for byte in data:
              acc = (acc << 8) | byte
              bits += 8
              while bits >= 5:
                  bits -= 5
                  five.append((acc >> bits) & 31)
          if bits:
              five.append((acc << (5 - bits)) & 31)
          expanded = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
          pm = polymod(expanded + five + [0] * 6) ^ 1
          five += [(pm >> 5 * (5 - i)) & 31 for i in range(6)]
          return hrp + "1" + "".join(charset[d] for d in five)


      # The test identity: derived here, so no age secret key is committed.
      IDENTITY = bech32(
          "age-secret-key-", hashlib.sha256(b"hasala-vm-test-identity").digest()
      ).upper()


      def as_user(user, cmd):
          return f"runuser -u {user} -- {cmd}"


      def http_code(cmd):
          return machine.succeed(cmd + " -s -o /dev/null -w '%{http_code}'").strip()


      start_all()

      with subtest("AT-V1: the target, the database, migrations and the API come up"):
          machine.wait_for_unit("hasala-postgresql.service")
          machine.wait_for_unit("hasala-db-setup.service")
          machine.wait_for_unit("hasalad.service")
          machine.wait_until_succeeds(f"curl -sf {API}/api/v1/healthz")
          machine.succeed("systemctl is-active hasala.target")
          assert machine.succeed("systemctl show -P Result hasala-migrate.service").strip() == "success"
          machine.succeed("journalctl -u hasala-migrate -o cat | grep 'hasalad migrate: done' >/dev/null")

      with subtest("AT-V2: the API answers on loopback"):
          body = json.loads(machine.succeed(f"curl -sf {API}/api/v1/healthz"))
          assert body == {"status": "ok", "db": "ok"}, body

      with subtest("AT-V3: nothing listens on a non-loopback address"):
          for line in machine.succeed("ss -ltnH").splitlines():
              local = line.split()[3]
              host = local.rsplit(":", 1)[0]
              assert host in ("127.0.0.1", "[::1]"), f"TCP listener on {local}: {line}"
          machine.fail("ss -ltnpH | grep postgres >/dev/null")
          addr = machine.succeed(
              "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1"
          ).strip()
          assert addr, "the VM has no global address to probe"
          machine.fail(f"curl -s --max-time 5 http://{addr}:${toString apiPort}/api/v1/healthz")

      with subtest("AT-V4: peer authentication maps OS users to roles, nobody else"):
          machine.succeed(as_user("hasala", f"{PSQL} 'select 1' -U hasala_runtime"))
          machine.fail(as_user("hasala", f"{PSQL} 'select 1' -U hasala_migrate"))
          machine.fail(as_user("hasala", f"{PSQL} 'select 1' -U hasala_su"))
          machine.fail(as_user("alice", f"{PSQL} 'select 1' -U hasala_runtime"))
          machine.fail(as_user("nobody", f"{PSQL} 'select 1' -U hasala_runtime"))
          machine.fail(f"{PSQL} 'select 1' -U hasala_runtime")
          machine.fail(f"{PSQL} 'select 1' -U hasala_su")
          machine.succeed(as_user("hasala-migrate", f"{PSQL} 'select 1' -U hasala_migrate"))
          machine.succeed(as_user("hasala-backup", f"{PSQL} 'select 1' -U hasala_backup"))

      with subtest("AT-V5: the runtime role has DML only"):
          rt = lambda q: as_user("hasala", f"{PSQL} \"{q}\" -U hasala_runtime")
          machine.fail(rt("CREATE TABLE x(i int)"))
          machine.fail(rt("ALTER TABLE op_log DISABLE TRIGGER ALL"))
          machine.fail(rt("DELETE FROM op_log"))
          owner = machine.succeed(rt("SELECT tableowner FROM pg_tables WHERE tablename='op_log'")).strip()
          assert owner == "hasala_migrate", owner
          timeout = machine.succeed(rt("SHOW statement_timeout")).strip()
          assert timeout == "15s", timeout

      with subtest("AT-V6: serve refuses to run as the schema owner"):
          out = machine.fail(
              "runuser -u hasala-migrate -- env"
              " HASALA_PG_DSN='host=/run/hasala-postgresql dbname=hasala user=hasala_migrate'"
              " HASALA_RP_ID=hasala.app HASALA_RP_ORIGINS=https://hasala.app"
              " HASALA_HEADROOM_PATH=/tmp HASALA_HTTP_LISTEN=127.0.0.1:18471"
              # The driver runs every command under `set -euo pipefail`.
              f" {HASALAD} serve 2>&1 || echo exit=$?; false"
          )
          assert "exit=2" in out and "O2" in out, out

      with subtest("AT-V7: Postgres never logs a refused row"):
          machine.fail(
              as_user(
                  "hasala-migrate",
                  f"{PSQL} \"CREATE TEMP TABLE canary(v text CHECK (v <> 'HASALA-LOG-CANARY'));"
                  " INSERT INTO canary VALUES ('HASALA-LOG-CANARY')\" -U hasala_migrate",
              )
          )
          machine.wait_until_succeeds("journalctl -u hasala-postgresql -o cat | grep 'violates check constraint' >/dev/null")
          machine.fail("journalctl -u hasala-postgresql -o cat | grep HASALA-LOG-CANARY >/dev/null")

      with subtest("AT-V8: a restart re-runs migrations as a no-op, with no pre-migration dump"):
          runs = lambda: int(machine.succeed("journalctl -u hasala-migrate -o cat | grep -c 'hasalad migrate: done' || true").strip())
          before = runs()
          machine.succeed("systemctl restart hasalad.service")
          machine.wait_for_unit("hasalad.service")
          machine.wait_until_succeeds(f"curl -sf {API}/api/v1/healthz")
          # At least one more run: a console start (and its restarts while it
          # is not built) also pulls hasala-migrate in.
          assert runs() > before, (before, runs())
          machine.succeed("journalctl -u hasala-backup-premigrate -o cat | grep 'no pending migrations' >/dev/null")
          machine.fail(f"ls {BACKUP_DIR} | grep premigrate >/dev/null")

      with subtest("AT-V9: hasala-admin runs each mode in a sandbox, as root only"):
          for mode in ["invite", "purge-user", "verify", "version", "migrate"]:
              machine.succeed(f"hasala-admin {mode} --help")
          machine.succeed("hasala-admin version | grep '^hasalad ' >/dev/null")
          code = machine.succeed("hasala-admin invite mint --note vm-note-text 2>/dev/null").strip()
          assert re.fullmatch(r"[A-Z2-7]{24}", code), code
          machine.succeed("hasala-admin migrate --status | grep '^pending 0$' >/dev/null")
          machine.succeed("journalctl -t hasala-admin -o cat | grep 'mode=invite by=root' >/dev/null")
          # Nowhere in the journal: not from the wrapper, not from systemd's
          # "Started <unit>" line, not from hasalad.
          machine.fail("journalctl -o cat | grep vm-note-text >/dev/null")
          machine.fail("hasala-admin console")
          machine.fail("hasala-admin serve")
          machine.fail(as_user("alice", "hasala-admin version"))

      with subtest("AT-V10: an encrypted backup that only the identity opens"):
          machine.succeed(f"printf '%s\\n' '{IDENTITY}' > /root/test-identity.txt && chmod 600 /root/test-identity.txt")
          machine.succeed("age-keygen -o /root/other-identity.txt 2>/dev/null")
          machine.succeed("systemctl start hasala-backup.service")
          dump = machine.succeed(f"ls {BACKUP_DIR}/hasala-daily-*.dump.age").strip()
          machine.succeed(f"test -f {dump}.sha256")
          machine.succeed(f"cd {BACKUP_DIR} && sha256sum -c {dump.rsplit('/', 1)[1]}.sha256")
          assert machine.succeed(f"stat -c %a {dump}").strip() == "600"
          assert machine.succeed(f"stat -c '%a %U' {BACKUP_DIR}").strip() == "700 hasala-backup"
          machine.fail(f"age -d -i /root/other-identity.txt {dump} > /dev/null")
          machine.succeed(
              f"age -d -i /root/test-identity.txt {dump} | pg_restore --list | grep ' TABLE DATA public op_log ' >/dev/null"
          )
          ledger = machine.succeed(f"ls {BACKUP_DIR}/hasala-ledger-*.tar.age").strip()
          machine.succeed(f"age -d -i /root/test-identity.txt {ledger} | tar -tf - > /dev/null")
          machine.succeed("test ! -e /run/hasala-backup || test -z \"$(ls -A /run/hasala-backup)\"")
          machine.succeed("systemctl start hasala-backup-check.service")

      with subtest("AT-V11: retention deletes everything 29 days old or older"):
          for kind in ["daily", "premigrate"]:
              for age in range(1, 41):
                  f = f"{BACKUP_DIR}/hasala-{kind}-seed{age:02d}.dump.age"
                  machine.succeed(f"touch -d '{age} days ago' {f} && chown hasala-backup: {f}")
          for age in range(1, 41):
              f = f"{BACKUP_DIR}/hasala-ledger-seed{age:02d}.tar.age"
              machine.succeed(f"touch -d '{age} days ago' {f} && chown hasala-backup: {f}")
          machine.succeed("systemctl start hasala-backup.service")
          left = machine.succeed(f"ls {BACKUP_DIR} | grep seed").split()
          ages = sorted({int(n.split("seed", 1)[1][:2]) for n in left})
          assert ages == list(range(1, 29)), ages
          assert len(left) == 3 * 28, len(left)
          machine.succeed("systemctl start hasala-backup-check.service")
          machine.succeed(f"touch -d '30 days ago' {BACKUP_DIR}/hasala-daily-planted.dump.age")
          machine.fail("systemctl start hasala-backup-check.service")
          machine.succeed(f"rm {BACKUP_DIR}/hasala-daily-planted.dump.age {BACKUP_DIR}/*seed*")
          machine.succeed("systemctl reset-failed hasala-backup-check.service")

      with subtest("AT-V13: the API's sandbox"):
          pid = machine.succeed("systemctl show -P MainPID hasalad.service").strip()
          machine.fail(f"nsenter -t {pid} -m -- cat /var/lib/neighbour/data")
          machine.fail(f"nsenter -t {pid} -m -- ls /run/credentials/hasala-console.service")
          machine.succeed(f"nsenter -t {pid} -m -- test -r /run/credentials/hasalad.service/auth-key")
          props = machine.succeed(
              "systemctl show hasalad.service -p User -p NoNewPrivileges -p ProtectSystem"
              " -p PrivateDevices -p CapabilityBoundingSet -p IPAddressDeny -p RestrictAddressFamilies"
          )
          print(props)
          assert "User=hasala" in props and "NoNewPrivileges=yes" in props, props
          assert "ProtectSystem=strict" in props and "PrivateDevices=yes" in props, props
          assert re.search(r"^CapabilityBoundingSet=$", props, re.M), props
          for net in ["10.0.0.0/8", "192.168.0.0/16", "100.64.0.0/10"]:
              assert net in props, (net, props)
          machine.succeed("systemctl show -P PrivateNetwork hasala-postgresql.service | grep -x yes >/dev/null")
          # The secrets are only ever *_FILE paths into the credentials directory.
          env = machine.succeed("systemctl show -P Environment hasalad.service")
          assert "/run/credentials/hasalad.service/auth-key" in env or "%d/auth-key" in env, env
          assert "hasala-vm-secrets" not in env, env
          auth_key = machine.succeed("cat /var/lib/hasala-vm-secrets/auth-key").strip()
          assert auth_key not in env, "the auth key's value is in the environment"
          # The dummy secrets live outside the store, root-only (M22).
          assert machine.succeed("stat -c '%a %U' /var/lib/hasala-vm-secrets/auth-key").strip() == "400 root"
          # Egress (spec AT-V13): from inside hasalad's cgroup, where
          # IPAddressDeny's BPF filter applies, a packet to the LAN range is
          # refused with EPERM. UDP reports it synchronously; a TCP connect
          # must never complete (Linux's tcp_connect ignores the filter's
          # error on the SYN, so its errno is printed, not asserted). A /32
          # route on the test network makes the address routable, so EPERM is
          # the filter's answer, not ENETUNREACH. Outside the cgroup the same
          # UDP send goes out.
          dev = machine.succeed("ip -4 -o addr show scope global | awk '{print $2}' | head -1").strip()
          machine.succeed(f"ip route replace 10.9.9.9/32 dev {dev}")
          cg = machine.succeed("systemctl show -P ControlGroup hasalad.service").strip()
          probe = "$(command -v python3) /etc/hasala-vm/egress.py 10.9.9.9"
          inside = machine.succeed(f"sh -c 'echo $$ > /sys/fs/cgroup{cg}/cgroup.procs && exec {probe}'")
          print(inside)
          assert "udp=EPERM" in inside, inside
          assert "tcp=connected" not in inside, inside
          outside = machine.succeed(probe)
          print(outside)
          assert "udp=sent" in outside, outside
          # Loopback stays open from the same cgroup.
          machine.succeed(f"sh -c 'echo $$ > /sys/fs/cgroup{cg}/cgroup.procs && exec curl -sf {API}/api/v1/healthz'")
          machine.succeed("ip route del 10.9.9.9/32")
          print(machine.succeed("systemd-analyze security hasalad.service hasala-postgresql.service hasala-console.service | tail -n 3 || true"))

      with subtest("AT-V17/V18/V19: the console and its kernel rule"):
          machine.wait_until_succeeds(
              "systemctl is-active hasala-console.service"
              " || journalctl -u hasala-console -o cat | grep 'not built yet' >/dev/null"
          )
          built = machine.execute("systemctl is-active hasala-console.service")[0] == 0
          if not built:
              # The whole console environment passed the server's own checks
              # (fence F7-4 and spec 07 §8.1): the only refusal is "not built".
              console_log = machine.succeed("journalctl -u hasala-console -o cat")
              assert "operator console is not built yet" in console_log, console_log
              for refusal in ["refuses to start with", "HASALA_CONSOLE_", "is under the RP ID", "HASALA_TESTFLIGHT_MODE is"]:
                  assert refusal not in console_log, (refusal, console_log)
              print("SKIPPED: console header checks (internal/console is not built yet, spec 07 §8, WS-19)")
              machine.succeed("systemctl stop hasala-console.service; systemctl reset-failed hasala-console.service || true")
              machine.succeed(
                  "systemd-run --unit=console-standin --uid=hasala-console --gid=hasala-console"
                  " -p WorkingDirectory=/var/empty"
                  f" $(command -v python3) -m http.server --bind 127.0.0.1 {CONSOLE_PORT}"
              )
          # The console never listens on ::1 (no option for it); a stand-in
          # there proves the ip6tables twin (spec 05 §5.14, F-11) bites too.
          machine.succeed(
              "systemd-run --unit=console-standin6 --uid=hasala-console --gid=hasala-console"
              " -p WorkingDirectory=/var/empty"
              f" $(command -v python3) -m http.server --bind ::1 {CONSOLE_PORT}"
          )
          machine.wait_until_succeeds(f"ss -ltnH 'sport = :{CONSOLE_PORT}' | grep '127.0.0.1:{CONSOLE_PORT}' >/dev/null")
          machine.wait_until_succeeds(f"ss -ltnH 'sport = :{CONSOLE_PORT}' | grep -F '[::1]:{CONSOLE_PORT}' >/dev/null")
          machine.succeed(f"ip6tables -w -S OUTPUT | grep -- '-d ::1/128 .*--dport {CONSOLE_PORT} -j hasala-console-out' >/dev/null")
          url = f"http://127.0.0.1:{CONSOLE_PORT}/"
          url6 = f"http://[::1]:{CONSOLE_PORT}/"
          # The kernel rule: root, a user shell and a DynamicUser service (as
          # cloudflared runs) all get a reset; only the nginx user connects.
          for u in [url, url6]:
              machine.fail(f"curl -sg --max-time 5 {u}")
              machine.fail(as_user("alice", f"curl -sg --max-time 5 {u}"))
              machine.fail(as_user("hasala", f"curl -sg --max-time 5 {u}"))
              machine.fail(f"systemd-run --wait --pipe -p DynamicUser=yes $(command -v curl) -sg --max-time 5 {u}")
              machine.succeed(as_user("nginx", f"curl -sg --max-time 5 -o /dev/null {u}"))

          # P10 (spec 05 §5.9.3): hasala-health, a DynamicUser, reports
          # nothing while the rule holds, and reports P10 once it is gone.
          def health_run():
              since = machine.succeed("date +%s").strip()
              machine.execute("systemctl start hasala-health.service")
              machine.succeed("sleep 1")
              return machine.succeed(f"journalctl -u hasala-health -o cat --since @{since}")

          out = health_run()
          print(out)
          assert "P10" not in out, out
          machine.succeed(f"iptables -w -D OUTPUT -o lo -p tcp -d 127.0.0.1 --dport {CONSOLE_PORT} -j hasala-console-out")
          out = health_run()
          print(out)
          assert f"P10 http://127.0.0.1:{CONSOLE_PORT}/" in out, out
          machine.succeed("systemctl restart firewall.service")
          machine.succeed(f"iptables -w -C OUTPUT -o lo -p tcp -d 127.0.0.1 --dport {CONSOLE_PORT} -j hasala-console-out")
          machine.fail(f"curl -s --max-time 5 {url}")
          machine.succeed("systemctl reset-failed hasala-health.service || true")
          if built:
              ok = [
                  "-H 'Host: ${consoleHost}'",
                  "-H 'X-Forwarded-Proto: https'",
                  "-H 'X-Webauth-User: ${consoleLogin}'",
                  "-H 'X-Webauth-Tailnet: ${consoleTailnet}'",
              ]
              base = as_user("nginx", f"curl --max-time 5 {url}")
              assert http_code(base + " " + " ".join(ok)) == "200"
              assert http_code(base + " " + " ".join(ok[:2] + ok[3:])) == "403", "no identity header"
              assert http_code(base + " " + " ".join(ok[:2] + ["-H 'X-Webauth-User: someone@else'"] + ok[3:])) == "403"
              health_url = f"http://127.0.0.1:{CONSOLE_METRICS_PORT}/healthz"
              health = json.loads(machine.succeed(as_user("alice", f"curl -sf {health_url}")))
              assert health.get("status") == "ok" and health.get("asc") == "disabled", health
              assert health.get("tunnel_refusals_24h") == 0, health
              for extra in ["Cf-Connecting-Ip: 192.0.2.1", "Cf-Ray: 0000000000000000-AAA", "CF-Visitor: {}", "Cdn-Loop: cloudflare"]:
                  assert http_code(base + " " + " ".join(ok) + f" -H '{extra}'") == "403", extra
              # Spec 07 §13.3: a Cloudflare header at the console is a tunnel
              # leak, and /healthz turns 503 for 24 hours so P8 pages.
              assert http_code(as_user("alice", f"curl --max-time 5 {health_url}")) == "503"
              health = json.loads(machine.succeed(as_user("alice", f"curl -s {health_url}")))
              assert health.get("status") == "fail" and health.get("tunnel_refusals_24h") == 4, health
              pid = machine.succeed("systemctl show -P MainPID hasala-console.service").strip()
              machine.fail(f"nsenter -t {pid} -m -- ls /run/credentials/hasalad.service")
          else:
              machine.succeed("systemctl stop console-standin.service")
          machine.succeed("systemctl stop console-standin6.service")
          for line in machine.succeed("ss -ltnH").splitlines():
              assert line.split()[3].rsplit(":", 1)[0] in ("127.0.0.1", "[::1]"), line

      with subtest("AT-V12: a cluster of another major version stops the start"):
          machine.succeed("systemctl stop hasala.target")
          machine.succeed("install -d -o hasala-pg -g hasala-db -m 700 /var/lib/hasala-postgresql/16")
          machine.succeed("echo 16 > /var/lib/hasala-postgresql/16/PG_VERSION")
          machine.fail("systemctl start hasala-postgresql.service")
          machine.succeed("journalctl -u hasala-postgresql -o cat | grep 'Dump and restore first' >/dev/null")
          machine.succeed("rm -r /var/lib/hasala-postgresql/16")
          machine.succeed("systemctl reset-failed")
          machine.succeed("systemctl start hasala.target")
          machine.wait_for_unit("hasalad.service")
          machine.wait_until_succeeds(f"curl -sf {API}/api/v1/healthz")

      with subtest("AT-V14: the kill switch stops everything"):
          machine.succeed("systemctl stop hasala.target")
          for unit in ["hasalad", "hasala-postgresql", "hasala-console"]:
              machine.fail(f"systemctl is-active {unit}.service")
          machine.fail(f"curl -s --max-time 5 {API}/api/v1/healthz")
    '';
}
