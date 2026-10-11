# Renderers for Hasala's own PostgreSQL cluster (spec 05 §5.3.2–§5.3.4):
# postgresql.conf, pg_hba.conf and pg_ident.conf. Imported by module.nix.
{ lib }:
rec {
  # §5.3.2. The keys a host may not override through database.settings (M9):
  # the socket, the auth files and every log_* key (security C7: nothing may
  # make the server echo a statement, a parameter or a failing row).
  forbiddenSetting =
    k:
    lib.elem k [
      "listen_addresses"
      "hba_file"
      "ident_file"
    ]
    || lib.hasPrefix "unix_socket_" k
    || lib.hasPrefix "log_" k;

  baseSettings = {
    listen_addresses = "";
    # 0770 octal: the socket's group is the server's group, hasala-db.
    unix_socket_permissions = 504;
    max_connections = 40;
    superuser_reserved_connections = 3;
    shared_buffers = "256MB";
    work_mem = "8MB";
    maintenance_work_mem = "64MB";
    effective_cache_size = "1GB";
    huge_pages = "off";
    dynamic_shared_memory_type = "posix";
    wal_level = "replica";
    max_wal_size = "1GB";
    min_wal_size = "80MB";
    checkpoint_timeout = "15min";
    fsync = "on";
    synchronous_commit = "on";
    full_page_writes = "on";
    password_encryption = "scram-sha-256";
    jit = "off";
    timezone = "UTC";
    log_timezone = "UTC";
    idle_in_transaction_session_timeout = "60s";
    log_destination = "stderr"; # journald
    logging_collector = "off";
    log_line_prefix = "%m [%p] %q%u@%d ";
    log_statement = "none"; # security C7
    log_min_duration_statement = -1;
    # Never echo the failing statement's text, and drop DETAIL: a CHECK
    # violation's DETAIL prints the whole failing row (a refused plaintext blob).
    log_min_error_statement = "panic";
    log_error_verbosity = "terse";
    log_parameter_max_length = 0;
    log_parameter_max_length_on_error = 0;
    log_connections = "off";
    log_disconnections = "off";
    log_checkpoints = "on";
    log_lock_waits = "on";
    shared_preload_libraries = "";
  };

  # Integers bare, everything else single-quoted with ' doubled.
  renderValue =
    v:
    if builtins.isInt v then
      toString v
    else if builtins.isBool v then
      (if v then "on" else "off")
    else
      "'" + lib.replaceStrings [ "'" ] [ "''" ] (toString v) + "'";

  renderConf =
    {
      settings,
      socketDir,
      hbaFile,
      identFile,
    }:
    let
      all = settings // {
        unix_socket_directories = socketDir;
        hba_file = "${hbaFile}";
        ident_file = "${identFile}";
      };
    in
    lib.concatStrings (
      lib.mapAttrsToList (k: v: "${k} = ${renderValue v}\n") (lib.filterAttrs (_: v: v != null) all)
    );

  # §5.3.3: peer authentication over the socket only, one line per role; every
  # other local connection and every TCP connection is rejected.
  hba = ''
    # TYPE  DATABASE  USER            ADDRESS    METHOD
    local   all       hasala_su                  peer map=hasala
    local   hasala    hasala_migrate             peer map=hasala
    local   hasala    hasala_runtime             peer map=hasala
    local   hasala    hasala_backup              peer map=hasala
    local   all       all                        reject
    host    all       all             0.0.0.0/0  reject
    host    all       all             ::/0       reject
  '';

  # §5.3.4: OS user → role. Root has no mapping. The console shares the runtime
  # role with serve and the CLI (spec 07 §14.1).
  ident =
    { console }:
    ''
      # MAP    SYSTEM-USERNAME  PG-USERNAME
      hasala   hasala-pg        hasala_su
      hasala   hasala-migrate   hasala_migrate
      hasala   hasala           hasala_runtime
      hasala   hasala-backup    hasala_backup
    ''
    + lib.optionalString console ''
      hasala   hasala-console   hasala_runtime
    '';
}
