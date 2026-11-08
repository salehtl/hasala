#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
for checkout in a b; do
	mkdir -p "$work/$checkout/ios/scripts"
	cp "$here/screens.sh" "$work/$checkout/ios/scripts/"
done
mkdir -p "$work/stub" "$work/dd/Build/Products/Debug-iphonesimulator/Hasala.app"
cat >"$work/stub/env" <<STUB
#!/bin/bash
shift 3
printf '%s\n' "\$*" >>"$work/calls"
if [[ "\$1 \$2" == "simctl io" && -n "\${STUB_SCREENSHOT_FAILS:-}" && "\$5" == */"\$STUB_SCREENSHOT_FAILS.png" ]]; then
	exit 1
fi
if [[ "\$1 \$2" == "simctl launch" && -n "\${STUB_LAUNCH_FAILS:-}" && "\$*" == *"-HasalaScreen \$STUB_LAUNCH_FAILS "* ]]; then
	exit 1
fi
exit 0
STUB
chmod +x "$work/stub/env"

rc=0
screens() {
	local script="$1"
	shift
	rc=0
	: >"$work/calls"
	PATH="$work/stub:$PATH" HASALA_SCREENS_WAIT=0 "$script" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
pass() { echo "ok   $1"; }
bad() {
	echo "FAIL $1"
	sed 's/^/     /' "$work/out" "$work/err"
	fail=1
}
a="$work/a/ios/scripts/screens.sh"
b="$work/b/ios/scripts/screens.sh"

unset HASALA_SCREENS_DD HASALA_SCREENS_OUT
screens "$a" SIM --no-build one
dd_a="$(sed -n 's/^screens.sh: no build at //p' "$work/err")"
screens "$b" SIM --no-build one
dd_b="$(sed -n 's/^screens.sh: no build at //p' "$work/err")"
if [[ -n "$dd_a" && -n "$dd_b" && "$dd_a" != "$dd_b" ]]; then pass "two checkouts have their own default derived data"; else
	bad "the default derived data is '$dd_a' and '$dd_b'"
fi

export HASALA_SCREENS_DD="$work/dd"
screens "$a" SIM --no-build one
out_a="$(dirname "$(head -n 1 "$work/out")")"
if grep -qF "install SIM $work/dd/Build/Products/Debug-iphonesimulator/Hasala.app" "$work/calls"; then pass "HASALA_SCREENS_DD is still used when set"; else bad "HASALA_SCREENS_DD was not used"; fi
screens "$b" SIM --no-build one
out_b="$(dirname "$(head -n 1 "$work/out")")"
if [[ "$out_a" != "$out_b" ]]; then pass "two checkouts have their own default output directory"; else bad "both checkouts write to $out_a"; fi
rmdir "$out_a" "$out_b" 2>/dev/null || true

export HASALA_SCREENS_OUT="$work/shots"
terminated() { grep -qF "terminate SIM app.hasala.ios" "$work/calls"; }
screens "$a" SIM --no-build one two three
if [[ "$rc" == 0 ]] && terminated && [[ "$(wc -l <"$work/out" | tr -d ' ')" == 3 ]]; then pass "every id captured, the app terminated, exit 0"; else bad "a clean run: exit $rc"; fi

STUB_SCREENSHOT_FAILS=two screens "$a" SIM --no-build one two three
if [[ "$rc" == 1 ]]; then pass "a failed screenshot fails the run (exit 1)"; else bad "a failed screenshot: exit $rc"; fi
if grep -qF "screenshot $work/shots/three.png" "$work/calls"; then pass "...and the ids after it are still captured"; else bad "the ids after a failed screenshot were lost"; fi
if terminated; then pass "...and the app is terminated"; else bad "the app was not terminated after a failed screenshot"; fi
if grep -qF "two" "$work/err"; then pass "...and it names the id"; else bad "the failed id was not named"; fi
if ! grep -qF "two.png" "$work/out"; then pass "...and does not list a file it did not write"; else bad "the failed screenshot is listed as written"; fi

STUB_LAUNCH_FAILS=two screens "$a" SIM --no-build one two three
if [[ "$rc" == 1 ]] && terminated && grep -qF "screenshot $work/shots/three.png" "$work/calls"; then pass "a failed launch is counted and skipped the same way"; else bad "a failed launch: exit $rc"; fi
exit "$fail"
