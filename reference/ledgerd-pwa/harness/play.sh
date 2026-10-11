#!/usr/bin/env bash
# play.sh — the long-lived instance you can actually USE, from a phone.
#
# `v2stack.sh` builds a scratch stack for SCRIPTS: throwaway cluster under /tmp,
# no account, no data, on `localhost`. A phone cannot reach localhost, and a bare
# LAN IP is not a secure context, so WebAuthn cannot run there either — which is
# why there has never been a way to hold this app in your hand.
#
# This is the other thing. One instance that persists, on a real HTTPS origin
# over the tailnet, with a real passkey and months of plausible data.
#
#   harness/play.sh up            # vite behind the front door — hot reload
#   harness/play.sh up --built    # ledgerd's embedded bundle — the real PWA
#   harness/play.sh status
#   harness/play.sh seed          # regenerate the CSV served at /seed/
#   harness/play.sh invite        # another single-use invite code
#   harness/play.sh reset         # wipe the database and start over
#   harness/play.sh down          # stop everything; the DATA stays
#
# NEVER PRODUCTION. Its own Postgres cluster (unix socket only, no TCP port),
# its own data directory, its own ports. It opens neither /var/lib/ledger nor
# /etc/ledger-v2 nor the ledger_v2 database nor either systemd unit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${LEDGER_PLAY_DIR:-/var/lib/ledger-play}"
# The host's `tailscale serve` name (<host>.<tailnet>.ts.net). No default: it is
# the operator's own machine, and the passkey rp_id is bound to it.
HOST="${LEDGER_PLAY_HOST:?set LEDGER_PLAY_HOST to this host's tailscale serve name}"
TS_PORT="${LEDGER_PLAY_TS_PORT:-8446}"
API_PORT="${LEDGER_PLAY_API_PORT:-8124}"
UI_PORT="${LEDGER_PLAY_UI_PORT:-5178}"
SMTP_PORT="${LEDGER_PLAY_SMTP_PORT:-2528}"
DB="${LEDGER_PLAY_DB:-ledger_play}"
PGDATA="$RUN/pg"
# /run, not $RUN, because that is where a runtime socket belongs: init()
# recreates it, so losing it on reboot is correct rather than a problem.
#
# It originally moved here for a worse reason. `internal/config`'s rail against
# v1's data directory was a bare substring match on the DSN, so it refused
# "/var/lib/ledger-play/sock" as if it were "/var/lib/ledger" and ledgerd would
# not start. That rail now matches a path SEGMENT, so this could sit under $RUN
# again — the placement is a preference now, not a workaround. Left as it is
# because a socket under /run is the more ordinary shape.
PGSOCK="${LEDGER_PLAY_SOCK:-/run/ledger-play}"
ORIGIN="https://$HOST:$TS_PORT"
# Resolved once, absolutely: `nohup` and `env` resolve the command against the
# CALLER's PATH, and `bun` is not a system binary here — it lives in
# /root/.bun/bin. A caller whose PATH lacks it (cron, a systemd unit, another
# shell, another agent) got `bunx: No such file or directory` pointing at a
# binary that is plainly present. Overridable, but never guessed.
BUN="${LEDGER_PLAY_BUN:-$(command -v bun || echo /root/.bun/bin/bun)}"

# The dev host is the production server as well as the dev box, so the difference
# between this instance and the live one is four names. Check them out loud,
# every invocation, rather than trusting that nobody ever exports the wrong var.
guard() {
	case "$RUN" in
		/var/lib/ledger|/var/lib/ledger/*|/etc/ledger-v2|/etc/ledger-v2/*)
			echo "refusing: \$RUN=$RUN is production's" >&2; exit 1 ;;
	esac
	case "$PGSOCK" in
		/var/lib/ledger|/var/lib/ledger/*|/etc/ledger-v2|/etc/ledger-v2/*)
			echo "refusing: \$PGSOCK=$PGSOCK is production's" >&2; exit 1 ;;
	esac
	if [[ "$DB" == "ledger_v2" || "$DB" == "ledger" ]]; then
		echo "refusing: \$DB=$DB is a production database" >&2; exit 1
	fi
	local p
	for p in "$TS_PORT" "$API_PORT" "$UI_PORT" "$SMTP_PORT"; do
		case "$p" in
			443|25|8079|8080|8099|8443|8444|8445|8123|5177|2526)
				echo "refusing: port $p belongs to production, v1 or v2stack.sh" >&2; exit 1 ;;
		esac
	done
	# A missing bun should fail once, up front, and name the variable — not
	# three functions later as a mystery "bunx: No such file or directory" in
	# vite.log, blaming a binary that is plainly present elsewhere on the box.
	if [[ ! -x "$BUN" ]]; then
		echo "refusing: \$BUN=$BUN is not executable — set LEDGER_PLAY_BUN" >&2
		exit 1
	fi
}

pg_bin() { ls -d /usr/lib/postgresql/*/bin | tail -1; }

