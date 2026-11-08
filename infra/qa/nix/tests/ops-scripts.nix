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
in
pkgs.runCommand "hasala-ops-scripts"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
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

    scenario "a backup that succeeds still applies retention"
    touch -d '29 days ago' backups/hasala-daily-seed29.dump.age
    run_backup daily
    [ "$rc" = 0 ] || no "a clean backup with an old file exited $rc"
    [ ! -e backups/hasala-daily-seed29.dump.age ] || no "a clean backup kept a 29 day old dump"
    [ "$(count 'hasala-daily-2*.dump.age')" = 1 ] || no "retention removed the new dump"

    [ "$failed" = 0 ]
    touch "$out"
  ''
