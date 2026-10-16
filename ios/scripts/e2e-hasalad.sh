#!/usr/bin/env bash
# e2e-hasalad.sh: HasalaCore's live suite (spec 04 §19.1 T4) against a real
# hasalad on 127.0.0.1 with a throwaway Postgres on a unix socket.
#
#   nix develop -c ios/scripts/e2e-hasalad.sh <hasalad binary>
#
# Needs initdb, postgres, pg_isready and psql (the devShell has them) and the
# system Swift toolchain (Xcode). Everything lives in one temporary directory
# and is stopped and removed on exit. No external service is called.
set -euo pipefail

HASALAD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# /tmp, not $TMPDIR: Postgres's unix socket lives here, and a socket path
# longer than 103 bytes (a deep $TMPDIR on macOS) makes the server fail to start.
TMP="$(mktemp -d /tmp/hasala-e2e.XXXXXX)"
PORT="${HASALA_E2E_PORT:-18443}"
SERVER_PID=""

cleanup() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
	pg_ctl -D "$TMP/pg" -m immediate stop >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

initdb -D "$TMP/pg" -U postgres -A trust --no-sync >/dev/null
pg_ctl -D "$TMP/pg" -l "$TMP/pg.log" -o "-k $TMP -c listen_addresses='' -c fsync=off" start >/dev/null
for _ in $(seq 50); do pg_isready -h "$TMP" -q && break; sleep 0.1; done

ADMIN="host=$TMP user=postgres dbname=postgres"
psql "$ADMIN" -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
CREATE DATABASE hasala OWNER hasala_migrate;
SQL
psql "host=$TMP user=postgres dbname=hasala" -v ON_ERROR_STOP=1 -q <<'SQL'
ALTER SCHEMA public OWNER TO hasala_migrate;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE hasala FROM PUBLIC;
GRANT CONNECT ON DATABASE hasala TO hasala_runtime;
SQL

HASALA_MIGRATE_DSN="host=$TMP user=hasala_migrate dbname=hasala" "$HASALAD" migrate >"$TMP/migrate.log" 2>&1 || {
	cat "$TMP/migrate.log" >&2
	exit 1
}

umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/auth.key"
echo 1 >"$TMP/log-generation"
HASALA_PG_DSN="host=$TMP user=hasala_runtime dbname=hasala" \
	HASALA_HTTP_LISTEN="127.0.0.1:$PORT" \
	HASALA_RP_ID=hasala.app HASALA_RP_ORIGINS=https://hasala.app \
	HASALA_AUTH_KEY_FILE="$TMP/auth.key" \
	HASALA_LOG_GENERATION_FILE="$TMP/log-generation" \
	HASALA_HEADROOM_PATH="$TMP" HASALA_HEADROOM_FLOOR_BYTES=1 \
	"$HASALAD" serve >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 100); do
	curl -fsS "http://127.0.0.1:$PORT/api/v1/healthz" >/dev/null 2>&1 && break
	sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/api/v1/healthz" >/dev/null || {
	cat "$TMP/serve.log" >&2
	exit 1
}

status=0
HASALA_E2E_URL="http://127.0.0.1:$PORT" HASALA_E2E_PSQL="$(command -v psql)" \
	HASALA_E2E_DSN="host=$TMP user=postgres dbname=hasala" \
	PATH="/usr/bin:$PATH" swift test --package-path "$IOS/HasalaCore" --filter 'LiveHasaladTests|LiveSampleSeedTests|LiveGmailToReplayTests|LiveOutlookToReplayTests' || status=$?
if [[ "$status" != 0 ]]; then
	echo "--- hasalad log ---" >&2
	tail -40 "$TMP/serve.log" >&2
fi
exit "$status"