# postgres refuses to run as root, and this script runs as root, so every
# cluster command drops to the system `postgres` user — which is also why the
# socket and data directories are chowned to it.
as_pg() { sudo -u postgres "$@"; }

dsn() { echo "postgres://postgres@/$DB?host=$PGSOCK&sslmode=disable"; }

pg_running() { as_pg "$(pg_bin)/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }

init() {
	guard
	mkdir -p "$RUN" "$PGSOCK" "$RUN/seed"
	chown postgres "$PGSOCK"
	# pg_ctl runs as `postgres` (postgres refuses to run as root) but $RUN is
	# root-owned, because the ledgerd binary, the config and the pid files live
	# here too. So the log file is created here and handed over, rather than
	# chowning the whole instance directory to postgres or hiding the log inside
	# $PGDATA where `$RUN/*.log` would not find it.
	touch "$RUN/pg.log"
	chown postgres "$RUN/pg.log"
	if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
		echo "==> initdb: a cluster of this instance's own, at $PGDATA"
		mkdir -p "$PGDATA"
		chown postgres "$PGDATA"
		chmod 700 "$PGDATA"
		as_pg "$(pg_bin)/initdb" -D "$PGDATA" -U postgres --auth=trust >/dev/null
	fi
}

pg_start() {
	pg_running && return 0
	echo "==> starting the play cluster on a unix socket only"
	# -h '' is the whole isolation story: no TCP listener at all, so nothing
	# else on this box can reach it and it can reach no other cluster.
	as_pg "$(pg_bin)/pg_ctl" -D "$PGDATA" -l "$RUN/pg.log" -w \
		-o "-k $PGSOCK -h ''" start >/dev/null
}

pg_stop() {
	pg_running || return 0
	as_pg "$(pg_bin)/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null
}

psql_admin() { as_pg psql -h "$PGSOCK" -U postgres -d postgres "$@"; }

ensure_db() {
	if ! psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
		psql_admin -qc "CREATE DATABASE $DB"
	fi
}

write_config() {
	cat > "$RUN/config.toml" <<-TOML
		[mail]
		domain      = "example.com"
		smtp_listen = "127.0.0.1:$SMTP_PORT"

		[server]
		http_listen = "127.0.0.1:$API_PORT"

		[auth]
		rp_id           = "$HOST"
		rp_display_name = "Ledger (play)"
		rp_origins      = ["$ORIGIN"]
	TOML
}

build_ledgerd() {
	echo "==> building ledgerd"
	(cd "$REPO" && CGO_ENABLED=0 go build -o "$RUN/ledgerd" ./cmd/ledgerd)
}

start_ledgerd() {
	stop_ledgerd
	echo "==> starting ledgerd on 127.0.0.1:$API_PORT"
	# --dns-fixtures serves the recorded DKIM/ARC TXT records offline, so the
	# corpus's signed bank mail verifies. Without it every message posted to the
	# SMTP listener reads `unauthenticated` and the mail lane is untestable.
	# ledgerd refuses the flag off loopback, and this listener is loopback.
	LEDGER_PG_DSN="$(dsn)" \
		nohup "$RUN/ledgerd" serve -config "$RUN/config.toml" \
			--dns-fixtures "$REPO/internal/origin/testdata/dns.json" \
			> "$RUN/ledgerd.log" 2>&1 &
	echo $! > "$RUN/ledgerd.pid"
	wait_for "http://127.0.0.1:$API_PORT/api/v1/healthz" ledgerd
}

stop_ledgerd() {
	[[ -f "$RUN/ledgerd.pid" ]] || return 0
	local pid
	pid="$(cat "$RUN/ledgerd.pid")"
	kill "$pid" 2>/dev/null || true
	# Wait for it to actually go. `reset` drops the database the moment this
	# returns, and Postgres refuses DROP DATABASE while a backend still holds a
	# connection — returning at the kill made reset fail intermittently. stop_vite
	# polls for the same reason.
	local _
	for _ in $(seq 1 40); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.25
	done
	rm -f "$RUN/ledgerd.pid"
}

start_vite() {
	stop_vite
	echo "==> starting vite on 127.0.0.1:$UI_PORT"
	# LEDGER_PLAY_HOST puts the tailnet name in `allowedHosts` and points the
	# HMR client at the front door's port — see web/vite.config.ts. Without it
	# every request through tailscale answers "Blocked request".
	(cd "$REPO/web" && LEDGER_V2_API="http://127.0.0.1:$API_PORT" \
		LEDGER_PLAY_HOST="$HOST" LEDGER_PLAY_PORT="$TS_PORT" \
		nohup "$BUN" x vite --port "$UI_PORT" --strictPort --host 127.0.0.1 \
			> "$RUN/vite.log" 2>&1 &
		echo $! > "$RUN/vite.pid")
	wait_for "http://127.0.0.1:$UI_PORT/" vite
}

stop_vite() {
	# `$BUN x vite` is a wrapper that spawns the real server, and the launch above
	# runs inside a subshell — so `$!` records neither. Killing that pid left vite
	# holding :$UI_PORT while `down` reported success, and the NEXT `up` died on
	# --strictPort blaming the port rather than the leak. The listening socket is
	# the fact that matters, so stop on that and confirm it actually let go.
	local pids
	# `|| true`: under `set -o pipefail`, this pipeline's exit status is 1
	# whenever grep finds no match — i.e. on every ordinary "nothing to kill"
	# call, which is the common case. Without it, `set -e` kills the whole
	# script the first time stop_vite runs with no vite yet listening.
	pids="$(ss -ltnpH "sport = :$UI_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u | tr '\n' ' ' || true)"
	# Only OUR kind of process. The port is the right way to find vite, but it is
	# not proof of ownership: an operator debugging something else on 5178 would
	# otherwise be killed by a harness teardown, silently. A pid whose command
	# line is not vite or bun is left alone and named, so the operator finds out
	# from this script rather than from their own missing process.
	local mine="" pid cmd
	for pid in $pids; do
		# NULs AND newlines to spaces, then truncated: a command line can be a
		# whole inline script, and a warning that scrolls is a warning nobody reads.
		cmd="$(tr '\0\n' '  ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-100 || true)"
		case "$cmd" in
			*vite*|*"bun x"*) mine="$mine $pid" ;;
			"") ;;  # already gone
			*) echo "  !! pid $pid holds :$UI_PORT and is not vite; leaving it: $cmd" >&2 ;;
		esac
	done
	pids="$mine"
	if [[ -n "${pids// /}" ]]; then
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null || true
		local _
		for _ in $(seq 1 20); do
			ss -ltnH "sport = :$UI_PORT" 2>/dev/null | grep -q . || break
			sleep 0.25
		done
	fi
	rm -f "$RUN/vite.pid"
}

