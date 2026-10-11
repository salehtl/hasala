#!/usr/bin/env bash
# upload.sh: validate and upload an exported Hasala .ipa to App Store Connect with
# altool (spec 06 §10.2 steps 5–7). Run it by hand, after archive.sh passed and
# you have looked at ios/build/<BUILD>/summary.txt:
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/upload.sh ios/build/<BUILD>/export/Hasala.ipa --yes
#
# Before anything touches the network or the key it refuses (exit 40) an .ipa that is
# not ios/build/<BUILD>/export/Hasala.ipa for its own CFBundleVersion, one whose
# summary.txt is missing, names another build, has a FAIL line, or does not end in
# archive.sh's "PASS <n>/<n> sha256=<sha256>" line for this very file (a summary cut
# short has no such line), and a local trial (archive.sh --allow-dirty /
# --allow-branch writes a TRIAL file beside summary.txt); and (exit 21) a build
# number that is not newer than ios/build/last-build-number.
#
# The key comes from the environment only (asc-env.sh). altool (Xcode 27's, `xcrun
# altool --help`) takes the key id and issuer with --api-key and --api-issuer, and
# reads the private key from --p8-file-path; without that it searches for
# AuthKey_<api-key>.p8 in ./private_keys, ~/private_keys, ~/.private_keys,
# ~/.appstoreconnect/private_keys and then $API_PRIVATE_KEYS_DIR, in that order, so
# a stale copy in one of the first four would win. --p8-file-path names ASC_KEY_PATH
# exactly; API_PRIVATE_KEYS_DIR (its directory) is set too, for the search. Without
# --yes it validates and stops.
#
# The build number is recorded in ios/build/last-build-number before the upload
# starts, so it stays recorded when the upload fails or is interrupted: App Store
# Connect may have taken the number even then, and archive.sh and this script refuse
# a number that is not newer (spec 06 §10.4). A validation alone records nothing.
#
# Exit codes (spec 06 §10.4): 2 usage, 14 key, 21 not newer (or not recordable), 40
# inspection not passed, 50 validation failed, 60 upload failed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

ipa="${1:-}"
confirm="${2:-}"
if [[ -z "$ipa" || ! -f "$ipa" ]] || [[ -n "$confirm" && "$confirm" != "--yes" ]] || (($# > 2)); then
	echo "usage: upload.sh <path/to/Hasala.ipa> [--yes]" >&2
	exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
build=""
if unzip -p "$ipa" Payload/Hasala.app/Info.plist >"$tmp/Info.plist" 2>/dev/null; then
	build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$tmp/Info.plist" 2>/dev/null || true)"
fi
if [[ ! "$build" =~ ^[0-9]{6}\.1[0-9]{4}$ ]]; then
	echo "upload: cannot read a build number (YYMMDD.1HHMM) from $ipa's CFBundleVersion ('$build')" >&2
	exit 40
fi

# --- this must be archive.sh's own export for this build, and it must have passed ------
build_root="$(hasala_build_root "$ios")"
out="$build_root/$build"
ipa_dir="$(cd "$(dirname "$ipa")" && pwd -P)"
want_dir="$(cd "$out/export" 2>/dev/null && pwd -P || true)"
if [[ -z "$want_dir" || "$ipa_dir" != "$want_dir" || "$(basename "$ipa")" != "Hasala.ipa" ]]; then
	echo "upload: $ipa is not $out/export/Hasala.ipa; only the .ipa that archive.sh exported and inspected for build $build can be uploaded" >&2
	exit 40
fi
summary="$out/summary.txt"
if ! hasala_summary_passed "$summary" "$ipa" "$build"; then
	echo "upload: build $build has not passed inspection; it is not uploadable" >&2
	exit 40
fi
if [[ -f "$out/$HASALA_TRIAL_MARKER" ]]; then
	echo "upload: build $build is a local trial ($(head -n1 "$out/$HASALA_TRIAL_MARKER")); archive it again from a clean main" >&2
	exit 40
fi
last_file="$build_root/last-build-number"
if [[ -f "$last_file" ]] && ! hasala_build_newer "$build" "$(cat "$last_file")"; then
	echo "upload: build $build is not newer than the last upload $(cat "$last_file")" >&2
	exit 21
fi

asc_resolve_key || exit 14
API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
export API_PRIVATE_KEYS_DIR
auth=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH")

echo "upload: validating Hasala $build"
if ! xcrun altool --validate-app "$ipa" "${auth[@]}" --output-format json >"$out/validate.json"; then
	cat "$out/validate.json" >&2
	echo "upload: validation failed" >&2
	exit 50
fi
cat "$out/validate.json"

if [[ "$confirm" != "--yes" ]]; then
	echo "upload: validated only. Re-run with --yes to upload build $build."
	exit 0
fi

# Recorded before the upload starts: the number may be spent even if altool fails or
# is interrupted, and it must never be offered again (spec 06 §10.4).
if ! hasala_record_build "$build_root" "$build"; then
	echo "upload: cannot record build $build in $last_file; not uploading" >&2
	exit 21
fi
echo "upload: build $build recorded in $last_file; uploading (this waits for processing)"
if ! xcrun altool --upload-package "$ipa" "${auth[@]}" --wait --output-format json >"$out/upload.json"; then
	cat "$out/upload.json" >&2
	echo "upload: upload failed; build $build stays recorded, so archive a new build rather than re-upload this one" >&2
	exit 60
fi
cat "$out/upload.json"
echo "upload: done; build $build uploaded"
