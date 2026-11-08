{
  self,
  nixpkgs,
  pkgs,
}:
let
  inherit (nixpkgs) lib;
  t = import ./lib.nix { inherit self nixpkgs; };
  recipient = "age1uqtdju3geshs2ad6fc6jj0eg22g8xwhe74w09vdwlp5vpfqazpnq779v4u";
  rendered =
    (t.evalSystem {
      services.hasala.backup = {
        enable = true;
        dir = "/hasala-test-backups";
        ageRecipients = [ recipient ];
        dumpTimeoutSec = 2;
      };
    }).config.services.hasala.renderedScripts;

  localPaths =
    text:
    builtins.replaceStrings
      [
        "/hasala-test-backups"
        "/var/lib/hasala-ledger"
        "/run/hasala-maintenance.lock"
      ]
      [
        "./backups"
        "./ledger"
        "./maintenance.lock"
      ]
      (builtins.unsafeDiscardStringContext text);

  stub = pkgs.writeShellScriptBin;
  stubs = [
    (stub "pg_dump" ''
      [ -z "''${PG_DUMP_FAIL:-}" ] || exit 1
      [ -z "''${PG_DUMP_SLEEP:-}" ] || sleep "$PG_DUMP_SLEEP"
      printf 'synthetic dump\n'
    '')
    (stub "pg_restore" ''
      cat > /dev/null
      echo '42; 0 1 TABLE DATA public op_log owner'
    '')
    (stub "age" ''
      out=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) out="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      if [ -n "''${AGE_FAIL_ON:-}" ] && [[ "$out" == *"$AGE_FAIL_ON"* ]]; then
        cat > /dev/null
        printf 'partial' > "$out"
        exit 1
      fi
      cat > "$out"
    '')
    (stub "id" "echo 0")
    (stub "logger" "true")
    (stub "chown" "true")
    (stub "systemctl" ''
      echo "systemctl $*" >> "$CALLS"
      exit "''${SYSTEMCTL_EXIT:-0}"
    '')
    (stub "systemd-run" ''
      echo "systemd-run $*" >> "$CALLS"
    '')
    (stub "flock" ''
      [ "$1" != 9 ] || exit 0
      echo "flock $1 $2" >> "$CALLS"
      shift 2
      exec "$@"
    '')
  ];

  backup = pkgs.writeShellApplication {
    name = "hasala-backup";
    runtimeInputs = stubs ++ [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnutar
    ];
    text = localPaths rendered.backup;
  };

  admin = pkgs.writeShellApplication {
    name = "hasala-admin";
    runtimeInputs = stubs ++ [ pkgs.coreutils ];
    text = builtins.unsafeDiscardStringContext rendered.admin;
  };

  bump = pkgs.writeShellApplication {
    name = "hasala-bump-generation";
    runtimeInputs = stubs ++ [ pkgs.coreutils ];
    text = localPaths rendered.bumpGeneration;
  };

  curlStub = stub "curl" ''
    out=/dev/null
    headers=/dev/null
    url=""
    post=""
    fail=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        -w | --max-time) shift 2 ;;
        -d) post="$2"; shift 2 ;;
        -sf | -f | --fail) fail=1; shift ;;
        -*) shift ;;
        *) url="$1"; shift ;;
      esac
    done
    if [ -n "$post" ]; then
      echo "$post" >> "$POSTS"
      if [ "''${NTFY_STATUS:-200}" != 200 ] && [ -n "$fail" ]; then exit 22; fi
      exit 0
    fi
    body='{"status":"ok"}'
    type=text/plain
    want=200
    case "$url" in
      http://127.0.0.1:8471/api/v1/healthz) probe=P1 ;;
      https://api.hasala.app/api/v1/healthz) probe=P2 ;;
      */metrics | */admin/) probe=P3; want=404 ;;
      */api/v1/console) probe=P9; want=404 ;;
      */apple-app-site-association)
        probe=P5
        type=application/json
        body='{"webcredentials":{"apps":["8CFG28JHP3.app.hasala.ios"]},"applinks":{"details":[{"components":[{"/":"/i/*"}]}]}}'
        ;;
      http://127.0.0.1:9473/healthz) probe=P8 ;;
      *:8472/)
        case " ''${DOWN:-} " in *" P10 "*) exit 0 ;; esac
        exit 7
        ;;
      *) echo "curl stub: unexpected url $url" >&2; exit 99 ;;
    esac
    case " ''${DOWN:-} " in *" $probe "*) want=503 ;; esac
    printf '%s' "$body" > "$out"
    printf 'HTTP/2 %s\r\ncontent-type: %s\r\n' "$want" "$type" > "$headers"
    printf '%s' "$want"
  '';

  healthWith =
    extra:
    pkgs.writeShellApplication {
      name = "hasala-health";
      runtimeInputs = [
        curlStub
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
      ];
      text =
        builtins.unsafeDiscardStringContext
          (t.evalSystem { services.hasala = extra; }).config.services.hasala.renderedScripts.health;
    };
  ntfy.monitoring.ntfyUrl = "http://127.0.0.1:2586/test";
  healthAll = healthWith (
    ntfy
    // {
      tunnel.enable = true;
      console.enable = true;
    }
  );
  healthApi = healthWith ntfy;
  healthQuiet = healthWith { };

  retry = pkgs.writeShellApplication {
    name = "hasala-retry";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.unsafeDiscardStringContext rendered.retry;
  };
