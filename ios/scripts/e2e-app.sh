#!/usr/bin/env bash
# e2e-app.sh: the app's live end-to-end tests (HasalaUITests/LiveE2ETests, E1-E5) on
# two iOS simulators against a local hasalad on 127.0.0.1, with a throwaway Postgres
# on a unix socket and a local stand-in for Cloudflare's email API.
#
#   H=$(nix build .#hasalad --no-link --print-out-paths)/bin/hasalad
#   nix develop -c ios/scripts/e2e-app.sh "$H"                  # every test, in order
#   nix develop -c ios/scripts/e2e-app.sh "$H" test00_launch    # only these, in this order
#   nix develop -c ios/scripts/e2e-app.sh "$H" --server-only    # serve until Ctrl-C
#
# The devShell supplies initdb, pg_ctl, pg_isready, psql and bun; Xcode supplies
# xcodebuild and simctl, called by absolute path (/usr/bin/...) so nothing on the
# devShell's PATH can stand in for them. Nothing here contacts any host but 127.0.0.1:
# the server's email goes to ios/scripts/e2e/mail-capture.ts (HASALA_EMAIL_API_BASE_URL),
# APNs is off, Gmail is unconfigured, and the app reaches the server through its
# Debug-only HASALA_API_BASE_URL launch override. Every address is @example.test.
#
# What it does:
#   1. Postgres in a new /tmp directory (the socket path must stay under 104 bytes),
#      the two roles and the database as e2e-hasalad.sh makes them, `hasalad migrate`.
#   2. Fresh auth and salt keys (64 hex each), the email token and the log generation.
#   3. The mail capture, then `hasalad serve`, polled until /api/v1/healthz answers.
#      A self-check (`hasalad email test`) proves a queued email reaches the capture.
#   4. Review invites from `hasalad invite mint --review` (the first goes to E1).
#   5. New simulators (A, and B when a test runs there), booted; one build-for-testing; then one
#      test-without-building per test on its simulator, in order, stopping at the
#      first failure (HASALA_E2E_CONTINUE=1 runs the rest anyway).
#   6. Teardown on any exit: the server, the capture, the wake watcher, Postgres
#      (immediate), both simulators (shut down and deleted) and the temporary directory.
#
# The tests talk to the harness through files under $TMP (the simulators run as host
# processes, so the test runner can read and write them): the emailed codes
# ($TMP/mail/*.json), the account E1 creates ($TMP/state/account.json), and wake
# requests ($TMP/state/wake-request, answered with `simctl push <sim> app.hasala.ios
# ios/scripts/e2e/wake.apns` and $TMP/state/wake-sent). The iOS 27 simulator refuses a
# content-available-only push (UNErrorDomain 1401, "no user visible content") and any
# push to an app without notification permission (2003), so wake.apns carries an alert
# besides content-available, and E1 allows notifications. hasalad's real wakes stay
# content-free. The system's permission alert does not always appear on a new
# simulator; E1 then answers "Not now", and E3 reports the refused push as an
# expected failure instead of a pass.
#
# Signing (HASALA_E2E_SIGNING):
#   adhoc (default)  CODE_SIGN_IDENTITY=- with CODE_SIGNING_REQUIRED=YES, manual style,
#                    no team and no profile, AppIdentifierPrefix set to the project's
#                    team prefix. The simulator build embeds the Debug entitlements
#                    (keychain-access-groups 8CFG28JHP3.app.hasala.ios and .shared) in
#                    the binary's __entitlements section, so the Keychain works and a
#                    relaunch keeps the session, as E3-E5 need. No Apple account needed.
#   team             the project's own automatic signing (needs the team in Xcode).
#   unsigned         CODE_SIGNING_ALLOWED=NO, as CI builds: no entitlements, so the
#                    Keychain refuses every call (errSecMissingEntitlement) and the
#                    Debug build keeps secrets in memory; E3-E5 cannot pass.
#
# Other knobs: HASALA_E2E_PORT (API, default 18453), HASALA_E2E_MAIL_PORT (default
# 18454), HASALA_E2E_DEVICE_TYPE (default iPhone 17), HASALA_E2E_RUNTIME (default the
# newest iOS runtime), HASALA_E2E_DERIVED_DATA (reuse a build directory between runs;
# default a new one under $TMP), HASALA_E2E_OUT (where logs and .xcresult bundles are
# kept; default ios/build/e2e/<UTC time>), HASALA_E2E_INVITES (default 3).
set -euo pipefail

