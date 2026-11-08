#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
real_bun="$(command -v bun)"
seed=server/internal/tmpl/seed
bundled=ios/HasalaCore/Sources/HasalaCore/Resources/templates
failures=0

mkdir -p "$work/bin"
cat >"$work/bin/bun" <<STUB
#!/bin/sh
case "\$1" in
*.ts) exec "$real_bun" "\$@" ;;
esac
printf '%s\n' "\$*" >>"\$STUB_LOG"
exit 0
STUB
cat >"$work/bin/govulncheck" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$work/bin/go" <<'STUB'
#!/bin/sh
case "$PWD" in
*/oracle) side=oracle ;;
*) side=server ;;
esac
pkg="stub/$side"
tst="TestStub$side"
case "$1" in
env)
	echo go9.9.9
	exit 0
	;;
run)
	echo 'HASALA_TEST_POSTGRES_URL=stub; PG_STOP='
	exit 0
	;;
vet)
	[ "$side" = oracle ] && exit "${STUB_ORACLE_VET_RC:-0}"
	exit 0
	;;
test) ;;
*)
	exit 64
	;;
esac
case " $* " in
*" -list "*)
	printf '{"Action":"output","Package":"%s","Output":"%s\\n"}\n{"Action":"pass","Package":"%s"}\n' "$pkg" "$tst" "$pkg"
	;;
*" -skip "*)
	if [ "$side" = oracle ] && [ -n "${STUB_ORACLE_TEST_FAILS:-}" ]; then
		printf '{"Action":"fail","Package":"%s","Test":"%s"}\n{"Action":"fail","Package":"%s"}\n' "$pkg" "$tst" "$pkg"
		exit 1
	fi
	printf '{"Action":"pass","Package":"%s","Test":"%s"}\n{"Action":"pass","Package":"%s"}\n' "$pkg" "$tst" "$pkg"
	;;
*" -v "*)
	printf '=== RUN   TestKnown\n--- FAIL: TestKnown (0.00s)\nFAIL\n'
	exit 1
	;;
esac
exit 0
STUB
chmod +x "$work/bin/bun" "$work/bin/govulncheck" "$work/bin/go"

g() { git -C "$work/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

commit() {
	g add -A
	g commit -q --allow-empty -m "$1"
}

fresh() {
	rm -rf "$work/t" "$work/tmp" "$work/log" "$work/summary"
	mkdir -p "$work/tmp" "$work/t/scripts/tests" "$work/t/server/oracle" "$work/t/infra/assist" "$work/t/$seed" "$work/t/$bundled"
	cp "$ROOT/scripts/check.sh" "$ROOT/scripts/gotest-summary.ts" "$ROOT/scripts/gotest-ran.ts" "$work/t/scripts/"
	local s
	while IFS= read -r s; do
		mkdir -p "$work/t/$(dirname "$s")"
		printf '#!/bin/sh\nexit 0\n' >"$work/t/$s"
		chmod +x "$work/t/$s"
	done < <(grep -oE '"\$ROOT/[^"]+\.sh"' "$ROOT/scripts/check.sh" | sed -E 's|^"\$ROOT/(.*)"$|\1|' | sort -u)
	printf 'toolchain go1.0.0\n' >"$work/t/server/go.mod"
	printf '{}\n' >"$work/t/$seed/a.json"
	printf '{}\n' >"$work/t/$bundled/a.json"
	local d
	for d in "$ROOT"/conformance/*/; do
		mkdir -p "$work/t/conformance/$(basename "$d")"
	done
	mkdir -p "$work/t/conformance/templates/sms"
	git -C "$work/t" init -q
	commit first
}

gate() {
	local name="$1" want="$2" rc=0
	shift 2
	env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u HASALA_PRIVATE_FIXTURES -u HASALA_TEST_POSTGRES_URL \
		-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
		TMPDIR="$work/tmp" STUB_LOG="$work/log" PATH="$work/bin:$PATH" "$@" \
		"$work/t/scripts/check.sh" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

says() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...says '$1'"; else
		echo "FAIL the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

lacks() {
	if grep -qF -- "$1" "$work/out"; then
		echo "FAIL the output says '$1'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	else echo "ok   ...does not say '$1'"; fi
}

fresh
g update-ref refs/remotes/origin/main HEAD
gate "a local run with a merge base" 0
says "check: OK (real-mail fence, toolchain, fence, govulncheck, go vet, go test, assist worker, conformance)"
lacks "NOT RUN"

fresh
gate "a local run with no origin/main" 0
says "NOT RUN: the golden-fixture rule"

fresh
commit second
gate "a CI run" 0 GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$work/summary"
says "check: OK (real-mail fence, toolchain, fence, go vet, go test, assist worker, conformance)"
says "NOT RUN: govulncheck"
lacks "golden-fixture rule ("
if grep -qF "govulncheck" "$work/summary"; then echo "ok   ...and the job summary names it"; else
	echo "FAIL the job summary does not name the step that did not run"
	failures=$((failures + 1))
fi

fresh
gate "a CI run with no HEAD^1" 1 GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$work/summary"
says "no base commit"
lacks "check: OK"

leftovers() {
	local left
	left="$(find "$work/tmp" -maxdepth 1 -type f -name 'tmp.*')"
	if [[ -z "$left" ]]; then echo "ok   ...and leaves no temporary file"; else
		echo "FAIL temporary files left behind:"
		sed 's/^/     /' <<<"$left"
		failures=$((failures + 1))
	fi
}

fresh
gate "a failing oracle go test" 1 STUB_ORACLE_TEST_FAILS=1
leftovers

fresh
gate "a failing oracle go vet" 1 STUB_ORACLE_VET_RC=1
leftovers

fresh
gate "a passing run" 0
leftovers

if ((failures)); then
	echo "$failures gate run case(s) failed"
	exit 1
fi
