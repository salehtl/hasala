#!/usr/bin/env bash
# upload.sh: validate and upload an exported Hasala .ipa to App Store Connect with
# altool (spec 06 §10.2 steps 5–7). Run it by hand, after archive.sh passed and
# you have looked at ios/build/<BUILD>/summary.txt:
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/upload.sh ios/build/<BUILD>/export/Hasala.ipa --yes
#
# Before anything touches the network or the key it refuses (exit 40) a build
# whose ios/build/<BUILD>/summary.txt is missing, names another build, or has a
# FAIL line, and a local trial (archive.sh --allow-dirty / --allow-branch writes a
# TRIAL file beside summary.txt); and (exit 21) a build number that is not newer
# than ios/build/last-build-number.
#
# The key comes from the environment only (asc-env.sh). altool finds the .p8 by
# key id in API_PRIVATE_KEYS_DIR, which is set to the directory holding
# ASC_KEY_PATH. Without --yes it validates and stops. On success it records the
# build number in ios/build/last-build-number, which archive.sh and this script
# use to refuse a number that is not newer.
#
# Exit codes (spec 06 §10.4): 2 usage, 14 key, 21 not newer, 40 inspection not
# passed, 50 validation failed, 60 upload failed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

ipa="${1:-}"
confirm="${2:-}"
if [[ -z "$ipa" || ! -f "$ipa" ]] || [[ -n "$confirm" && "$confirm" != "--yes" ]]; then
	echo "usage: upload.sh <path/to/Hasala.ipa> [--yes]" >&2
	exit 2
fi

build="$(unzip -p "$ipa" Payload/Hasala.app/Info.plist | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
if [[ -z "$build" ]]; then
	echo "upload: cannot read CFBundleVersion from $ipa" >&2
	exit 40
fi
out="$(cd "$(dirname "$ipa")/.." && pwd)"
summary="$out/summary.txt"

# --- the archive's own inspection must have passed, for this very build ------------
if [[ ! -f "$summary" ]]; then
	echo "upload: no $summary; only an .ipa that archive.sh exported and inspected can be uploaded" >&2
	exit 40
fi
if [[ "$(head -n1 "$summary")" != "Hasala $build ("* ]]; then
	echo "upload: $summary is for '$(head -n1 "$summary")', not build $build" >&2
	exit 40
fi
if grep -q "^  FAIL" "$summary"; then
	echo "upload: build $build failed inspection (see $summary); it is not uploadable" >&2
	exit 40
fi
if [[ -f "$out/$HASALA_TRIAL_MARKER" ]]; then
	echo "upload: build $build is a local trial ($(head -n1 "$out/$HASALA_TRIAL_MARKER")); archive it again from a clean main" >&2
	exit 40
fi
last_file="$ios/build/last-build-number"
if [[ -f "$last_file" ]] && ! hasala_build_newer "$build" "$(cat "$last_file")"; then
	echo "upload: build $build is not newer than the last upload $(cat "$last_file")" >&2
	exit 21
fi

asc_resolve_key || exit 14
API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
export API_PRIVATE_KEYS_DIR

echo "upload: validating Hasala $build"
if ! xcrun altool --validate-app -f "$ipa" -t ios \
	--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --output-format json >"$out/validate.json"; then
	cat "$out/validate.json" >&2
	echo "upload: validation failed" >&2
	exit 50
fi
cat "$out/validate.json"

if [[ "$confirm" != "--yes" ]]; then
	echo "upload: validated only. Re-run with --yes to upload build $build."
	exit 0
fi

echo "upload: uploading Hasala $build (this waits for processing)"
if ! xcrun altool --upload-package "$ipa" \
	--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait --output-format json >"$out/upload.json"; then
	cat "$out/upload.json" >&2
	# The number may be spent even though altool failed: record it anyway so the
	# same number is never offered again (spec 06 §10.4).
	mkdir -p "$ios/build"
	echo "$build" >"$ios/build/last-build-number"
	echo "upload: upload failed; never re-upload the same number, archive a new build" >&2
	exit 60
fi
cat "$out/upload.json"

mkdir -p "$ios/build"
echo "$build" >"$ios/build/last-build-number"
echo "upload: done; build $build recorded in ios/build/last-build-number"
