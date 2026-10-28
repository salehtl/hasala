#!/usr/bin/env bash
# screens.sh: screenshots of app screens by id, on the mocks, for comparing with the Paper
# boards (plan 0.4, B6). Each id is a Debug `-HasalaScreen` launch: the app opens straight
# on that screen from its own scenario, with motion settled (`-HasalaMotion off`).
#
#   ios/scripts/screens.sh <simulator udid> [--release] [--reduce] [--no-build]
#     [--scenario <name>] [--identity <name>] [--size <category>] <id>... | --all
#
#   --release          the Release surface (`-HasalaReleaseSurface`); files end in .release.png
#   --reduce           the Reduce Motion substitutes (`-HasalaMotion reduce`) instead of settled
#   --no-build         reuse the last build in the derived data directory
#   --scenario <name>  every id over this `-HasalaScenario` (mayaWorst, mayaEmpty, mayaOne,
#                      mayaHuge ...); files end in .<name>.png
#   --identity <name>  the account identity (`-HasalaIdentity` worst, one, empty or huge) over
#                      the screen's own scenario; files end in .id-<name>.png
#   --size <category>  a Dynamic Type size (`-UIPreferredContentSizeCategoryName`, for example
#                      UICTContentSizeCategoryAccessibilityXXXL); files end in .<category>.png
#   --all              every id registered in ios/Hasala/App/Debug/ScreenLaunch+*.swift
#
# It builds Debug once (derived data $HASALA_SCREENS_DD, default /tmp/hasala-dd-screens),
# installs it, launches each id, waits for it to settle ($HASALA_SCREENS_WAIT seconds,
# default 2.5) and writes $HASALA_SCREENS_OUT/<id>[.release].png (default
# /tmp/hasala-screens). Debug builds only: the hook is compiled out of Release.
set -euo pipefail

usage() {
	echo "usage: screens.sh <simulator udid> [--release] [--reduce] [--no-build] [--scenario <name>]" \
		"[--identity <name>] [--size <category>] <id>... | --all" >&2
	exit 2
}

(($# >= 2)) || usage
udid="$1"
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
dd="${HASALA_SCREENS_DD:-/tmp/hasala-dd-screens}"
out="${HASALA_SCREENS_OUT:-/tmp/hasala-screens}"
wait="${HASALA_SCREENS_WAIT:-2.5}"
release=false
motion=off
build=true
scenario=""
identity=""
size=""
ids=()
while (($#)); do
	arg="$1"
	shift
	case "$arg" in
	--release) release=true ;;
	--reduce) motion=reduce ;;
	--no-build) build=false ;;
	--scenario | --identity | --size)
		(($#)) || usage
		case "$arg" in
		--scenario) scenario="$1" ;;
		--identity) identity="$1" ;;
		--size) size="$1" ;;
		esac
		shift
		;;
	--all)
		# The registry's ids, as each area file writes them: Screen("<id>", ...
		while IFS= read -r id; do ids+=("$id"); done < <(
			sed -n 's/^ *Screen("\([^"]*\)".*/\1/p' "$ios"/Hasala/App/Debug/ScreenLaunch+*.swift
		)
		;;
	-*) usage ;;
	*) ids+=("$arg") ;;
	esac
done
((${#ids[@]})) || usage

# Xcode's tools by path: the Nix devShell's PATH and SDKROOT can shadow them.
xcrun=(env -u SDKROOT /usr/bin/xcrun)
"${xcrun[@]}" simctl boot "$udid" 2>/dev/null || true
"${xcrun[@]}" simctl bootstatus "$udid" -b >/dev/null

app="$dd/Build/Products/Debug-iphonesimulator/Hasala.app"
if $build; then
	/usr/bin/xcodebuild build -project "$ios/Hasala.xcodeproj" -scheme Hasala -configuration Debug \
		-destination "id=$udid" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet
fi
[[ -d "$app" ]] || {
	echo "screens.sh: no build at $app (run without --no-build)" >&2
	exit 1
}
"${xcrun[@]}" simctl install "$udid" "$app"
mkdir -p "$out"

failed=0
for id in "${ids[@]}"; do
	args=(-HasalaScreen "$id" -HasalaMotion "$motion")
	name="$id"
	if [[ -n "$scenario" ]]; then
		args+=(-HasalaScenario "$scenario")
		name="$name.$scenario"
	fi
	if [[ -n "$identity" ]]; then
		args+=(-HasalaIdentity "$identity")
		name="$name.id-$identity"
	fi
	if [[ -n "$size" ]]; then
		args+=(-UIPreferredContentSizeCategoryName "$size")
		name="$name.$size"
	fi
	if $release; then
		args+=(-HasalaReleaseSurface)
		name="$name.release"
	fi
	if ! "${xcrun[@]}" simctl launch --terminate-running-process "$udid" app.hasala.ios "${args[@]}" >/dev/null; then
		echo "screens.sh: $id did not launch" >&2
		failed=1
		continue
	fi
	sleep "$wait"
	"${xcrun[@]}" simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
	echo "$out/$name.png"
done
"${xcrun[@]}" simctl terminate "$udid" app.hasala.ios 2>/dev/null || true
exit "$failed"
