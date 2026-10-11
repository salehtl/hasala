#!/usr/bin/env bash
# lint.sh — the ingress lint for the hasala tunnel (spec 05 §7.4).
#
# The tunnel is the QA host's only public ingress, so its config may route
# exactly one thing: api.hasala.app, on the API path allowlist, to the API port
# on loopback. Everything else is a 404 from cloudflared itself. The console
# (spec 07) and every metrics port must never be reachable through it.
#
#   lint.sh check  <config.yml>                 rules L1–L9 on one file
#   lint.sh routes <config.yml> <routes.tsv>    each URL hits its expected rule
#   lint.sh all    <rendered.yml> <dir>         what checks.<sys>.ingress-lint runs:
#       G1  the rendered config equals <dir>/config.golden.yml byte for byte
#       L*  check on the rendered config
#       R   routes on the rendered config with <dir>/routes.tsv
#       N   every <dir>/bad/*.yml is rejected, with the rule its
#           "# lint-expect: Ln" line names among the reasons
#
# Rules (a failure prints "Ln: reason"; check reports every failing rule):
#   L1 exactly two ingress rules
#   L2 rule 0's hostname is exactly api.hasala.app; no hostname anywhere holds a *
#   L3 rule 0's path is exactly the API allowlist
#   L4 rule 0's service is exactly http://127.0.0.1:<api port>
#   L5 the last rule has only a service, and it is http_status:404
#   L6 no noTLSVerify, access, bastionMode, proxyType, ipRules or warp-routing
#      key anywhere; no unix:, ssh:, rdp:, tcp:, smb: or hello_world service
#   L7 no service names a metrics port, a console port, or a known neighbour's
#      port (Postgres, Prometheus, Grafana, ntfy)
#   L8 `cloudflared tunnel ingress validate` accepts the file
#   L9 loglevel is info (at debug, cloudflared logs request paths, which carry
#      credential ids)
#
# Needs yq (mikefarah's yq-go) and cloudflared on PATH. Override the ports with
# HASALA_API_PORT and HASALA_FORBIDDEN_PORTS (space-separated).
set -euo pipefail

HOST="api.hasala.app"
API_PATH='^/(api/v1/.*|hooks/gmail/pubsub)$'
API_PORT="${HASALA_API_PORT:-8471}"
# 9471 hasalad metrics, 9472 cloudflared metrics, 8472/9473 the console and its
# metrics (spec 07, M16), 5432 Postgres, 9090 Prometheus, 3000 Grafana, 2586 ntfy.
FORBIDDEN_PORTS="${HASALA_FORBIDDEN_PORTS:-9471 9472 8472 9473 5432 9090 3000 2586}"

die() {
	echo "lint.sh: $*" >&2
	exit 2
}

