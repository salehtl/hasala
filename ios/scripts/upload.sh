#!/usr/bin/env bash
# upload.sh: validate and upload an exported Hasala .ipa to App Store Connect with
# altool (spec 06 §10.2 steps 5–7). Run it by hand, after archive.sh passed and
# you have looked at ios/build/<BUILD>/summary.txt:
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/upload.sh ios/build/<BUILD>/export/Hasala.ipa --yes
#
# The key comes from the environment only (asc-env.sh). altool finds the .p8 by
# key id in API_PRIVATE_KEYS_DIR, which is set to the directory holding
# ASC_KEY_PATH. Without --yes it validates and stops. On success it records the
# build number in ios/build/last-build-number, which archive.sh uses to refuse a
# number that is not newer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"

ipa="${1:-}"
confirm="${2:-}"
if [[ -z "$ipa" || ! -f "$ipa" ]]; then
	echo "usage: upload.sh <path/to/Hasala.ipa> [--yes]" >&2
	exit 2
fi
asc_resolve_key || exit 14
API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
export API_PRIVATE_KEYS_DIR

build="$(unzip -p "$ipa" Payload/Hasala.app/Info.plist | plutil -extract CFBundleVersion raw -o - -)"
out="$(dirname "$ipa")/.."

echo "upload: validating Hasala $build"
xcrun altool --validate-app -f "$ipa" -t ios \
	--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --output-format json | tee "$out/validate.json"

if [[ "$confirm" != "--yes" ]]; then
	echo "upload: validated only. Re-run with --yes to upload build $build."
	exit 0
fi

echo "upload: uploading Hasala $build (this waits for processing)"
xcrun altool --upload-package "$ipa" \
	--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait --output-format json | tee "$out/upload.json"

mkdir -p "$ios/build"
echo "$build" >"$ios/build/last-build-number"
echo "upload: done; build $build recorded in ios/build/last-build-number"
