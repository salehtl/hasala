#!/usr/bin/env bash
# archive.sh: archive Hasala (Release) and export a signed App Store Connect .ipa,
# on this Mac: the archive with automatic development signing, the export with manual
# distribution signing (see below; spec 06 §10.1–§10.2). It never uploads;
# ios/scripts/upload.sh does that, separately and on purpose.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/archive.sh [--allow-dirty] [--allow-branch]
#
# --allow-dirty and --allow-branch are for local trials only: the build is marked
# with a TRIAL file beside summary.txt and upload.sh refuses it.
#
# One archive per build number: build numbers are per UTC minute (build_number.sh), and
# a second archive in the same minute is refused (21) rather than reuse the first one's
# directory. The exported .ipa is inspected by inspect-ipa.sh (spec 06 §10.3), whose
# output is summary.txt; it ends in "PASS <n>/<n> sha256=<.ipa's sha256>" only when
# every check passed, and upload.sh uploads nothing else.
#
# The API key comes from the environment (see asc-env.sh); xcodebuild uses it with
# -allowProvisioningUpdates to create or refresh the development profile for the
# archive. The export is signed MANUALLY (ExportOptions.plist): an "Apple
# Distribution" identity in this Mac's keychain plus the App Store profiles named
# "Hasala App Store" (app.hasala.ios) and "Hasala Widgets App Store"
# (app.hasala.ios.widgets), all created through the App Store Connect API (the upload key
# is App Manager, which may not use cloud-managed distribution certificates). Output,
# all under ios/build/ (git-ignored):
#
#   ios/build/<BUILD>/Hasala.xcarchive
#   ios/build/<BUILD>/export/Hasala.ipa
#   ios/build/<BUILD>/archive.log, export.log, summary.txt
#
# Exit codes (spec 06 §10.4; PRECHECK reduced to 10, 11, 13, 14, 16, 21 for Gate A0, §15.2):
#   2 usage, MARKETING_VERSION cannot be read from ios/Config, or HASALA_BUILD_DIR is
#     set without HASALA_TEST_MODE=1 (see hasala_build_root in release-common.sh)
#   10 dirty tree   11 branch is not main   13 the gate failed: an IntegrationStub is
#   left under ios/, or privacy-lint.sh failed (spec 06 §5.4: a required-reason API the
#   privacy manifest doesn't declare)   14 key or asc.env missing or unsafe
#   16 Xcode is not 27.x   21 build number not newer than the last upload, or
#   ios/build/<BUILD>/ exists already (a second archive in the same UTC minute)
#   30 archive failed   31 export failed   40 the exported .ipa failed inspection (§10.3)
set -euo pipefail

# Export compliance (spec 06 §6.2), inspection I4: the value the exported Info.plist's
# ITSAppUsesNonExemptEncryption must have. false (NO) is the spec default and stands
# until the owner signs the answer off. To change the answer, change this line and the
# key in ios/Hasala/Info.plist together (HasalaTests/BuildInfoTests.swift asserts the
# bundle's value too); I4 refuses an .ipa whose Info.plist disagrees with this line.
NON_EXEMPT_ENCRYPTION=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
repo="$(cd "$ios/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

allow_dirty=0
allow_branch=0
for a in "$@"; do
	case "$a" in
	--allow-dirty) allow_dirty=1 ;;
	--allow-branch) allow_branch=1 ;;
	*)
		echo "usage: archive.sh [--allow-dirty] [--allow-branch]" >&2
		exit 2
		;;
	esac
done
# Where builds and last-build-number live: ios/build, unless the script tests moved it.
if ! build_root="$(hasala_build_root "$ios")"; then
	echo "archive: refusing to run with HASALA_BUILD_DIR set outside test mode" >&2
	exit 2
fi

