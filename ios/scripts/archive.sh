#!/usr/bin/env bash
# archive.sh: archive Hasala (Release) and export a signed App Store Connect .ipa,
# on this Mac, with automatic signing (spec 06 §9, §10.1–§10.2). It never uploads;
# ios/scripts/upload.sh does that, separately and on purpose.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/archive.sh [--allow-dirty] [--allow-branch]
#
# --allow-dirty and --allow-branch are for local trials only: the build is marked
# with a TRIAL file beside summary.txt and upload.sh refuses it.
#
# The API key comes from the environment (see asc-env.sh); xcodebuild uses it with
# -allowProvisioningUpdates to create or refresh the App ID's profiles and the
# cloud-managed distribution certificate. Output, all under ios/build/ (git-ignored):
#
#   ios/build/<BUILD>/Hasala.xcarchive
#   ios/build/<BUILD>/export/Hasala.ipa
#   ios/build/<BUILD>/archive.log, export.log, summary.txt
#
# Exit codes (spec 06 §10.4; PRECHECK reduced to 10, 11, 14, 16, 21 for Gate A0, §15.2):
#   10 dirty tree   11 branch is not main   14 key or asc.env missing or unsafe
#   16 Xcode is not 27.x   21 build number not newer than the last upload
#   30 archive failed   31 export failed   40 the exported .ipa failed inspection (§10.3)
set -euo pipefail

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

# --- precheck (10, 11, 14, 16, 21) ---------------------------------------------------
trial=()
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
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
asc_resolve_key || exit 14
xcode="$(xcodebuild -version 2>/dev/null | head -n1 || true)"
if [[ ! "$xcode" =~ ^Xcode\ 27\. ]]; then
	echo "archive: needs Xcode 27.x (xcodebuild -version says '${xcode:-nothing}')" >&2
	exit 16
fi

BUILD="$("$here/build_number.sh" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
SHA="$(git -C "$repo" rev-parse --short=12 HEAD)"
last_file="$ios/build/last-build-number"
if [[ -f "$last_file" ]]; then
	last="$(cat "$last_file")"
	if ! hasala_build_newer "$BUILD" "$last"; then
		echo "archive: build $BUILD is not newer than the last upload $last; wait a minute" >&2
		exit 21
	fi
fi

