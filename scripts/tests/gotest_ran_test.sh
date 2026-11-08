#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

list() {
	local t
	: >"$work/list"
	for t in "$@"; do
		printf '{"Action":"output","Package":"p","Output":"%s\\n"}\n' "$t" >>"$work/list"
	done
	printf '{"Action":"pass","Package":"p"}\n' >>"$work/list"
}

record() {
	: >"$work/record"
	while (($#)); do
		if [[ -n "$3" ]]; then
			printf '{"Action":"output","Package":"p","Test":"%s","Output":"    x_test.go:1: %s\\n"}\n' "$1" "$3" >>"$work/record"
		fi
		printf '{"Action":"%s","Package":"p","Test":"%s"}\n' "$2" "$1" >>"$work/record"
		shift 3
	done
	printf '{"Action":"pass","Package":"p"}\n' >>"$work/record"
}

expect() {
	local name="$1" want="$2" rc=0
	bun "$ROOT/scripts/gotest-ran.ts" "$work/list" "$work/record" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
	if [[ -n "${3:-}" ]] && ! grep -qF -- "$3" "$work/out"; then
		echo "FAIL $name: the output does not say '$3'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

list TestA
record TestA pass ""
expect "a test that passed" 0

list TestA
record TestA skip "[real-corpus] HASALA_PRIVATE_FIXTURES is unset"
expect "a real-corpus test that skipped" 0

list TestWriteFixtures
record TestWriteFixtures skip "HASALA_WRITE_CONFORMANCE is unset; regenerated deliberately"
expect "a fixture writer that skipped" 0

list TestA
record TestA skip "fixture testdata/a.json not found"
expect "a test that skipped because its fixture moved" 1 "TestA"

list TestWriteFixtures
record TestWriteFixtures skip "fixture testdata/a.json not found"
expect "a test named like a writer that skipped for another reason" 1 "TestWriteFixtures"

list TestA
record TestA skip "HASALA_WRITE_CONFORMANCE is unset"
expect "a test that is no writer but names the switch" 1 "TestA"

list TestA
record TestA skip ""
expect "a test that skipped with no reason" 1 "TestA"

list TestA TestB
record TestA pass ""
expect "a test that did not run" 1 "TestB"

if ((failures)); then
	echo "$failures gotest-ran case(s) failed"
	exit 1
fi
