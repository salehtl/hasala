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

    [ "$failed" = 0 ]
    touch "$out"
  ''
