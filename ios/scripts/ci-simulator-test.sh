#!/usr/bin/env bash
# The app's simulator tests in CI (.github/workflows/ci.yml, jobs `ios` and
# `ios-ui`): picks the newest available iPhone simulator with iOS 26 or later,
# builds the Hasala scheme unsigned for testing while that simulator boots, waits
# until it has finished booting, then runs the tests there (xcodebuild
# build-for-testing and test-without-building: what `xcodebuild test` does, with
# the wait between them), passing the remaining arguments through to both (each
# job's -only-testing or -skip-testing selectors). Warnings are errors, as in
# every CI build.
#
#   ios/scripts/ci-simulator-test.sh RESULT_BUNDLE [XCODEBUILD_ARG...]
#
# A run that executed no test at all fails: a selector that matches nothing
# (a renamed test class) would otherwise pass with nothing tested.
set -euo pipefail
if [[ $# -lt 1 ]]; then
	echo "usage: ios/scripts/ci-simulator-test.sh RESULT_BUNDLE [XCODEBUILD_ARG...]" >&2
	exit 2
fi
result="$1"
shift
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

# The simulator boots during the build, and the tests start only once it has
# finished booting, its first-boot work (data migration, minutes on a fresh
# runner) included: an app launch on a simulator still settling can time out.
xcrun simctl bootstatus "$udid" -b >"$result.boot.log" 2>&1 &
boot=$!
xcodebuild build-for-testing \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala \
	-destination "id=$udid" \
	CODE_SIGNING_ALLOWED=NO HASALA_WARNINGS_AS_ERRORS=YES \
	"$@"
if ! wait "$boot"; then
	cat "$result.boot.log"
	echo "::error::the simulator $udid did not boot"
	exit 1
fi
tail -n 3 "$result.boot.log"
xcodebuild test-without-building \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala \
	-destination "id=$udid" \
	-resultBundlePath "$result" \
	CODE_SIGNING_ALLOWED=NO HASALA_WARNINGS_AS_ERRORS=YES \
	"$@"

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
