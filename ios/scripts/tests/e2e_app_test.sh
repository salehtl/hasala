#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
stop_other_run() {
	if [[ -f "$work/other-run.pid" ]]; then
		kill "$(cat "$work/other-run.pid")" 2>/dev/null || true
		rm -f "$work/other-run.pid"
	fi
}
trap 'stop_other_run; rm -rf "$work"' EXIT
fail=0
mkdir -p "$work/ios/scripts" "$work/stub"
cp "$here/e2e-app.sh" "$work/ios/scripts/"

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
cat >"$work/stub/pg_ctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$work/pg_ctl-calls"
exit 0
STUB
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
cat >"$work/stub/bun" <<STUB
#!/bin/sh
exec /usr/bin/python3 -I "$work/listener.py" "\$3"
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

rc=0
run() {
	rc=0
	: >"$work/pg_ctl-calls"
	env PATH="$work/stub:$PATH" HASALA_E2E_PORT="$(free_port)" HASALA_E2E_MAIL_PORT="$(free_port)" \
		HASALA_E2E_OUT="$work/kept" "$@" "$work/ios/scripts/e2e-app.sh" "$work/hasalad" --server-only >"$work/out" 2>&1 || rc=$?
}
pass() { echo "ok   $1"; }
bad() {
	echo "FAIL $1"
	sed 's/^/     /' "$work/out"
	fail=1
}
said() { grep -qF -- "$1" "$work/out"; }

run STUB_INITDB=other-run-binds STUB_SERVE=dies-late
stop_other_run
if [[ "$rc" == 1 ]] && said "hasalad did not come up" && ! said "hasalad is up" && said "address already in use"; then
	pass "another run's server on the port does not count as ours while ours is starting (exit $rc)"
else
	bad "another run's server on the port while ours is starting: exit $rc"
fi
if said "logs and results:"; then pass "...and the teardown ran to its end"; else bad "the teardown stopped early"; fi

started=$SECONDS
run STUB_SERVE=dies
waited=$((SECONDS - started))
if [[ "$rc" == 1 ]] && ((waited < 10)) && said "hasalad did not come up" && said "address already in use"; then
	pass "a server that dies at start ends the wait and shows its log"
else
	bad "a server that dies at start: exit $rc after ${waited}s"
fi

run STUB_SERVE=healthy
if said "hasalad is up"; then pass "this run's own server counts as up"; else bad "this run's own server did not count as up (exit $rc)"; fi

: >"$work/pg_ctl-calls"
rm -f "$work/owner-seen"
env PATH="$work/stub:$PATH" HASALA_E2E_PORT="$(free_port)" HASALA_E2E_MAIL_PORT="$(free_port)" HASALA_E2E_OUT="$work/kept" STUB_SERVE=dies \
	"$work/ios/scripts/e2e-app.sh" "$work/hasalad" --server-only >"$work/out" 2>&1 &
run_owner=$!
wait "$run_owner" || true
if [[ "$(cat "$work/owner-seen" 2>/dev/null)" == "$run_owner" ]]; then pass "the cluster names the run that owns it"; else bad "owner.pid says '$(cat "$work/owner-seen" 2>/dev/null)', the run was $run_owner"; fi
if grep -qE -- '-D .+/pgtest-[^/]+/data ' "$work/pg_ctl-calls"; then pass "the cluster has the shape the gate's reaper looks for"; else
	bad "pg_ctl started $(head -n 1 "$work/pg_ctl-calls")"
fi

exit "$fail"
