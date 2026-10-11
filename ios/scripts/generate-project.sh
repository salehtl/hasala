#!/usr/bin/env bash
# generate-project.sh: regenerate ios/Hasala.xcodeproj from ios/project.yml.
#
#   ios/scripts/generate-project.sh          # regenerate in place
#   ios/scripts/generate-project.sh --check  # fail if the committed project is stale (AT-01)
#
# The project needs XcodeGen 2.46.0 exactly (spec 06 §1): 2.46 is the first release
# that writes synchronized-folder build-file exceptions (Info.plist, entitlements)
# and a Resources phase for synchronized folders; 2.44.1, which the Nix devShell
# currently ships, writes neither, so its project builds an app with no asset
# catalog and no privacy manifest. Set XCODEGEN to pick a binary explicitly.
set -euo pipefail

want="2.46.0"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pick() {
	for c in "${XCODEGEN:-}" "$(command -v xcodegen 2>/dev/null || true)" /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
		[[ -n "$c" && -x "$c" ]] || continue
		if [[ "$("$c" --version 2>/dev/null | sed -n 's/^Version: //p')" == "$want" ]]; then
			echo "$c"
			return 0
		fi
	done
	return 1
}

if ! xg="$(pick)"; then
	echo "generate-project: XcodeGen $want not found (set XCODEGEN=/path/to/xcodegen)" >&2
	exit 2
fi

if [[ "${1:-}" == "--check" ]]; then
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	# XcodeGen reads the target folders (it lists Info.plist and the entitlements as
	# exceptions only if they exist), so the check runs on a copy of the sources.
	for d in project.yml Config Hasala HasalaTests HasalaUITests HasalaKit/Package.swift; do
		mkdir -p "$tmp/$(dirname "$d")"
		cp -R "$here/$d" "$tmp/$d"
	done
	(cd "$tmp" && "$xg" generate --spec project.yml --quiet)
	# Git keeps files, not directories: compare the files only (Xcode leaves empty
	# directories such as project.xcworkspace/xcshareddata behind after a build).
	mkdir -p "$tmp/committed"
	(cd "$here" && find Hasala.xcodeproj -type f ! -path '*/xcuserdata/*' -print0 | xargs -0 -I{} rsync -R {} "$tmp/committed/")
	if ! diff -ru "$tmp/committed/Hasala.xcodeproj" "$tmp/Hasala.xcodeproj" >&2; then
		echo "generate-project: ios/Hasala.xcodeproj is stale; run ios/scripts/generate-project.sh and commit" >&2
		exit 1
	fi
	echo "ios/Hasala.xcodeproj matches ios/project.yml (XcodeGen $want)"
else
	(cd "$here" && "$xg" generate --spec project.yml --quiet)
	echo "generated ios/Hasala.xcodeproj with XcodeGen $want"
fi
