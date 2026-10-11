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

# The monotonicity rule archive.sh and upload.sh share (code 21).
# shellcheck source=../release-common.sh
source "$here/release-common.sh"
newer() {
	local verdict=no
	if hasala_build_newer "$1" "$2"; then verdict=yes; fi
	if [[ "$verdict" == "$3" ]]; then echo "ok   $1 newer than $2: $verdict"; else echo "FAIL $1 newer than $2: $verdict (want $3)"; fail=1; fi
}
newer 261011.11531 261011.11530 yes
newer 261011.11530 261011.11530 no
newer 261011.11529 261011.11530 no
newer 261012.10000 261011.12359 yes
newer 261011.12359 261012.10000 no
newer 270101.10000 261231.12359 yes
newer 261011.11530 garbage no
newer 0.1.0 261011.11530 no
exit "$fail"
