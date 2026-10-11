#!/usr/bin/env bash
# archive.sh's prechecks (spec 06 §10.4: 14, 16, 21) and its one-archive-per-build-
# number rule: a second archive in the same UTC minute is refused (21) instead of
# reusing the first one's ios/build/<BUILD>/.
#
# Offline, and nothing is archived, signed or provisioned: xcodebuild is a stub first
# on PATH that answers -version and refuses everything else (so `xcodebuild archive`
# fails, exit 30, before anything is built), the key is a text file, HOME is empty,
# and HASALA_BUILD_DIR keeps every build directory and last-build-number in a
# temporary directory. archive.sh runs with --allow-dirty --allow-branch, so the
# state of this checkout does not matter.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
root="$work/build"
mkdir -p "$work/home" "$work/stub" "$work/keys"

# The stub only stands in for xcodebuild if archive.sh reaches it through PATH.
if grep -nE '/usr/bin/xcodebuild|xcrun[[:space:]]+xcodebuild' "$here/archive.sh"; then
	echo "FAIL archive.sh does not call xcodebuild through PATH; the stub cannot replace it, so this test stops here"
	exit 1
fi
cat >"$work/stub/xcodebuild" <<STUB
#!/bin/sh
# archive_precheck_test.sh's xcodebuild: answers -version, refuses everything else.
printf '%s\n' "\$*" >>"$work/calls"
if [ "\$1" = -version ]; then
	echo "Xcode \${STUB_XCODE:-27.0}"
	echo "Build version 27A000"
	exit 0
fi
echo "xcodebuild stub: refusing to run" >&2
exit 65
STUB
real_git="$(command -v git)"
cat >"$work/stub/git" <<STUB
#!/bin/sh
# archive_precheck_test.sh's git: the real one, unless STUB_GIT_FAIL is set.
if [ -n "\${STUB_GIT_FAIL:-}" ]; then echo "git stub: failing" >&2; exit 128; fi
exec "$real_git" "\$@"
STUB
chmod +x "$work/stub/xcodebuild" "$work/stub/git"
key="$work/keys/AuthKey_TESTKEY000.p8"
echo "not a key" >"$key"
chmod 600 "$key"
: >"$work/calls"

# archive NAME WANT [VAR=value...]: archive.sh --allow-dirty --allow-branch with the
# stubs, the fake key and HASALA_BUILD_DIR=$root, plus the given variables.
archive() {
	local name="$1" want="$2" rc=0
	shift 2
	env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH HOME="$work/home" HASALA_BUILD_DIR="$root" \
		PATH="$work/stub:$PATH" ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
		ASC_KEY_PATH="$key" "$@" "$here/archive.sh" --allow-dirty --allow-branch >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
said() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...$2"; else
		echo "FAIL $2: the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
archives() { grep -c '^archive ' "$work/calls" || true; }

archive "no key file" 14 ASC_KEY_PATH="$work/keys/none/AuthKey_TESTKEY000.p8"
archive "Xcode 26" 16 STUB_XCODE=26.4
said "needs Xcode 27.x" "refused for the Xcode version"
archive "git fails while checking the tree" 128 STUB_GIT_FAIL=1
mkdir -p "$root"
echo 991231.12359 >"$root/last-build-number"
archive "a build number not newer than the last upload" 21
said "is not newer than the last upload 991231.12359" "refused for the build number"
rm "$root/last-build-number"
if [[ "$(archives)" != 0 ]]; then
	echo "FAIL a refused precheck reached xcodebuild archive"
	fail=1
fi

# Two archives in one UTC minute: run both well inside the same minute.
sec="$(/bin/date -u +%S)"
if ((10#$sec > 45)); then sleep $((61 - 10#$sec)); fi
archive "the first archive of the minute reaches xcodebuild archive (the stub refuses it)" 30
dirs=()
for d in "$root"/[0-9]*; do
	if [[ -d "$d" ]]; then dirs+=("$d"); fi
done
if [[ "${#dirs[@]}" == 1 && -d "${dirs[0]}" && "$(archives)" == 1 ]]; then
	echo "ok   ...it claimed ${dirs[0]##*/}/ and ran xcodebuild archive once"
else
	echo "FAIL the first archive did not claim exactly one build directory"
	fail=1
fi
archive "a second archive in the same UTC minute" 21
said "exists already" "refused because ios/build/<BUILD>/ exists"
if [[ "$(archives)" == 1 ]]; then echo "ok   ...and never reached xcodebuild archive"; else
	echo "FAIL the second archive reached xcodebuild archive"
	fail=1
fi

rc=0
env HOME="$work/home" HASALA_BUILD_DIR="$root" PATH="$work/stub:$PATH" "$here/archive.sh" --upload >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then echo "ok   archive.sh refuses an unknown option (exit 2)"; else
	echo "FAIL archive.sh --upload: exit $rc, want 2"
	fail=1
fi
exit "$fail"
