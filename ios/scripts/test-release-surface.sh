#!/usr/bin/env bash
# test-release-surface.sh: walks what a Release build shows (HasalaUITests'
# ReleaseSurface* classes, one per area: every tab and the profile, no placeholder text,
# no control without a screen behind it, the beta's account actions, Gmail and Outlook
# (personal Microsoft accounts only), one mailbox, and a switch of provider only after
# its confirmation) on a Release-configuration build in the simulator.
#
#   ios/scripts/test-release-surface.sh <simulator udid> [derived data directory]
#
# A Release build has no data to show without an account and a server, so this one
# links the Maya mock (HasalaMocks) as a Debug build does: the Release optimizer, no
# DEBUG flag, and the mock ledger to walk. It is unsigned, for the simulator only, and is
# never archived; archive.sh builds Release without the mock, and inspect-ipa.sh's
# AT-REV-4 refuses an .ipa that carries it. ENABLE_TESTABILITY lets the unit-test target
# build alongside (the scheme builds every test target).
set -euo pipefail

if (($# < 1 || $# > 2)); then
	echo "usage: test-release-surface.sh <simulator udid> [derived data directory]" >&2
	exit 2
fi
udid="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# Derived data: the directory given (kept), else a temporary one, removed on exit.
if (($# == 2)); then
	dd="$2"
else
	dd="$(mktemp -d "${TMPDIR:-/tmp}/hasala-release-surface.XXXXXX")"
	trap 'rm -rf "$dd"' EXIT
fi

# Every Release-surface class: the shell's, then each area's (plan B7.4).
classes=(
	ReleaseSurfaceTests ReleaseSurfaceJoinTests ReleaseSurfaceSetupTests ReleaseSurfaceMailboxTests
	ReleaseSurfaceSignInTests ReleaseSurfaceHomeTests ReleaseSurfaceActivityTests ReleaseSurfacePlanTests
	ReleaseSurfaceProfileTests
)
only=()
for c in "${classes[@]}"; do only+=("-only-testing:HasalaUITests/$c"); done

# Xcode's tools by path: the Nix devShell's PATH and SDKROOT can shadow them.
/usr/bin/xcodebuild test \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala -configuration Release \
	-destination "id=$udid" -derivedDataPath "$dd" \
	"${only[@]}" \
	CODE_SIGNING_ALLOWED=NO \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS=HASALA_MOCKS \
	EXCLUDED_SOURCE_FILE_NAMES= \
	ENABLE_TESTABILITY=YES