in
pkgs.runCommand "hasala-ops-scripts"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    failed=0
    no() { echo "FAIL: $1"; failed=1; }

    scenario() {
      echo "--- $1"
      rm -rf "$TMPDIR/s"
      mkdir -p "$TMPDIR/s/backups" "$TMPDIR/s/ledger" "$TMPDIR/s/run" "$TMPDIR/s/state"
      cd "$TMPDIR/s"
      : > maintenance.lock
      echo 'synthetic ledger line' > ledger/purged
      export RUNTIME_DIRECTORY="$PWD/run" STATE_DIRECTORY="$PWD/state" CALLS="$PWD/calls"
      : > "$CALLS"
    }
    count() { find backups -maxdepth 1 -name "$1" | wc -l | tr -d ' '; }
    run_backup() { rc=0; ${lib.getExe backup} "$@" > out.log 2>&1 || rc=$?; cat out.log; }

    scenario "a backup publishes the dump, its checksum and the ledger copy"
    run_backup daily
    [ "$rc" = 0 ] || no "a clean backup exited $rc"
    [ "$(count 'hasala-daily-*.dump.age')" = 1 ] || no "no dump published"
    [ "$(count 'hasala-daily-*.dump.age.sha256')" = 1 ] || no "no checksum published"
    [ "$(count 'hasala-ledger-daily-*.tar.age')" = 1 ] || no "no ledger copy published"
    [ "$(count '*.part')" = 0 ] || no "a .part file is left after a clean backup"
    (cd backups && sha256sum -c ./*.sha256 > /dev/null) || no "the checksum does not match the dump"
    [ -s state/last-success-daily ] || no "the success mark is missing"

    for failing in hasala-ledger .dump.age; do
      scenario "age fails on the $failing file: nothing is left without its other half"
      AGE_FAIL_ON="$failing" run_backup daily
      [ "$rc" != 0 ] || no "a backup whose $failing file failed exited 0"
      [ "$(count 'hasala-daily-*.dump.age')" = 0 ] || no "$failing failed and a dump is published"
      [ "$(count '*.sha256')" = 0 ] || no "$failing failed and a checksum is published"
      [ "$(count '*.part')" = 0 ] || no "$failing failed and a .part file is left"
      [ ! -e state/last-success-daily ] || no "$failing failed and the success mark is written"
    done

    scenario "a missing purge ledger publishes no dump"
    rm ledger/purged
    run_backup daily
    [ "$rc" != 0 ] || no "a missing ledger exited 0"
    [ "$(count 'hasala-daily-*.dump.age')" = 0 ] || no "a missing ledger left a published dump"
    [ "$(count '*.sha256')" = 0 ] || no "a missing ledger left a checksum"

    for tag in daily premigrate; do
      scenario "a $tag backup that fails still applies retention"
      touch -d '40 days ago' backups/hasala-daily-seed40.dump.age
      touch -d '29 days ago' backups/hasala-ledger-daily-seed29.tar.age
      touch -d '29 days ago' backups/hasala-premigrate-seed29.dump.age.sha256
      touch -d '28 days ago' backups/hasala-daily-seed28.dump.age
      PG_DUMP_FAIL=1 run_backup "$tag"
      [ "$rc" != 0 ] || no "a failing $tag backup exited 0"
      [ ! -e backups/hasala-daily-seed40.dump.age ] || no "a failing $tag backup kept a 40 day old dump"
      [ ! -e backups/hasala-ledger-daily-seed29.tar.age ] || no "a failing $tag backup kept a 29 day old ledger copy"
      [ ! -e backups/hasala-premigrate-seed29.dump.age.sha256 ] || no "a failing $tag backup kept a 29 day old checksum"
      [ -e backups/hasala-daily-seed28.dump.age ] || no "a failing $tag backup deleted a 28 day old dump"
    done

    scenario "a dump that outlasts its limit is stopped and publishes nothing"
    PG_DUMP_SLEEP=20 run_backup daily
    [ "$rc" != 0 ] || no "a dump past its limit exited 0"
    [ "$(count 'hasala-daily-*.dump.age')" = 0 ] || no "a dump past its limit was published"
    [ "$(count '*.part')" = 0 ] || no "a dump past its limit left a .part file"
    [ ! -e state/last-success-daily ] || no "a dump past its limit wrote the success mark"

    scenario "a backup that succeeds still applies retention"
    touch -d '29 days ago' backups/hasala-daily-seed29.dump.age
    run_backup daily
    [ "$rc" = 0 ] || no "a clean backup with an old file exited $rc"
    [ ! -e backups/hasala-daily-seed29.dump.age ] || no "a clean backup kept a 29 day old dump"
    [ "$(count 'hasala-daily-2*.dump.age')" = 1 ] || no "retention removed the new dump"

    scenario "a command that fails twice and then succeeds is retried to success"
    cat > flaky <<'SH'
    #!${pkgs.runtimeShell}
    echo x >> tries
    [ "$(wc -l < tries)" -ge 3 ]
    SH
    chmod +x flaky
    rc=0; ${lib.getExe retry} 4 0 ./flaky || rc=$?
    [ "$rc" = 0 ] || no "the retry gave up with $rc on a command that recovers"
    [ "$(wc -l < tries | tr -d ' ')" = 3 ] || no "the retry ran $(wc -l < tries) times, want 3"

    scenario "a command that keeps failing stops at the bound with its own exit code"
    cat > broken <<'SH'
    #!${pkgs.runtimeShell}
    echo x >> tries
    exit 7
    SH
    chmod +x broken
    rc=0; ${lib.getExe retry} 4 0 ./broken || rc=$?
    [ "$rc" = 7 ] || no "the retry exited $rc, want the command's 7"
    [ "$(wc -l < tries | tr -d ' ')" = 4 ] || no "the retry ran $(wc -l < tries) times, want 4"

    scenario "a command that succeeds runs once"
    cat > fine <<'SH'
    #!${pkgs.runtimeShell}
    echo x >> tries
    SH
    chmod +x fine
    rc=0; ${lib.getExe retry} 4 0 ./fine || rc=$?
    [ "$rc" = 0 ] || no "a command that succeeds exited $rc"
    [ "$(wc -l < tries | tr -d ' ')" = 1 ] || no "a command that succeeds ran more than once"

    run_admin() { rc=0; ${lib.getExe admin} "$@" > out.log 2>&1 < /dev/null || rc=$?; cat out.log; }
    called() { grep -c "$1" "$CALLS" | tr -d ' '; }

    for flag in --status -status --pending -pending --help -help -h; do
      scenario "hasala-admin migrate $flag only reads"
      run_admin migrate "$flag"
      [ "$rc" = 0 ] || no "migrate $flag exited $rc"
      [ "$(called '^systemd-run ')" = 1 ] || no "migrate $flag did not reach hasalad"
      [ "$(called '^systemctl ')" = 0 ] || no "migrate $flag started a dump"
      [ "$(called '^flock ')" = 0 ] || no "migrate $flag took the maintenance lock"
    done

    check_migrates() {
      [ "$rc" = 0 ] || no "$1 exited $rc"
      [ "$(sed -n 1p "$CALLS")" = "systemctl start hasala-backup-premigrate.service" ] \
        || no "$1 did not start the pre-migration dump first: $(cat "$CALLS")"
      [ "$(sed -n 2p "$CALLS")" = "flock --no-fork /run/hasala-maintenance.lock" ] \
        || no "$1 did not take the maintenance lock second: $(cat "$CALLS")"
      sed -n 3p "$CALLS" | grep -q '^systemd-run .* migrate' || no "$1 did not run hasalad migrate third: $(cat "$CALLS")"
    }

    scenario "hasala-admin migrate dumps first and holds the maintenance lock"
    run_admin migrate
    check_migrates "migrate"

    scenario "hasala-admin migrate --to dumps first and holds the maintenance lock"
    run_admin migrate --to 5
    check_migrates "migrate --to 5"

    scenario "a read-only flag turned off is a real migration"
    run_admin migrate --status=false
    check_migrates "migrate --status=false"

    scenario "a read-only flag with another argument is a real migration"
    run_admin migrate --status --to 5
    check_migrates "migrate --status --to 5"

    scenario "a pre-migration dump that fails stops hasala-admin migrate"
    SYSTEMCTL_EXIT=1 run_admin migrate
    [ "$rc" != 0 ] || no "a failed dump let migrate exit 0"
    [ "$(called '^systemd-run ')" = 0 ] || no "a failed dump still reached hasalad"
    [ "$(called '^flock ')" = 0 ] || no "a failed dump still took the lock"

    scenario "other modes neither dump nor lock"
    run_admin version
    [ "$rc" = 0 ] || no "version exited $rc"
    [ "$(called '^systemd-run ')" = 1 ] || no "version did not reach hasalad"
    [ "$(called '^systemctl ')" = 0 ] || no "version started a dump"
    [ "$(called '^flock ')" = 0 ] || no "version took the lock"

    run_bump() { rc=0; ${lib.getExe bump} > out.log 2>&1 || rc=$?; cat out.log; }

    scenario "a host that lost its generation file gets a value above every counter"
    run_bump
    [ "$rc" = 0 ] || no "a lost generation file exited $rc"
    [ "$(cat ledger/generation)" -gt 1000000000 ] || no "a lost generation file became $(cat ledger/generation), a value an iPhone may hold"
    [ "$(find ledger -name 'generation.*' | wc -l | tr -d ' ')" = 0 ] || no "a temporary file is left"

    scenario "a counter moves past every value it has held"
    echo 2 > ledger/generation
    run_bump
    [ "$rc" = 0 ] || no "a counter exited $rc"
    [ "$(cat ledger/generation)" -gt 2 ] || no "generation 2 became $(cat ledger/generation)"

    scenario "two restores in one second still differ"
    run_bump
    first="$(cat ledger/generation)"
    run_bump
    [ "$(cat ledger/generation)" -gt "$first" ] || no "the second restore repeated $first"

    scenario "a value ahead of the clock still goes up"
    echo 99999999999 > ledger/generation
    run_bump
    [ "$(cat ledger/generation)" = 100000000000 ] || no "a value ahead of the clock became $(cat ledger/generation)"

    for bad in nope ""; do
      scenario "a generation file holding '$bad' stops the step and stays as it was"
      echo "$bad" > ledger/generation
      run_bump
      [ "$rc" != 0 ] || no "a file holding '$bad' exited 0"
      [ "$(cat ledger/generation)" = "$bad" ] || no "a file holding '$bad' was changed"
    done

    all=${lib.getExe healthAll}
    api=${lib.getExe healthApi}
    quiet=${lib.getExe healthQuiet}
    health() { rc=0; "$1" > out.log 2>&1 || rc=$?; cat out.log; }
    posted() { wc -l < "$POSTS" | tr -d ' '; }
    health_scenario() { scenario "$1"; export POSTS="$PWD/posts"; : > "$POSTS"; }

    health_scenario "a healthy run alerts and posts nothing"
    health "$all"
    [ "$rc" = 0 ] || no "a healthy run exited $rc"
    [ "$(posted)" = 0 ] || no "a healthy run posted"

    health_scenario "a probe alerts on its second failing run and posts one recovery"
    DOWN=P1 health "$api"
    [ "$rc" = 0 ] || no "the first failing run alerted"
    DOWN=P1 health "$api"
    [ "$rc" = 1 ] || no "the second failing run did not alert"
    DOWN=P1 health "$api"
    [ "$rc" = 0 ] || no "the third failing run alerted again"
    health "$api"
    [ "$rc" = 0 ] || no "the recovering run exited $rc"
    [ "$(cat "$POSTS")" = "hasala: recovered P1" ] || no "the recovery notice was: $(cat "$POSTS")"
    health "$api"
    [ "$(posted)" = 1 ] || no "the recovery was posted $(posted) times"

    health_scenario "a recovery notice that was not delivered goes out on a later run"
    DOWN=P1 health "$api"
    DOWN=P1 health "$api"
    NTFY_STATUS=500 health "$api"
    [ "$rc" = 0 ] || no "a lost notice failed the run with $rc"
    [ "$(posted)" = 1 ] || no "the first attempt posted $(posted) times"
    health "$api"
    [ "$(posted)" = 2 ] || no "the notice was not sent again after it was lost"
    [ "$(tail -n 1 "$POSTS")" = "hasala: recovered P1" ] || no "the second attempt posted: $(tail -n 1 "$POSTS")"
    health "$api"
    [ "$(posted)" = 2 ] || no "a delivered notice was sent again"

    health_scenario "a probe that alerts again drops the notice it still owes"
    DOWN=P1 health "$api"
    DOWN=P1 health "$api"
    NTFY_STATUS=500 health "$api"
    DOWN=P1 NTFY_STATUS=500 health "$api"
    [ "$rc" = 0 ] || no "one failure after a recovery alerted"
    [ "$(posted)" = 2 ] || no "one failure dropped the notice that was still owed"
    DOWN=P1 health "$api"
    [ "$rc" = 1 ] || no "the new outage did not alert"
    [ "$(posted)" = 2 ] || no "a probe that is down posted its old recovery"
    health "$api"
    [ "$(posted)" = 3 ] || no "the new outage posted no recovery"
    health "$api"
    [ "$(posted)" = 3 ] || no "the new recovery was posted twice"

    health_scenario "a probe switched off while alerting is not reported as recovered"
    DOWN=P2 health "$all"
    DOWN=P2 health "$all"
    [ "$rc" = 1 ] || no "the public probe did not alert"
    health "$api"
    [ "$rc" = 0 ] || no "the run with the probe off exited $rc"
    [ "$(posted)" = 0 ] || no "a probe that never passed was posted as recovered: $(cat "$POSTS")"
    [ ! -e state/failures.P2 ] || no "a probe that is off kept its failure count"
    DOWN=P2 health "$all"
    [ "$rc" = 0 ] || no "the first failure after switching back on alerted"
    DOWN=P2 health "$all"
    [ "$rc" = 1 ] || no "the probe did not alert again after switching back on"

    health_scenario "a probe switched off drops the notice it still owes"
    DOWN=P8 health "$all"
    DOWN=P8 health "$all"
    NTFY_STATUS=500 health "$all"
    [ "$(posted)" = 1 ] || no "the first attempt posted $(posted) times"
    health "$api"
    [ "$(posted)" = 1 ] || no "a probe that is off posted its old recovery"

    health_scenario "with no notice address a recovery is not kept"
    DOWN=P1 health "$quiet"
    DOWN=P1 health "$quiet"
    health "$quiet"
    [ "$(posted)" = 0 ] || no "a host with no address posted"
    [ "$(find state -name 'recovered.*' | wc -l | tr -d ' ')" = 0 ] || no "a host with no address kept an owed notice"

    [ "$failed" = 0 ]
    touch "$out"
  ''
