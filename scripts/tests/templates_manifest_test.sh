#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
seed=server/internal/tmpl/seed
manifest=ios/HasalaCore/Sources/HasalaCore/Resources/TemplatesManifest.swift
failures=0

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi | cut -d' ' -f1; }

entry() { printf '    Entry(file: "%s.json", id: "%s", version: 1, sha256: "%s"),\n' "$1" "$1" "$2"; }

fresh() {
	rm -rf "$work/t"
	mkdir -p "$work/t/scripts" "$work/t/$seed" "$work/t/$(dirname "$manifest")"
	cp "$ROOT/scripts/check-templates-manifest.sh" "$work/t/scripts/"
	printf '{"id":"a","version":1}\n' >"$work/t/$seed/a.json"
	printf '{"id":"b","version":1}\n' >"$work/t/$seed/b.json"
	{
		echo 'public enum TemplatesManifest {'
		entry a "$(sha "$work/t/$seed/a.json")"
		entry b "$(sha "$work/t/$seed/b.json")"
		echo '}'
	} >"$work/t/$manifest"
}

expect() {
	local name="$1" want="$2" rc=0
	"$work/t/scripts/check-templates-manifest.sh" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
	if [[ -n "${3:-}" ]] && ! grep -qF -- "$3" "$work/out"; then
		echo "FAIL $name: the output does not say '$3'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

fresh
expect "a manifest that names every seed by its hash" 0

fresh
printf '{"id":"a","version":2}\n' >"$work/t/$seed/a.json"
expect "a seed changed without a new manifest" 1 "a.json"

fresh
sed -i.bak '/"b.json"/d' "$work/t/$manifest"
expect "a seed the manifest does not list" 1 "b.json"

fresh
entry c "$(sha "$work/t/$seed/a.json")" >>"$work/t/$manifest"
expect "a manifest entry with no seed" 1 "c.json"

fresh
rm "$work/t/$manifest"
expect "no manifest" 1

exit "$((failures > 0))"
