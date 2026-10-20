#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/ios/HasalaCore/Tools/OutlookTrustCheck"

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "outlook-trust-check: runs on macOS (it builds HasalaCore's CoreMail with Xcode's Swift)" >&2
	exit 64
fi

swift build --package-path "$PKG" -c release --product outlook-trust-check >&2
exec "$(swift build --package-path "$PKG" -c release --show-bin-path)/outlook-trust-check" "$@"