# --- precheck (10, 11, 13, 14, 16, 21) -----------------------------------------------
trial=()
# Assigned first, so a git that fails stops here (set -e) instead of reading as clean.
tree="$(git -C "$repo" status --porcelain)"
if [[ -n "$tree" ]]; then
	if [[ "$allow_dirty" == 1 ]]; then
		echo "archive: WARNING the tree is dirty; HasalaGitCommit names HEAD, not what was built" >&2
		trial+=("dirty tree")
	else
		echo "archive: the working tree is dirty; commit first (or --allow-dirty for a local trial)" >&2
		exit 10
	fi
fi
branch="$(git -C "$repo" branch --show-current)"
if [[ "$branch" != "main" ]]; then
	if [[ "$allow_branch" == 1 ]]; then
		echo "archive: WARNING on branch '${branch:-detached HEAD}', not main" >&2
		trial+=("branch ${branch:-detached HEAD}")
	else
		echo "archive: on branch '${branch:-detached HEAD}'; releases are archived from main (or --allow-branch for a local trial)" >&2
		exit 11
	fi
fi
# The gate (13), before anything is built. First, no IntegrationStub is left under ios/,
# tracked or not (ignored files aside): the integration contracts' stub bodies throw at
# run time. ios/scripts names it (this check and its test), so it is not searched.
stubs_rc=0
stubs="$(git -C "$repo" grep -l --untracked -e IntegrationStub -- ios ':(exclude)ios/scripts')" || stubs_rc=$?
if [[ "$stubs_rc" != 1 ]]; then
	if [[ "$stubs_rc" == 0 ]]; then
		echo "archive: IntegrationStub is still used under ios/; finish these first:" >&2
		sed 's/^/  /' <<<"$stubs" >&2
	else
		echo "archive: cannot search ios/ for IntegrationStub (git grep exit $stubs_rc)" >&2
	fi
	exit 13
fi
# Then required-reason APIs against the privacy manifest (spec 06 §5.4): App Store
# Connect rejects an upload that uses one without declaring it.
if ! "$here/privacy-lint.sh" >&2; then
	echo "archive: privacy-lint.sh failed; declare the API in ios/Hasala/PrivacyInfo.xcprivacy or stop using it" >&2
	exit 13
fi
asc_resolve_key || exit 14
xcode="$(xcodebuild -version 2>/dev/null || true)"
xcode="${xcode%%$'\n'*}"
if [[ ! "$xcode" =~ ^Xcode\ 27\. ]]; then
	echo "archive: needs Xcode 27.x (xcodebuild -version says '${xcode:-nothing}')" >&2
	exit 16
fi
# CFBundleShortVersionString comes from MARKETING_VERSION; I3 checks the .ipa against it.
if ! MARKETING_VERSION="$(hasala_marketing_version "$ios/Config")"; then
	echo "archive: cannot read MARKETING_VERSION from ios/Config/*.xcconfig" >&2
	exit 2
fi

if ! now="$(hasala_now)"; then
	echo "archive: refusing to run with HASALA_TEST_NOW set outside test mode" >&2
	exit 2
fi
BUILD="$("$here/build_number.sh" "$now")"
SHA="$(git -C "$repo" rev-parse --short=12 HEAD)"
last_file="$build_root/last-build-number"
if [[ -f "$last_file" ]]; then
	last="$(cat "$last_file")"
	if ! hasala_build_newer "$BUILD" "$last"; then
		echo "archive: build $BUILD is not newer than the last upload $last; wait a minute" >&2
		exit 21
	fi
fi

# mkdir without -p is the claim on BUILD: it fails when the directory exists, so a
# second archive in the same UTC minute never reuses or overwrites the first one's
# archive, .ipa or summary.
OUT="$build_root/$BUILD"
mkdir -p "$build_root"
if [[ -e "$OUT" ]] || ! mkdir "$OUT"; then
	echo "archive: $OUT exists already: build $BUILD has been archived (one archive per UTC minute); wait a minute" >&2
	exit 21
