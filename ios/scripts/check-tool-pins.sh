#!/usr/bin/env bash
set -euo pipefail

core="$(cd "$(dirname "${BASH_SOURCE[0]}")/../HasalaCore" && pwd)"
want="$(jq -S '.pins' "$core/Package.resolved")"
fail=0
for f in "$core"/Tools/*/Package.resolved; do
	if [[ "$(jq -S '.pins' "$f")" != "$want" ]]; then
		echo "check-tool-pins: ${f#"$core"/} pins differ from ios/HasalaCore/Package.resolved; copy them from there" >&2
		fail=1
	fi
done
exit "$fail"
