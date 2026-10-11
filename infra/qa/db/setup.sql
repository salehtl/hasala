-- Roles and database for Hasala's own PostgreSQL cluster (spec 05 §5.3.5).
-- Run by hasala-db-setup.service as hasala_su (the bootstrap superuser, peer
-- mapped from the OS user hasala-pg) on every start; idempotent.
--
-- Infra only creates the roles, the database and the schema's ownership. The
-- table, sequence and default-privilege grants to hasala_runtime belong to the
-- baseline migration (server/internal/pg/migrations), run as hasala_migrate.
--
-- hasala_console (spec 05 review 2 row 1, F-10) is not created yet: it waits
-- for spec 02/07's grant split (see infra/qa/nix/postgresql.nix).
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_migrate') THEN
    CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_runtime') THEN
    CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
      CONNECTION LIMIT 30;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hasala_backup') THEN
    CREATE ROLE hasala_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      CONNECTION LIMIT 2;
  END IF;
END $$;

GRANT pg_read_all_data TO hasala_backup;
ALTER ROLE hasala_backup  SET default_transaction_read_only = on;
ALTER ROLE hasala_runtime SET statement_timeout = '15s';
ALTER ROLE hasala_runtime SET lock_timeout = '5s';
ALTER ROLE hasala_runtime SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE hasala_migrate SET lock_timeout = '30s';
ALTER ROLE hasala_migrate SET statement_timeout = 0;

-- The builtin collation provider (PostgreSQL 17) keeps the cluster immune to
-- glibc collation changes when nixpkgs bumps glibc.
SELECT 'CREATE DATABASE hasala OWNER hasala_migrate TEMPLATE template0 ENCODING ''UTF8'' '
       'LOCALE ''C'' LOCALE_PROVIDER builtin BUILTIN_LOCALE ''C.UTF-8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'hasala') \gexec

REVOKE ALL     ON DATABASE hasala    FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres  FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
GRANT  CONNECT ON DATABASE hasala TO hasala_runtime, hasala_backup;  -- the owner, hasala_migrate, has it already

\connect hasala
ALTER SCHEMA public OWNER TO hasala_migrate;
REVOKE ALL   ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO hasala_runtime, hasala_backup;
