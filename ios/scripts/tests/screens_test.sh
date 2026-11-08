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
exit "$fail"