fi
if ((${#trial[@]})); then
	printf 'local trial, not for upload: %s\n' "${trial[@]}" >"$OUT/$HASALA_TRIAL_MARKER"
fi
auth=(
	-allowProvisioningUpdates
	-authenticationKeyPath "$ASC_KEY_PATH"
	-authenticationKeyID "$ASC_KEY_ID"
	-authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "archive: Hasala $MARKETING_VERSION ($BUILD) at $SHA -> $OUT"

# --- archive ---------------------------------------------------------------------
if ! xcodebuild archive \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala -configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$OUT/Hasala.xcarchive" \
	"${auth[@]}" \
	CURRENT_PROJECT_VERSION="$BUILD" HASALA_GIT_COMMIT="$SHA" \
	>"$OUT/archive.log" 2>&1; then
	echo "archive: xcodebuild archive failed; the signing errors are:" >&2
	grep -E 'error:|No profiles|No signing|Provisioning|certificate|Automatic signing' "$OUT/archive.log" | sort -u | head -40 >&2 || true
	echo "archive: full log: $OUT/archive.log" >&2
	exit 30
fi

# --- export (re-signs for distribution) --------------------------------------------
if ! xcodebuild -exportArchive \
	-archivePath "$OUT/Hasala.xcarchive" \
	-exportPath "$OUT/export" \
	-exportOptionsPlist "$here/ExportOptions.plist" \
	"${auth[@]}" \
	>"$OUT/export.log" 2>&1; then
	echo "archive: xcodebuild -exportArchive failed; the signing errors are:" >&2
	grep -E 'error:|No profiles|No signing|Provisioning|certificate|Cloud|distribution' "$OUT/export.log" | sort -u | head -40 >&2 || true
	if grep -qiE "signing certificate|provisioning profile|No profiles for|cloud-managed" "$OUT/export.log"; then
		cat >&2 <<'HINT'
archive: the export signs manually (ExportOptions.plist) and needs, on this Mac:
  - an "Apple Distribution" identity for team 8CFG28JHP3 in a keychain on the
    search list (security find-identity -v -p codesigning), and
  - the App Store profile named "Hasala App Store" for app.hasala.ios and the one
    named "Hasala Widgets App Store" for app.hasala.ios.widgets (App Group
    group.app.hasala.ios), made with that certificate, installed in
    ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
  Create either through the App Store Connect API (POST /v1/certificates,
  certificateType DISTRIBUTION, with a CSR whose key stays in the keychain;
  POST /v1/profiles, profileType IOS_APP_STORE), or in the developer portal.
  When the certificate changes, make new profiles with that certificate and the
  SAME names, and move the old profile files out of
  ~/Library/Developer/Xcode/UserData/Provisioning Profiles (one name, one profile).
The development archive above is fine; only the distribution re-sign failed.
HINT
	fi
	echo "archive: full log: $OUT/export.log" >&2
	exit 31
fi

IPA="$OUT/export/Hasala.ipa"
[[ -f "$IPA" ]] || {
	echo "archive: export reported success but $IPA is missing" >&2
	exit 31
}

# --- inspect (spec 06 §10.3): inspect-ipa.sh writes summary.txt, whose last line is the
# PASS line only when every check passed. The same test upload.sh applies is run here,
# so "done" below means upload.sh will take this .ipa (unless it is a local trial). ---
summary="$OUT/summary.txt"
inspected=0
"$here/inspect-ipa.sh" "$IPA" "$BUILD" "$MARKETING_VERSION" "$SHA" "$NON_EXEMPT_ENCRYPTION" >"$summary" 2>&1 || inspected=$?
cat "$summary"
if [[ "$inspected" != 0 ]] || ! hasala_summary_passed "$summary" "$IPA" "$BUILD"; then
	echo "archive: the exported .ipa failed inspection; do not upload it" >&2
	exit 40
fi
if [[ -f "$OUT/$HASALA_TRIAL_MARKER" ]]; then
	cat "$OUT/$HASALA_TRIAL_MARKER"
	echo "archive: done (local trial; upload.sh will refuse this build)"
else
	echo "archive: done. To upload (not done here): ios/scripts/upload.sh $IPA"
fi