# One front door, two things that can sit behind it. The ORIGIN never changes,
# so the passkey, the account and the data survive a mode switch.
front_door() {
	local target=$1
	tailscale serve --bg --yes --https="$TS_PORT" "$target" >/dev/null
	# The seed CSV, served as a static directory beside the app. This is how the
	# file reaches a phone: Safari downloads it from the same origin, and the
	# import screen picks it up. /seed is not an app route.
	tailscale serve --bg --yes --https="$TS_PORT" --set-path=/seed "$RUN/seed" >/dev/null
}

clear_front_door() {
	# BY PORT AND PATH, never `tailscale serve reset` — reset would also remove
	# the admin console (8445), storybook (8443) and v1 (8444, and / on 8080).
	tailscale serve --https="$TS_PORT" --set-path=/seed off >/dev/null 2>&1 || true
	tailscale serve --https="$TS_PORT" off >/dev/null 2>&1 || true
}

# No file means never brought up (or brought down since) — say so rather than
# guessing "dev", which used to make `status` claim a live mode when nothing
# was serving.
mode() { cat "$RUN/mode" 2>/dev/null || echo "none (down)"; }

up() {
	guard
	init
	pg_start
	ensure_db
	write_config

	local prev
	prev="$(mode)"

	local want=dev
	case "${1:-}" in
		""|--dev) want=dev ;;
		--built) want=built ;;
		*)
			echo "usage: $0 up [--dev|--built]" >&2
			exit 2
			;;
	esac

	# VitePWA has no devOptions, so vite dev neither registers nor unregisters a
	# worker of its own. A worker installed by a previous --built therefore keeps
	# controlling this origin straight through the switch, and it answers every
	# navigation with the bundle it was built from — so "edit web/src, refresh
	# the tab" silently shows stale code until that worker is gone.
	if [[ "$prev" == built && "$want" == dev ]]; then
		echo >&2
		echo "==> WARNING: switching from --built to --dev leaves the LAST BUILT SERVICE WORKER in control." >&2
		echo "    Until you clear site data for $HOST (or unregister the worker in devtools)," >&2
		echo "    this tab keeps serving the previously built bundle, not your edits." >&2
		echo >&2
	fi

	if [[ "$want" == built ]]; then
		# The bundle is embedded, so the web build must precede the Go build.
		# LEDGER_WEB_OUT_DIR is deliberately NOT set: --built exists to serve
		# exactly what a deploy would serve, which is the committed artifact.
		echo "==> this rewrites the COMMITTED internal/webui/dist — check 'git status' after"
		echo "==> building the web bundle into internal/webui/dist"
		(cd "$REPO/web" && "$BUN" run build)
	fi
	build_ledgerd
	start_ledgerd

	if [[ "$want" == built ]]; then
		stop_vite
		front_door "http://127.0.0.1:$API_PORT"
	else
		start_vite
		front_door "http://127.0.0.1:$UI_PORT"
	fi
	# Written only once the front door actually points somewhere live — earlier
	# than this, a front_door failure under `set -e` would exit with $RUN/mode
	# still claiming a mode that never got served.
	echo "$want" > "$RUN/mode"

	[[ -f "$RUN/seed/ledger-play.csv" ]] || seed >/dev/null
	local code
	code="$(invite)"
	echo
	echo "play instance up in $want mode."
	echo "  app   $ORIGIN"
	echo "  seed  $ORIGIN/seed/ledger-play.csv"
	echo "  invite $code"
}

