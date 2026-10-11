#!/usr/bin/env bash
# The spec 06 §8 vectors for build_number.sh (AT-04).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
check() {
	local got
	got="$("$here/build_number.sh" "$1")"
	if [[ "$got" == "$2" ]]; then echo "ok   $1 -> $got"; else echo "FAIL $1 -> $got (want $2)"; fail=1; fi
}
check 2026-10-11T15:30:59Z 261011.11530
check 2026-01-02T03:04:00Z 260102.10304
check 2026-12-31T23:59:59Z 261231.12359
check 2027-01-01T00:00:00Z 270101.10000
check 2026-10-11T15:30:00+04:00 261011.11130
if "$here/build_number.sh" 2026-10-11T15:30:00 >/dev/null 2>&1; then
	echo "FAIL an instant without a zone was accepted"
	fail=1
else
	echo "ok   an instant without a zone is refused"
fi
exit "$fail"