# check FILE: print one line per failed rule; exit 1 if any failed.
check() {
	local f="$1" bad=0 n v keys svc port
	[ -r "$f" ] || die "cannot read $f"
	fail() {
		echo "$1: $2"
		bad=1
	}
	yq -e 'tag == "!!map"' "$f" >/dev/null 2>&1 || {
		echo "L1: $f is not a YAML mapping"
		return 1
	}

	n="$(yq '.ingress | length' "$f")"
	[ "$n" = 2 ] || fail L1 "the ingress has $n rules, want exactly 2"

	v="$(yq '.ingress[0].hostname // ""' "$f")"
	[ "$v" = "$HOST" ] || fail L2 "rule 0's hostname is '$v', want '$HOST'"
	if yq '.. | select(tag == "!!map" and has("hostname")) | .hostname' "$f" | grep -q '[*]'; then
		fail L2 "a hostname holds a wildcard"
	fi

	v="$(yq '.ingress[0].path // ""' "$f")"
	[ "$v" = "$API_PATH" ] || fail L3 "rule 0's path is '$v', want '$API_PATH'"

	v="$(yq '.ingress[0].service // ""' "$f")"
	[ "$v" = "http://127.0.0.1:$API_PORT" ] || fail L4 "rule 0's service is '$v', want 'http://127.0.0.1:$API_PORT'"

	keys="$(yq '.ingress[-1] | keys | join(",")' "$f")"
	v="$(yq '.ingress[-1].service // ""' "$f")"
	{ [ "$keys" = service ] && [ "$v" = http_status:404 ]; } ||
		fail L5 "the last rule has keys '$keys' and service '$v', want only service: http_status:404"

	keys="$(yq '[.. | select(tag == "!!map") | keys | .[]] | unique | .[]' "$f")"
	for k in noTLSVerify access bastionMode proxyType ipRules warp-routing; do
		if grep -qx -- "$k" <<<"$keys"; then fail L6 "the key '$k' is not allowed"; fi
	done
	svc="$(yq '.. | select(tag == "!!map" and has("service")) | .service' "$f")"
	if grep -qE '^(unix|unix\+tls|ssh|rdp|tcp|smb):|hello_world' <<<"$svc"; then
		fail L6 "a service uses a forbidden scheme: $(grep -E '^(unix|unix\+tls|ssh|rdp|tcp|smb):|hello_world' <<<"$svc" | head -1)"
	fi

	while read -r port; do
		[ -n "$port" ] || continue
		for p in $FORBIDDEN_PORTS; do
			[ "$port" = "$p" ] && fail L7 "a service names port $port"
		done
	done < <(sed -nE 's#^[a-z+]+://[^/]*:([0-9]+).*#\1#p' <<<"$svc")

	if ! cloudflared tunnel --config "$f" ingress validate >/dev/null 2>&1; then
		fail L8 "cloudflared tunnel ingress validate refuses the file"
	fi

	v="$(yq '.loglevel // ""' "$f")"
	[ "$v" = info ] || fail L9 "loglevel is '$v', want 'info'"

	return "$bad"
}

# routes FILE TSV: each "<url>\t<rule index>" row must match that rule.
routes() {
	local f="$1" tsv="$2" bad=0 url want got
	while IFS=$'\t' read -r url want; do
		case "$url" in '' | '#'*) continue ;; esac
		got="$(cloudflared tunnel --config "$f" ingress rule "$url" 2>&1 | sed -nE 's/^Matched rule #([0-9]+).*/\1/p')"
		if [ "$got" != "$want" ]; then
			echo "R: $url matched rule '${got:-none}', want $want"
			bad=1
		fi
	done <"$tsv"
	return "$bad"
}

all() {
	local rendered="$1" dir="$2" bad=0 expect out
	if cmp -s "$rendered" "$dir/config.golden.yml"; then
		echo "G1 ok: the rendered config equals config.golden.yml"
	else
		echo "G1: the rendered config differs from config.golden.yml:"
		diff -u "$dir/config.golden.yml" "$rendered" || true
		bad=1
	fi
	if out="$(check "$rendered")"; then echo "L1–L9 ok on the rendered config"; else
		echo "$out"
		bad=1
	fi
	if out="$(routes "$rendered" "$dir/routes.tsv")"; then
		echo "routes ok: $(grep -cvE '^(#|$)' "$dir/routes.tsv") URLs"
	else
		echo "$out"
		bad=1
	fi
	local fixtures=0
	for f in "$dir"/bad/*.yml; do
		fixtures=$((fixtures + 1))
		expect="$(sed -nE 's/^# lint-expect: (L[0-9]+)$/\1/p' "$f")"
		[ -n "$expect" ] || {
			echo "N: $(basename "$f") has no '# lint-expect: Ln' line"
			bad=1
			continue
		}
		if out="$(check "$f")"; then
			echo "N: $(basename "$f") was ACCEPTED; the lint must reject it ($expect)"
			bad=1
		elif ! grep -q "^$expect: " <<<"$out"; then
			echo "N: $(basename "$f") was rejected, but not by $expect:"
			echo "$out"
			bad=1
		else
			echo "N ok: $(basename "$f") rejected by $expect"
		fi
	done
	[ "$fixtures" -gt 0 ] || {
		echo "N: no negative fixtures under $dir/bad"
		bad=1
	}
	return "$bad"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
check) [ $# = 1 ] || die "usage: lint.sh check <config.yml>"; check "$1" ;;
routes) [ $# = 2 ] || die "usage: lint.sh routes <config.yml> <routes.tsv>"; routes "$1" "$2" ;;
all) [ $# = 2 ] || die "usage: lint.sh all <rendered.yml> <dir>"; all "$1" "$2" ;;
*) die "usage: lint.sh {check|routes|all} ..." ;;
esac