down() {
	guard
	stop_vite
	stop_ledgerd
	clear_front_door
	pg_stop
	# Cleared so `status` cannot report a mode that is no longer serving.
	rm -f "$RUN/mode"
	# $RUN is NOT removed. The account, the passkey and the data are the point.
	echo "play instance down. Data kept at $RUN — 'up' brings it back."
}

status() {
	echo "origin   $ORIGIN"
	echo "mode     $(mode)"
	echo "cluster  $(pg_running && echo running || echo stopped)"
	printf 'ledgerd  '; curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$API_PORT/api/v1/healthz" 2>/dev/null || echo down
	if [[ "$(mode)" == dev ]]; then
		printf 'vite     '
		# Not a plain GET: the Host header is what tailscale sends, and an
		# unlisted host answers "Blocked request" with a 403 while a plain
		# localhost GET answers 200. Checking the wrong one is how this would
		# look healthy and still be unreachable from the phone.
		curl -fsS -o /dev/null -w '%{http_code}\n' -H "Host: $HOST" "http://127.0.0.1:$UI_PORT/" 2>/dev/null || echo down
	fi
	echo "--- tailscale ---"
	tailscale serve status | grep -A2 ":$TS_PORT" || echo "no front door on $TS_PORT"
}

wait_for() {
	local url=$1 what=$2
	local _
	for _ in $(seq 1 60); do
		curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
		sleep 0.5
	done
	echo "$what did not come up; see $RUN/*.log" >&2
	exit 1
}

