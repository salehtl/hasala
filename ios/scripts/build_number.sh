#!/usr/bin/env bash
# build_number.sh <iso8601>: the CFBundleVersion for an archive made at that instant
# (spec 06 §8): YYMMDD.1HHMM in UTC. The literal 1 keeps the second component free
# of a leading zero, so build numbers compare correctly component by component.
#
#   ios/scripts/build_number.sh "$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # -> 261011.11530
#
# Accepts a trailing Z or a ±HH:MM / ±HHMM offset (converted to UTC first). BSD
# date(1) by absolute path: the Nix devShell puts GNU date first on PATH, which has
# no -j and whose -f reads a file of dates. Two instants in the same UTC minute give
# the same number; archive.sh refuses a second archive under a number that already
# has a directory.
set -euo pipefail

in="${1:?usage: build_number.sh <iso8601 instant>}"
norm="$in"
case "$norm" in
*Z) norm="${norm%Z}+0000" ;;
*[+-][0-9][0-9]:[0-9][0-9]) norm="${norm:0:${#norm}-3}${norm: -2}" ;;
*[+-][0-9][0-9][0-9][0-9]) ;;
*)
	echo "build_number: $in has no time zone (use Z or an offset)" >&2
	exit 2
	;;
esac
if ! out="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$norm" '+%y%m%d.1%H%M' 2>/dev/null)"; then
	echo "build_number: cannot parse $in" >&2
	exit 2
fi
echo "$out"
