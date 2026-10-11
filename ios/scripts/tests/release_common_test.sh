#!/usr/bin/env bash
# release-common.sh's helpers: MARKETING_VERSION from the xcconfigs (inspection I3),
# hasala_absent (every absence check in inspect-ipa.sh), hasala_record_build and
# hasala_build_root (HASALA_BUILD_DIR counts only with HASALA_TEST_MODE=1).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=../release-common.sh
source "$here/release-common.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() {
	echo "FAIL $1"
	fail=1
}

# hasala_marketing_version
v="$(hasala_marketing_version "$ios/Config")"
if [[ "$v" == 0.2.0 ]]; then ok "ios/Config sets MARKETING_VERSION = $v"; else bad "ios/Config: MARKETING_VERSION is '$v', want 0.2.0"; fi
version() { # version NAME WANT-OUTPUT-OR-REFUSED XCCONFIG-LINE...
	local name="$1" want="$2" got
	shift 2
	rm -rf "$work/cfg"
	mkdir -p "$work/cfg"
	printf '%s\n' "$@" >"$work/cfg/A.xcconfig"
	got="$(hasala_marketing_version "$work/cfg" 2>/dev/null)" || got=refused
	if [[ "$got" == "$want" ]]; then ok "$name: $got"; else bad "$name: got '$got', want '$want'"; fi
}
version "one plain line" 1.2.3 '// MARKETING_VERSION = 9.9.9 in a comment' 'MARKETING_VERSION = 1.2.3'
version "no spaces, trailing blank" 1.2.3 'MARKETING_VERSION=1.2.3 '
version "not set" refused 'CURRENT_PROJECT_VERSION = 1'
version "set twice" refused 'MARKETING_VERSION = 1.2.3' 'MARKETING_VERSION = 1.2.4'
version "set per configuration" refused 'MARKETING_VERSION = 1.2.3' 'MARKETING_VERSION[config=Release] = 1.2.4'
version "a build setting reference" refused 'MARKETING_VERSION = $(VERSION)'
version "two components" refused 'MARKETING_VERSION = 1.2'

# hasala_absent: true only for "searched everything, found nothing".
printf 'alpha\nbeta\n' >"$work/text"
printf 'head\0\1\2 localhost \0tail' >"$work/binary"
absent() { # absent NAME WANT(true|false) ERE PATH...
	local name="$1" want="$2" got=false
	shift 2
	if hasala_absent "$@" 2>/dev/null; then got=true; fi
	if [[ "$got" == "$want" ]]; then ok "hasala_absent $name: $got"; else bad "hasala_absent $name: $got, want $want"; fi
}
absent "no match" true 'gamma' "$work/text"
absent "a match" false 'beta' "$work/text"
absent "a match in a binary file" false 'localhost' "$work/binary"
absent "a match in a directory" false 'localhost' "$work"
absent "a missing file" false 'gamma' "$work/missing"
absent "a missing file beside a clean one" false 'gamma' "$work/text" "$work/missing"
absent "no path at all" false 'gamma'

# hasala_record_build and hasala_build_root
hasala_record_build "$work/root" 991231.12359
if [[ "$(cat "$work/root/last-build-number")" == 991231.12359 && ! -e "$work/root/last-build-number.tmp" ]]; then
	ok "hasala_record_build writes last-build-number"
else
	bad "hasala_record_build"
fi
# root NAME WANT(path|refused) [VAR=value...]: hasala_build_root /x/ios with only the
# given HASALA_BUILD_DIR and HASALA_TEST_MODE.
root() {
	local name="$1" want="$2" got
	shift 2
	got="$(env -u HASALA_BUILD_DIR -u HASALA_TEST_MODE "$@" bash -c 'source "$1" && hasala_build_root /x/ios' _ \
		"$here/release-common.sh" 2>/dev/null)" || got=refused
	if [[ "$got" == "$want" ]]; then ok "hasala_build_root $name: $got"; else bad "hasala_build_root $name: got '$got', want '$want'"; fi
}
root "with neither variable" /x/ios/build
root "with HASALA_BUILD_DIR empty" /x/ios/build HASALA_BUILD_DIR=
root "with HASALA_TEST_MODE=1 alone" /x/ios/build HASALA_TEST_MODE=1
root "with HASALA_BUILD_DIR and HASALA_TEST_MODE=1" /t HASALA_BUILD_DIR=/t HASALA_TEST_MODE=1
root "with HASALA_BUILD_DIR alone" refused HASALA_BUILD_DIR=/t
root "with HASALA_BUILD_DIR and HASALA_TEST_MODE=0" refused HASALA_BUILD_DIR=/t HASALA_TEST_MODE=0
root "with HASALA_BUILD_DIR and HASALA_TEST_MODE=yes" refused HASALA_BUILD_DIR=/t HASALA_TEST_MODE=yes
exit "$fail"