seed() {
	# bun, not node: this repo runs everything through bun (bunx vite, bun run
	# build, bun test), playseed.mjs imports only node:fs and node:path, and the
	# box's `node` is a dangling symlink into a long-deleted /tmp scratch dir.
	# Depending on a name nothing else here depends on buys nothing.
	"$BUN" "$REPO/web/harness/playseed.mjs" "$RUN/seed" >&2
	echo "$ORIGIN/seed/ledger-play.csv"
}

# A single-use invite, minted through ledgerd itself rather than by an INSERT,
# so the code really is hashed the way a real one is.
invite() {
	# Errors are HELD, not discarded and not printed on the happy path.
	#
	# `2>/dev/null` used to hide them, so a failed mint printed "invite " with a
	# blank code and exited 0 — a command substitution's failure does not trip
	# `set -e` in an enclosing `echo`. Removing the redirect fixed that but put
	# goose's "no migrations to run" and the single-use warning on the terminal
	# after every successful mint, which trains the reader to skim past exactly
	# the place a real error would appear.
	#
	# So stderr goes to a file, and the file is shown only when there is no code.
	# `set +e` around the capture, and the status kept by hand. Without it `set -e`
	# aborts ON THE ASSIGNMENT the moment mint-invite fails, so the diagnostic
	# below never runs and the caller sees a bare exit 1 with nothing said — the
	# same silence this function exists to remove, arrived at from the other
	# direction. Verified by moving config.toml aside and watching it print
	# nothing until this was added.
	local code err status
	err="$(mktemp)"
	set +e
	code="$(LEDGER_PG_DSN="$(dsn)" \
		"$RUN/ledgerd" mint-invite --note "play" -config "$RUN/config.toml" 2>"$err" | sed -n '1p')"
	status=$?
	set -e
	if [[ "$status" -ne 0 || -z "$code" ]]; then
		echo "mint-invite failed (exit $status):" >&2
		cat "$err" >&2
		rm -f "$err"
		return 1
	fi
	rm -f "$err"
	echo "$code"
}

# Reset is TOTAL, and that is deliberate. A partial reset that deleted only the
# op-log rows would leave every device's local projection ahead of the server's
# claimed position and hash chain — which is exactly the permanent anomaly state
# the append-only log makes unrecoverable. Wiping the database and clearing site
# data on each device is the honest operation.
reset() {
	guard
	pg_start
	stop_ledgerd
	# Anything still attached loses its connection now, so the DROP below is
	# deterministic rather than a race we have been winning. Scoped to $DB, which
	# guard() has already refused to let be a production name.
	psql_admin -qc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid()" >/dev/null
	echo "==> dropping $DB"
	psql_admin -qc "DROP DATABASE IF EXISTS $DB"
	ensure_db
	start_ledgerd
	seed >/dev/null
	local code
	code="$(invite)"
	echo
	echo "reset done."
	echo "  On EVERY device: clear site data for $HOST, then sign up again."
	# Anchored on the ORIGIN header line, not on ":$TS_PORT" anywhere in the
	# block. The loose match would also hit a different entry that merely
	# mentioned the number, and this box already serves four other ports.
	if tailscale serve status 2>/dev/null | grep -q "^https://$HOST:$TS_PORT\b"; then
		echo "  app    $ORIGIN"
		echo "  seed   $ORIGIN/seed/ledger-play.csv"
	else
		echo "  the front door is down — run '$0 up' to serve it at $ORIGIN"
	fi
	echo "  invite $code"
}

case "${1:-up}" in
	init)    init ;;
	db-up)   guard; init; pg_start; ensure_db; echo "cluster up: $(dsn)" ;;
	db-down) guard; pg_stop; echo "cluster down (data kept at $PGDATA)" ;;
	up)      shift; up "$@" ;;
	--built) up --built ;;
	down)    down ;;
	status)  status ;;
	seed)    guard; seed ;;
	invite)  guard; invite ;;
	reset)   reset ;;
	*) echo "usage: $0 [up [--dev|--built]|down|status|seed|invite|reset|init|db-up|db-down]" >&2; exit 2 ;;
esac