usage() {
	echo "usage: e2e-app.sh <hasalad binary> [--server-only | <LiveE2ETests method>...]" >&2
	exit 2
}
[[ $# -ge 1 && -x "$1" ]] || usage
HASALAD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
SERVER_ONLY=0
if [[ "${1:-}" == "--server-only" ]]; then
	SERVER_ONLY=1
	shift
	[[ $# -eq 0 ]] || usage
fi

IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEBUILD=/usr/bin/xcodebuild
XCRUN=/usr/bin/xcrun
PORT="${HASALA_E2E_PORT:-18453}"
MAIL_PORT="${HASALA_E2E_MAIL_PORT:-18454}"
SIGNING="${HASALA_E2E_SIGNING:-adhoc}"
DEVICE_TYPE="${HASALA_E2E_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
INVITES="${HASALA_E2E_INVITES:-3}"
BUNDLE_ID=app.hasala.ios
API="http://127.0.0.1:$PORT"

# Each test and the simulator it runs on, in run order (integration plan §4, Lane E).
ALL_TESTS=(test00_launch test01_pathB test02_pathA_secondDevice test03_rebind test04_delete test05_deletedElsewhere)
sim_for() {
	case "$1" in
	test02_pathA_secondDevice | test04_delete) echo B ;;
	*) echo A ;;
	esac
}
if [[ $# -gt 0 ]]; then TESTS=("$@"); else TESTS=("${ALL_TESTS[@]}"); fi
for t in "${TESTS[@]}"; do
	[[ "$t" =~ ^test[0-9A-Za-z_]+$ ]] || {
		echo "e2e-app: '$t' is not a LiveE2ETests method name" >&2
		exit 2
	}
done

for tool in initdb pg_ctl pg_isready psql bun curl; do
	command -v "$tool" >/dev/null || {
		echo "e2e-app: $tool is missing; run inside \`nix develop\`" >&2
		exit 2
	}
done
[[ -x "$XCODEBUILD" && -x "$XCRUN" ]] || {
	echo "e2e-app: Xcode's $XCODEBUILD and $XCRUN are required" >&2
	exit 2
}
port_free() { ! /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
for p in "$PORT" "$MAIL_PORT"; do
	port_free "$p" || {
		echo "e2e-app: 127.0.0.1:$p is already in use; set HASALA_E2E_PORT / HASALA_E2E_MAIL_PORT" >&2
		exit 2
	}
done

# /tmp, not $TMPDIR: Postgres's unix socket lives here, and a socket path longer
# than 103 bytes (a deep $TMPDIR on macOS) makes the server fail to start.
TMP="$(mktemp -d /tmp/hasala-app-e2e.XXXXXX)"
STATE="$TMP/state"
MAIL="$TMP/mail"
mkdir -p "$STATE" "$MAIL" "$TMP/results"
OUT="${HASALA_E2E_OUT:-$IOS/build/e2e/$(date -u +%Y%m%dT%H%M%SZ)}"
DD="${HASALA_E2E_DERIVED_DATA:-$TMP/dd}"
SERVER_PID=""
MAIL_PID=""
WAKE_PID=""
SIMS=()

log() { printf 'e2e-app: %s\n' "$*" >&2; }

keep_logs() {
	mkdir -p "$OUT"
	for f in serve.log mail-capture.log migrate.log pg.log wake.log build.log; do
		[[ -f "$TMP/$f" ]] && cp "$TMP/$f" "$OUT/"
	done
	for f in "$TMP"/results/*; do
		[[ -e "$f" ]] && cp -R "$f" "$OUT/"
	done
	return 0
}

cleanup() {
	local status=$?
	set +e
	keep_logs
	[[ -n "$WAKE_PID" ]] && kill "$WAKE_PID" 2>/dev/null
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
	[[ -n "$MAIL_PID" ]] && kill "$MAIL_PID" 2>/dev/null && wait "$MAIL_PID" 2>/dev/null
	pg_ctl -D "$TMP/pg" -m immediate stop >/dev/null 2>&1
	for sim in "${SIMS[@]}"; do
		"$XCRUN" simctl shutdown "$sim" >/dev/null 2>&1
		"$XCRUN" simctl delete "$sim" >/dev/null 2>&1
	done
	rm -rf "$TMP"
	log "logs and results: $OUT"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 1. Postgres ------------------------------------------------------------------
initdb -D "$TMP/pg" -U postgres -A trust --no-sync >/dev/null
pg_ctl -D "$TMP/pg" -l "$TMP/pg.log" -o "-k $TMP -c listen_addresses='' -c fsync=off" start >/dev/null
for _ in $(seq 50); do pg_isready -h "$TMP" -q && break; sleep 0.1; done

psql "host=$TMP user=postgres dbname=postgres" -v ON_ERROR_STOP=1 -q <<'SQL'
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

# --- 2. Keys ------------------------------------------------------------------------
(
	umask 077
	head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/auth.key"
	head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/salt.key"
	echo e2e >"$TMP/email.token"
	echo 1 >"$TMP/log-generation"
)

# The environment every hasalad mode here shares. No [gmail] group, APNs off, no
# trusted proxy (so the email API base URL may point at the capture).
export HASALA_PG_DSN="host=$TMP user=hasala_runtime dbname=hasala"
export HASALA_HTTP_LISTEN="127.0.0.1:$PORT"
export HASALA_RP_ID=hasala.app HASALA_RP_ORIGINS=https://hasala.app
export HASALA_AUTH_KEY_FILE="$TMP/auth.key" HASALA_SALT_KEY_FILE="$TMP/salt.key"
export HASALA_LOG_GENERATION_FILE="$TMP/log-generation"
export HASALA_HEADROOM_PATH="$TMP" HASALA_HEADROOM_FLOOR_BYTES=1
export HASALA_EMAIL_CF_ACCOUNT_ID=00000000000000000000000000000000
export HASALA_EMAIL_API_TOKEN_FILE="$TMP/email.token"
export HASALA_EMAIL_API_BASE_URL="http://127.0.0.1:$MAIL_PORT/client/v4"
export HASALA_ADMIN_ACTOR=e2e

# --- 3. Mail capture and the server -------------------------------------------------
bun "$IOS/scripts/e2e/mail-capture.ts" --port "$MAIL_PORT" --dir "$MAIL" --token e2e >"$TMP/mail-capture.log" 2>&1 &
MAIL_PID=$!
for _ in $(seq 100); do curl -fsS "http://127.0.0.1:$MAIL_PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "http://127.0.0.1:$MAIL_PORT/healthz" >/dev/null || {
	cat "$TMP/mail-capture.log" >&2
	exit 1
}

"$HASALAD" serve >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 150); do
	curl -fsS "$API/api/v1/healthz" >/dev/null 2>&1 && break
	kill -0 "$SERVER_PID" 2>/dev/null || break
	sleep 0.1
done
curl -fsS "$API/api/v1/healthz" >/dev/null || {
	log "hasalad did not come up"
	cat "$TMP/serve.log" >&2
	exit 1
}
log "hasalad is up at $API ($(curl -fsS "$API/api/v1/healthz"))"

# Prove the capture path before any test depends on it: one queued email must land.
"$HASALAD" email test e2e-selftest@example.test >/dev/null
for _ in $(seq 100); do
	grep -lq '"to": "e2e-selftest@example.test"' "$MAIL"/*.json 2>/dev/null && break
	sleep 0.1
done
grep -lq '"to": "e2e-selftest@example.test"' "$MAIL"/*.json 2>/dev/null || {
	log "the self-check email never reached the capture"
	tail -20 "$TMP/serve.log" >&2
	cat "$TMP/mail-capture.log" >&2
	exit 1
}
log "mail capture works ($(find "$MAIL" -name '*.json' | wc -l | tr -d ' ') message)"

# --- 4. Review invites ----------------------------------------------------------------
: >"$STATE/invites.txt"
for _ in $(seq "$INVITES"); do
	code="$("$HASALAD" invite mint --review --note e2e 2>/dev/null | grep -oE '[A-Z2-7-]{24,29}' | tr -d - | head -1)"
	[[ ${#code} -eq 24 ]] || {
		log "invite mint printed no 24-character code"
		exit 1
	}
	echo "$code" >>"$STATE/invites.txt"
done
INVITE="$(head -1 "$STATE/invites.txt")"
log "minted $INVITES review invites"

if [[ "$SERVER_ONLY" == 1 ]]; then
	cat >&2 <<EOF
e2e-app: serving until Ctrl-C. For a run from Xcode, set these on the test action:
  TEST_RUNNER_HASALA_E2E_API=$API
  TEST_RUNNER_HASALA_E2E_MAIL_DIR=$MAIL
  TEST_RUNNER_HASALA_E2E_STATE=$STATE
  TEST_RUNNER_HASALA_E2E_INVITE=$INVITE
(other invites: $STATE/invites.txt)
EOF
	wait "$SERVER_PID"
	exit $?
fi

# --- 5. Simulators, one build, the tests ------------------------------------------------
RUNTIME="${HASALA_E2E_RUNTIME:-$("$XCRUN" simctl list runtimes available |
	grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)}"
[[ -n "$RUNTIME" ]] || {
	log "no iOS simulator runtime is installed"
	exit 1
}
SIM_A="$("$XCRUN" simctl create "hasala-e2e-a-$$" "$DEVICE_TYPE" "$RUNTIME")"
SIMS+=("$SIM_A")
SIM_B=""
for t in "${TESTS[@]}"; do
	if [[ "$(sim_for "$t")" == B && -z "$SIM_B" ]]; then
		SIM_B="$("$XCRUN" simctl create "hasala-e2e-b-$$" "$DEVICE_TYPE" "$RUNTIME")"
		SIMS+=("$SIM_B")
	fi
done
for sim in "${SIMS[@]}"; do
	"$XCRUN" simctl boot "$sim"
	"$XCRUN" simctl bootstatus "$sim" -b >/dev/null
done
log "simulators: A=$SIM_A B=${SIM_B:-none} ($RUNTIME)"

TEAM="$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$IOS/Config/Shared.xcconfig" | head -1)"
case "$SIGNING" in
adhoc)
	SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
		DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= "AppIdentifierPrefix=$TEAM.")
	;;
team) SIGN_ARGS=() ;;
unsigned) SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO) ;;
*)
	log "HASALA_E2E_SIGNING is '$SIGNING': want adhoc, team or unsigned"
	exit 2
	;;
esac

log "build-for-testing (signing: $SIGNING) into $DD"
"$XCODEBUILD" build-for-testing -project "$IOS/Hasala.xcodeproj" -scheme Hasala -configuration Debug \
	-destination "id=$SIM_A" -derivedDataPath "$DD" "${SIGN_ARGS[@]}" >"$TMP/build.log" 2>&1 || {
	grep -E 'error:|BUILD FAILED' "$TMP/build.log" | head -40 >&2
	log "build-for-testing failed; the full log is kept in $OUT/build.log"
	exit 1
}
XCTESTRUN="$(find "$DD/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
[[ -n "$XCTESTRUN" ]] || {
	log "build-for-testing wrote no .xctestrun"
	exit 1
}
if [[ "$SIGNING" == adhoc ]]; then
	ENTS="$(find "$DD/Build/Intermediates.noindex" -path '*Hasala.build/Hasala.app-Simulated.xcent' | head -1)"
	if [[ -z "$ENTS" ]] || ! grep -q "$TEAM.app.hasala.ios" "$ENTS"; then
		log "the simulator entitlements lack the $TEAM.app.hasala.ios Keychain group; E3-E5 will fail"
	fi
fi

# The wake watcher: a test asks for a silent push by creating $STATE/wake-request; the
# push goes to the simulator the current test runs on.
(
	while :; do
		if [[ -f "$STATE/wake-request" ]]; then
			rm -f "$STATE/wake-request"
			sim="$(cat "$STATE/current-sim")"
			if "$XCRUN" simctl push "$sim" "$BUNDLE_ID" "$IOS/scripts/e2e/wake.apns" >"$TMP/wake.out" 2>&1; then
				date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE/wake-sent"
			else
				cp "$TMP/wake.out" "$STATE/wake-failed"
			fi
			cat "$TMP/wake.out" >>"$TMP/wake.log"
		fi
		sleep 0.5
	done
) &
WAKE_PID=$!

passed=()
failed=()
for t in "${TESTS[@]}"; do
	which="$(sim_for "$t")"
	if [[ "$which" == B ]]; then sim="$SIM_B"; else sim="$SIM_A"; fi
	echo "$sim" >"$STATE/current-sim"
	rm -f "$STATE/wake-sent" "$STATE/wake-failed"
	log "run $t on $which"
	status=0
	TEST_RUNNER_HASALA_E2E_API="$API" \
		TEST_RUNNER_HASALA_E2E_MAIL_DIR="$MAIL" \
		TEST_RUNNER_HASALA_E2E_STATE="$STATE" \
		TEST_RUNNER_HASALA_E2E_INVITE="$INVITE" \
		TEST_RUNNER_HASALA_E2E_DEVICE="$which" \
		"$XCODEBUILD" test-without-building -xctestrun "$XCTESTRUN" -destination "id=$sim" \
		-only-testing:"HasalaUITests/LiveE2ETests/$t" -resultBundlePath "$TMP/results/$t.xcresult" \
		-collect-test-diagnostics never \
		>"$TMP/results/$t.log" 2>&1 || status=$?
	# A skipped test exits 0 too; it counts as a failure here, since this harness set
	# everything the tests need.
	if [[ "$status" == 0 ]] && grep -qiE "test case .*$t.* passed" "$TMP/results/$t.log" &&
		! grep -qiE "test case .*$t.* skipped" "$TMP/results/$t.log"; then
		passed+=("$t")
		log "PASS $t"
	else
		failed+=("$t")
		log "FAIL $t (exit $status)"
		grep -E 'error: |XCTAssert|failed \(|skipped' "$TMP/results/$t.log" | head -20 >&2 || true
		# The last minutes of the app's, SpringBoard's and the notification daemon's logs
		# (much faster than the diagnostics xcodebuild would collect).
		"$XCRUN" simctl spawn "$sim" log show --last 5m --style compact \
			--predicate 'process == "Hasala" OR process == "SpringBoard" OR process == "usernotificationsd"' \
			>"$TMP/results/$t.syslog" 2>&1 || true
		if [[ "${HASALA_E2E_CONTINUE:-0}" != 1 ]]; then
			log "stopping: the later tests build on this one (HASALA_E2E_CONTINUE=1 runs them anyway)"
			break
		fi
	fi
done

log "passed: ${passed[*]:-none}"
log "failed: ${failed[*]:-none}"
[[ ${#failed[@]} -eq 0 && ${#passed[@]} -eq ${#TESTS[@]} ]]
