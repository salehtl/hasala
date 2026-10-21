#!/usr/bin/env bash
set -euo pipefail

ios="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core="$ios/HasalaCore"
want="$(jq -S '.pins' "$core/Package.resolved")"
fail=0
for f in "$core"/Tools/*/Package.resolved "$ios/Hasala.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; do
	if [[ ! -f "$f" || "$(jq -S '.pins' "$f")" != "$want" ]]; then
		echo "check-tool-pins: ios/${f#"$ios"/} pins differ from ios/HasalaCore/Package.resolved; copy them from there" >&2
		fail=1
	fi
done
exit "$fail"