OUT="$ios/build/$BUILD"
mkdir -p "$OUT"
if ((${#trial[@]})); then
	printf 'local trial, not for upload: %s\n' "${trial[@]}" >"$OUT/$HASALA_TRIAL_MARKER"
fi
auth=(
	-allowProvisioningUpdates
	-authenticationKeyPath "$ASC_KEY_PATH"
	-authenticationKeyID "$ASC_KEY_ID"
	-authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "archive: Hasala $BUILD at $SHA -> $OUT"

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
	if grep -q "cloud-managed distribution certificates" "$OUT/export.log"; then
		cat >&2 <<'HINT'
archive: the API key may not use cloud-managed distribution certificates. Either
  - use a team API key with the Admin role (App Store Connect > Users and Access >
    Integrations > Team Keys; a key's role cannot be raised, so generate a new one), or
  - give the key's access to cloud-managed distribution certificates, or
  - once, in Xcode signed in as the Account Holder: Organizer > this archive >
    Distribute App > App Store Connect > Export, which creates the distribution
    certificate (spec 06 §9); later exports then need only the key.
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

# --- inspect (spec 06 §10.3, the checks that apply to the A0 app; inspect-ipa.sh will
# own the full list, with the widget and NSE, from A1) ---------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$IPA" -d "$work"
app="$work/Payload/Hasala.app"
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fi; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist" 2>/dev/null; }
ents="$work/ents.plist"
codesign -d --entitlements - --xml "$app" >"$ents" 2>/dev/null || true
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "$ents" 2>/dev/null; }
# I1: the entitlements equal the golden file exactly, except beta-reports-active
# (Apple adds it) and the order inside arrays.
ents_match_golden() {
	/usr/bin/python3 -I - "$here/golden/app.release.entitlements.plist" "$ents" <<'PY'
import plistlib, sys
def norm(path):
    with open(path, "rb") as f:
        d = plistlib.load(f)
    d.pop("beta-reports-active", None)
    return {k: sorted(v) if isinstance(v, list) else v for k, v in d.items()}
want, got = norm(sys.argv[1]), norm(sys.argv[2])
for k in sorted(set(want) | set(got)):
    if want.get(k) != got.get(k):
        print(f"        {k}: want {want.get(k)!r}, got {got.get(k)!r}", file=sys.stderr)
sys.exit(0 if want == got else 1)
PY
}

{
	echo "Hasala $BUILD ($SHA)"
	check "I3 CFBundleVersion is $BUILD" '[[ "$(plist CFBundleVersion)" == "$BUILD" ]]'
	check "I3 CFBundleShortVersionString is 0.1.0" '[[ "$(plist CFBundleShortVersionString)" == "0.1.0" ]]'
	check "I3 HasalaGitCommit is $SHA" '[[ "$(plist HasalaGitCommit)" == "$SHA" ]]'
	check "I4 ITSAppUsesNonExemptEncryption is false" '[[ "$(plist ITSAppUsesNonExemptEncryption)" == "false" ]]'
	check "I4 no CFBundleURLTypes" '! plist CFBundleURLTypes >/dev/null'
	check "I4 no NSAppTransportSecurity" '! plist NSAppTransportSecurity >/dev/null'
	check "I1 aps-environment is production" '[[ "$(ent aps-environment)" == "production" ]]'
	check "I1 get-task-allow is false" '[[ "$(ent get-task-allow)" == "false" ]]'
	check "I1 no ?mode=developer domain" '! grep -q "mode=developer" "$ents"'
	check "I1 entitlements equal golden/app.release.entitlements.plist" 'ents_match_golden'
	check "I5 PrivacyInfo.xcprivacy present and valid" 'plutil -lint -s "$app/PrivacyInfo.xcprivacy"'
	check "I6 no mail, fixtures, databases or keys" '[[ -z "$(find "$work/Payload" \( -iname "*.eml" -o -iname "*.mbox" -o -path "*conformance*" -o -path "*fixtures*" -o -iname "*.sqlite" -o -iname "*.db" -o -iname "*.p8" -o -iname "*.env" \) -print)" ]]'
	check "I7 no secrets" '! grep -rIlE "GOCSPX-|BEGIN (EC |RSA )?PRIVATE KEY|AuthKey_|HASALA_[A-Z_]*KEY=" "$work/Payload" >/dev/null'
	check "I8 no JavaScriptCore" '! otool -L "$app/Hasala" | grep -q JavaScriptCore'
	check "I10 icon compiled" '[[ "$(xcrun assetutil --info "$app/Assets.car" | grep -c "\"Name\" : \"AppIcon\"")" -gt 0 ]]'
	check "I11 minos 26.0" 'xcrun vtool -show-build "$app/Hasala" | grep -q "minos 26.0"'
	check "I12 no dev hosts" '! strings "$app/Hasala" | grep -qE "localhost|127\.0\.0\.1|sandbox\.push|mode=developer"'
	echo "ipa: $IPA ($(du -h "$IPA" | cut -f1))"
	if [[ -f "$OUT/$HASALA_TRIAL_MARKER" ]]; then cat "$OUT/$HASALA_TRIAL_MARKER"; fi
} 2>&1 | tee "$OUT/summary.txt"

if grep -q "^  FAIL" "$OUT/summary.txt"; then
	echo "archive: the exported .ipa failed a check; do not upload it" >&2
	exit 40
fi
if [[ -f "$OUT/$HASALA_TRIAL_MARKER" ]]; then
	echo "archive: done (local trial; upload.sh will refuse this build)"
else
	echo "archive: done. To upload (not done here): ios/scripts/upload.sh $IPA"
fi
