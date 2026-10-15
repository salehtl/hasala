#!/usr/bin/env bash
# The app's simulator tests in CI (.github/workflows/ci.yml, jobs `ios`,
# `ios-build` and `ios-ui`): picks the newest available iPhone simulator with
# iOS 26 or later, builds the Hasala scheme unsigned for testing while that
# simulator boots, waits until it has finished booting, then runs the tests
# there (xcodebuild build-for-testing and test-without-building: what
# `xcodebuild test` does, with the wait between them), passing the remaining
# arguments through to both (each job's -only-testing or -skip-testing
# selectors). Warnings are errors, as in every CI build.
#
#   ios/scripts/ci-simulator-test.sh RESULT_BUNDLE [XCODEBUILD_ARG...]
#
# The build and the tests can also run on different runners: --build-only
# builds for testing into DERIVED_DATA and boots nothing; --from-build boots the
# simulator and runs the tests of DERIVED_DATA's .xctestrun without building.
# Both pick the simulator the same way, so on the same runner image the build
# matches the simulator the tests run on.
#
#   ios/scripts/ci-simulator-test.sh --build-only DERIVED_DATA [XCODEBUILD_ARG...]
#   ios/scripts/ci-simulator-test.sh --from-build DERIVED_DATA RESULT_BUNDLE [XCODEBUILD_ARG...]
#
# A run that executed no test at all fails: a selector that matches nothing
# (a renamed test class) would otherwise pass with nothing tested.
set -euo pipefail
usage() {
	cat >&2 <<'EOF'
usage: ios/scripts/ci-simulator-test.sh RESULT_BUNDLE [XCODEBUILD_ARG...]
       ios/scripts/ci-simulator-test.sh --build-only DERIVED_DATA [XCODEBUILD_ARG...]
       ios/scripts/ci-simulator-test.sh --from-build DERIVED_DATA RESULT_BUNDLE [XCODEBUILD_ARG...]
EOF
	exit 2
}
mode=all derived="" result=""
case "${1:-}" in
--build-only)
	[[ $# -ge 2 ]] || usage
	mode=build derived="$2"
	shift 2
	;;
--from-build)
	[[ $# -ge 3 ]] || usage
	mode=test derived="$2" result="$3"
	shift 3
	;;
"" | -*) usage ;;
*)
	result="$1"
	shift
	;;
esac
ios="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
rts = json.load(sys.stdin)["devices"]
best = None
for rt, devs in rts.items():
    if ".iOS-" not in rt:
        continue
    ver = tuple(int(x) for x in rt.rsplit(".iOS-", 1)[1].split("-"))
    if ver < (26,):
        continue
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or ver > best[0]):
            best = (ver, d["udid"], d["name"])
if best is None:
    sys.exit("no iPhone simulator with iOS 26 or later")
print(best[1])
')"
xcrun simctl list devices | grep "$udid"

build() {
	xcodebuild build-for-testing \
		-project "$ios/Hasala.xcodeproj" -scheme Hasala \
		-destination "id=$udid" \
		CODE_SIGNING_ALLOWED=NO HASALA_WARNINGS_AS_ERRORS=YES \
		"$@"
}

if [[ "$mode" == build ]]; then
	build -derivedDataPath "$derived" "$@"
	ls "$derived"/Build/Products/*.xctestrun
	exit 0
fi

# The simulator boots during the build, and the tests start only once it has
# finished booting, its first-boot work (data migration, minutes on a fresh
# runner) included: an app launch on a simulator still settling can time out.
xcrun simctl bootstatus "$udid" -b >"$result.boot.log" 2>&1 &
boot=$!
if [[ "$mode" == all ]]; then
	build "$@"
fi
if ! wait "$boot"; then
	cat "$result.boot.log"
	echo "::error::the simulator $udid did not boot"
	exit 1
fi
tail -n 3 "$result.boot.log"
if [[ "$mode" == test ]]; then
	xctestrun=("$derived"/Build/Products/*.xctestrun)
	if [[ ${#xctestrun[@]} -ne 1 || ! -f "${xctestrun[0]}" ]]; then
		echo "::error::expected one .xctestrun in $derived/Build/Products, found: ${xctestrun[*]}"
		exit 1
	fi
	xcodebuild test-without-building \
		-xctestrun "${xctestrun[0]}" \
		-destination "id=$udid" \
		-resultBundlePath "$result" \
		"$@"
else
	xcodebuild test-without-building \
		-project "$ios/Hasala.xcodeproj" -scheme Hasala \
		-destination "id=$udid" \
		-resultBundlePath "$result" \
		CODE_SIGNING_ALLOWED=NO HASALA_WARNINGS_AS_ERRORS=YES \
		"$@"
fi

summary="$(xcrun xcresulttool get test-results summary --path "$result")"
counts="$(python3 -c '
import json, sys
s = json.load(sys.stdin)
print(s["totalTestCount"], s["passedTests"], s["failedTests"], s["skippedTests"])
' <<<"$summary")"
read -r total passed failed skipped <<<"$counts"
echo "ran $total tests: $passed passed, $failed failed, $skipped skipped"
if [[ "$total" -eq 0 || "$passed" -eq 0 ]]; then
	echo "::error::no test ran; check this job's -only-testing/-skip-testing selectors against the test classes"
	exit 1
fi
