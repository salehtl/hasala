#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
listener=""
stop_listener() {
	if [[ -n "$listener" ]]; then
		kill "$listener" 2>/dev/null || true
		wait "$listener" 2>/dev/null || true
		listener=""
	fi
}
stop_other_run() {
	if [[ -f "$work/other-run.pid" ]]; then
		kill "$(cat "$work/other-run.pid")" 2>/dev/null || true
		rm -f "$work/other-run.pid"
	fi
}
trap 'stop_listener; stop_other_run; rm -rf "$work"' EXIT
fail=0
mkdir -p "$work/ios/scripts" "$work/stub"
cp "$here/e2e-hasalad.sh" "$work/ios/scripts/"
real_curl="$(command -v curl)"

cat >"$work/listener.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

for tool in pg_isready psql; do
	printf '#!/bin/sh\nexit 0\n' >"$work/stub/$tool"
done
cat >"$work/stub/initdb" <<STUB
#!/bin/sh
if [ "\${STUB_INITDB:-}" = other-run-binds ]; then
	/usr/bin/python3 -I "$work/listener.py" "\$HASALA_E2E_PORT" >/dev/null 2>&1 &
	echo \$! >"$work/other-run.pid"
	i=0
	while [ \$i -lt 100 ]; do
		/usr/sbin/lsof -nP -iTCP:"\$HASALA_E2E_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
		sleep 0.1
		i=\$((i + 1))
	done
fi
exit 0
STUB
cat >"$work/stub/pg_ctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$work/pg_ctl-calls"
exit 0
STUB
cat >"$work/stub/curl" <<STUB
#!/bin/sh
echo call >>"$work/curl-calls"
case "\${STUB_CURL:-real}" in
refuses) exit 7 ;;
answers)
	sleep 0.3
	exit 0
	;;
esac
exec "$real_curl" "\$@"
STUB
cat >"$work/hasalad" <<STUB
#!/bin/sh
case "\$1" in
migrate) exit 0 ;;
serve)
	cat "\$HASALA_HEADROOM_PATH/owner.pid" >"$work/owner-seen" 2>/dev/null || echo none >"$work/owner-seen"
	if [ "\${STUB_SERVE:-dies}" = healthy ]; then
		exec /usr/bin/python3 -I "$work/listener.py" "\${HASALA_HTTP_LISTEN##*:}"
	fi
	[ "\${STUB_SERVE:-dies}" = dies-late ] && sleep 1.5
	echo "listen tcp: bind: address already in use" >&2
	exit 1
	;;
esac
exit 64
STUB
chmod +x "$work/stub"/* "$work/hasalad"

free_port() {
	/usr/bin/python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
listening() { /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

rc=0
run() {
	local port="$1"
	shift
	rc=0
	: >"$work/curl-calls"
	: >"$work/pg_ctl-calls"
	env PATH="$work/stub:$PATH" HASALA_E2E_PORT="$port" "$@" "$work/ios/scripts/e2e-hasalad.sh" "$work/hasalad" >"$work/out" 2>&1 || rc=$?
}
pass() { echo "ok   $1"; }
bad() {
	echo "FAIL $1"
	sed 's/^/     /' "$work/out"
	fail=1
}
reached_tests() { grep -qF -- '--- hasalad log ---' "$work/out"; }
said() { grep -qF -- "$1" "$work/out"; }

port="$(free_port)"
/usr/bin/python3 -I "$work/listener.py" "$port" &
listener=$!
for _ in $(seq 100); do
	listening "$port" && break
	sleep 0.1
done
run "$port" STUB_SERVE=dies
if [[ "$rc" == 2 ]] && ! reached_tests && said "127.0.0.1:$port is already in use; stop that process" && [[ ! -s "$work/pg_ctl-calls" ]]; then
	pass "a server left on the port stops the run before it starts anything (exit $rc)"
else
	bad "a server left on the port: exit $rc, and the run went on or the port was not named"
fi
stop_listener

port="$(free_port)"
run "$port" STUB_INITDB=other-run-binds STUB_SERVE=dies-late
stop_other_run
if [[ "$rc" == 1 ]] && ! reached_tests && said "address already in use"; then
	pass "another run's server on the port does not count as ours while ours is starting (exit $rc)"
else
	bad "another run's server on the port while ours is starting: exit $rc, and the tests ran"
fi

port="$(free_port)"
run "$port" STUB_SERVE=dies STUB_CURL=refuses
polls="$(wc -l <"$work/curl-calls" | tr -d ' ')"
if [[ "$rc" != 0 ]] && ((polls < 20)) && said "address already in use"; then
	pass "a server that dies at start ends the wait after $polls polls and shows its log"
else
	bad "a server that dies at start: exit $rc after $polls polls"
fi

port="$(free_port)"
run "$port" STUB_SERVE=dies STUB_CURL=answers
if [[ "$rc" != 0 ]] && ! reached_tests && said "address already in use"; then
	pass "an answer on the port while our server has exited does not count as ready (exit $rc)"
else
	bad "an answer on the port while our server has exited: exit $rc, and the tests ran"
fi

port="$(free_port)"
run "$port" STUB_SERVE=healthy
if reached_tests; then pass "a healthy server reaches the tests"; else bad "a healthy server did not reach the tests (exit $rc)"; fi
if ! listening "$port"; then pass "...and is stopped on exit"; else bad "the server still listens on $port after the run"; fi

run_owner=""
port="$(free_port)"
: >"$work/pg_ctl-calls"
env PATH="$work/stub:$PATH" HASALA_E2E_PORT="$port" STUB_SERVE=healthy "$work/ios/scripts/e2e-hasalad.sh" "$work/hasalad" >"$work/out" 2>&1 &
run_owner=$!
wait "$run_owner" || true
if [[ "$(cat "$work/owner-seen")" == "$run_owner" ]]; then pass "the cluster names the run that owns it"; else bad "owner.pid says '$(cat "$work/owner-seen")', the run was $run_owner"; fi
if grep -qE -- '-D .+/pgtest-[^/]+/data ' "$work/pg_ctl-calls"; then pass "the cluster has the shape the gate's reaper looks for"; else
	bad "pg_ctl started $(head -n 1 "$work/pg_ctl-calls")"
fi

exit "$fail"
