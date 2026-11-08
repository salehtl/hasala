#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
seed="$ROOT/server/internal/tmpl/seed"
manifest="$ROOT/ios/HasalaCore/Sources/HasalaCore/Resources/TemplatesManifest.swift"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -- "$1"
	else
		shasum -a 256 -- "$1"
	fi | cut -d' ' -f1
}

if [[ ! -f "$manifest" ]]; then
	echo "$manifest is missing; run swift ios/tools/templates/sync.swift" >&2
	exit 1
fi

want="$(for f in "$seed"/*.json; do printf '%s %s\n' "${f##*/}" "$(sha256 "$f")"; done | LC_ALL=C sort)"
have="$(sed -nE 's/^ *Entry\(file: "([^"]+)", id: "[^"]*", version: [0-9]+, sha256: "([0-9a-f]{64})"\),$/\1 \2/p' "$manifest" | LC_ALL=C sort)"

if [[ "$want" != "$have" ]]; then
	echo "TemplatesManifest.swift does not match server/internal/tmpl/seed; run swift ios/tools/templates/sync.swift" >&2
	diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") >&2 || true
	exit 1
fi
echo "$(printf '%s\n' "$want" | wc -l | tr -d ' ') manifest entries match the seed hashes"
