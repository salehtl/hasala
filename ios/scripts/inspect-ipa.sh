#!/usr/bin/env bash
# inspect-ipa.sh: the spec 06 §10.3 inspection of an exported Hasala .ipa, the checks
# that apply to the A0 app (the widget and the NSE join at A1). archive.sh runs it on
# every export and keeps its output as ios/build/<BUILD>/summary.txt; upload.sh only
# uploads an .ipa whose summary ends in the PASS line for that very file.
#
#   inspect-ipa.sh <ipa> <build> <marketing-version> <commit> <non-exempt-encryption>
#
# archive.sh passes what it built: the CFBundleVersion it set, MARKETING_VERSION from
# ios/Config, the HasalaGitCommit it set, and its export-compliance constant (true or
# false). The output is a header line, one line per check ("  ok    ..." or
# "  FAIL  ..."), the .ipa's size, and only when every check passed, last:
#
#   PASS <n>/<n> sha256=<SHA-256 of the .ipa that was inspected>
#
# Exit 0 when every check passed, 40 when one failed or the .ipa cannot be read, 2 on
# bad arguments. Every check fails closed: a tool that fails or a file that is missing
# counts as a failure, never as "nothing found". No tool is piped into grep; its output
# goes to a file that grep reads (see hasala_absent in release-common.sh). Offline, no
# key; macOS tools by absolute path, so it also runs in the Nix devShell.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

usage() {
	echo "usage: inspect-ipa.sh <ipa> <build> <marketing-version> <commit> <true|false>" >&2
	exit 2
}
(($# == 5)) || usage
ipa="$1" build="$2" marketing="$3" commit="$4" encryption="$5"
[[ -f "$ipa" ]] || usage
[[ "$build" =~ ^[0-9]{6}\.1[0-9]{4}$ ]] || usage
[[ "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || usage
[[ "$encryption" == true || "$encryption" == false ]] || usage

echo "Hasala $build ($commit)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Inspect a private copy, so the sha256 in the PASS line is of the very bytes inspected.
cp -- "$ipa" "$work/inspected.ipa"
if ! sha="$(hasala_sha256 "$work/inspected.ipa")" || ! unzip -q "$work/inspected.ipa" -d "$work/x"; then
	echo "  FAIL  the .ipa can be hashed and unzipped"
	exit 40
fi
app="$work/x/Payload/Hasala.app"
bin="$app/Hasala"
info="$app/Info.plist"
ents="$work/entitlements.plist"
strs="$work/strings.txt"
golden="$here/golden/app.release.entitlements.plist"

# --- what the checks read ----------------------------------------------------------
# Each is made once; a failure here leaves the file missing or empty, and every check
# that reads it then fails.
if ! /usr/bin/codesign -d --entitlements - --xml "$app" >"$ents" 2>/dev/null; then rm -f "$ents"; fi
# strings "-": every byte of the binary, not only its sections.
if [[ ! -s "$bin" ]] || ! /usr/bin/strings - -- "$bin" >"$strs" 2>/dev/null; then rm -f "$strs"; fi

# plist_get FILE KEY: prints a top-level string, integer or boolean (true/false).
# Exit 3 when KEY is absent, other non-zero when FILE is not a plist dictionary.
plist_get() {
	/usr/bin/python3 -I - "$1" "$2" <<'PY'
import os, plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
except Exception as e:
    print(f"        {os.path.basename(sys.argv[1])}: {type(e).__name__}", file=sys.stderr)
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if sys.argv[2] not in d:
    sys.exit(3)
v = d[sys.argv[2]]
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, (str, int)):
    print(v)
else:
    sys.exit(4)
PY
}
# is FILE KEY VALUE: KEY is present with exactly VALUE.
is() {
	local got
	got="$(plist_get "$1" "$2")" && [[ "$got" == "$3" ]]
}
# lacks FILE KEY: FILE is a readable plist dictionary without KEY.
lacks() {
	local rc=0
	plist_get "$1" "$2" >/dev/null 2>&1 || rc=$?
	[[ "$rc" == 3 ]]
}
valid_plist() { [[ -s "$1" ]] && /usr/bin/plutil -lint -s "$1" >/dev/null; }

# I1: the entitlements equal the golden file exactly, except beta-reports-active
# (Apple adds it) and the order inside arrays.
ents_match_golden() {
	valid_plist "$ents" || return 1
	/usr/bin/python3 -I - "$golden" "$ents" <<'PY'
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

# I5: the privacy manifest is valid, tracks nothing, and declares exactly the five
# collected data types of spec 06 (each once, none used for tracking).
privacy_manifest_ok() {
	valid_plist "$app/PrivacyInfo.xcprivacy" || return 1
	/usr/bin/python3 -I - "$app/PrivacyInfo.xcprivacy" <<'PY'
import plistlib, sys
want = {"NSPrivacyCollectedDataType" + t for t in
        ("UserID", "DeviceID", "EmailAddress", "Name", "OtherFinancialInfo")}
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
bad = []
if d.get("NSPrivacyTracking") is not False:
    bad.append("NSPrivacyTracking is not false")
entries = d.get("NSPrivacyCollectedDataTypes")
if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
    bad.append("NSPrivacyCollectedDataTypes is not a list of dictionaries")
    entries = []
got = [e.get("NSPrivacyCollectedDataType") for e in entries]
if len(got) != len(want) or set(got) != want:
    bad.append(f"collected types {got}, want exactly {sorted(want)}")
for e in entries:
    if e.get("NSPrivacyCollectedDataTypeTracking") is not False:
        bad.append(f"{e.get('NSPrivacyCollectedDataType')} is not marked as not used for tracking")
for b in bad:
    print("        " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

# I6: no mail, fixtures, databases or keys anywhere in the payload.
no_forbidden_files() {
	[[ -d "$app" ]] || return 1
	find "$work/x/Payload" \( -iname "*.eml" -o -iname "*.mbox" -o -path "*conformance*" -o -path "*fixtures*" \
		-o -iname "*.sqlite" -o -iname "*.db" -o -iname "*.p8" -o -iname "*.env" \) -print >"$work/forbidden.txt" || return 1
	if [[ -s "$work/forbidden.txt" ]]; then
		sed 's/^/        /' "$work/forbidden.txt" >&2
		return 1
	fi
}

# I8: nothing links JavaScriptCore (the load commands must list libSystem, or the
# listing is not one).
no_javascriptcore() {
	[[ -s "$bin" ]] && /usr/bin/otool -L "$bin" >"$work/linked.txt" &&
		grep -q libSystem "$work/linked.txt" && hasala_absent 'JavaScriptCore' "$work/linked.txt"
}

# I10: the asset catalog has the compiled AppIcon.
icon_compiled() {
	[[ -s "$app/Assets.car" ]] && /usr/bin/xcrun assetutil --info "$app/Assets.car" >"$work/assets.json" 2>/dev/null &&
		/usr/bin/python3 -I - "$work/assets.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    items = json.load(f)
sys.exit(0 if any(isinstance(i, dict) and i.get("Name") == "AppIcon" for i in items) else 1)
PY
}

# I11: the deployment target is iOS 26.0.
minos_26() {
	[[ -s "$bin" ]] && /usr/bin/xcrun vtool -show-build "$bin" >"$work/build-version.txt" 2>/dev/null &&
		grep -qE '^[[:space:]]*minos 26\.0$' "$work/build-version.txt"
}

pass=0 total=0
check() {
	local label="$1"
	shift
	total=$((total + 1))
	if "$@"; then
		echo "  ok    $label"
		pass=$((pass + 1))
	else
		echo "  FAIL  $label"
	fi
}

check "I3 CFBundleVersion is $build" is "$info" CFBundleVersion "$build"
check "I3 CFBundleShortVersionString is $marketing (MARKETING_VERSION)" is "$info" CFBundleShortVersionString "$marketing"
check "I3 HasalaGitCommit is $commit" is "$info" HasalaGitCommit "$commit"
check "I4 ITSAppUsesNonExemptEncryption is $encryption" is "$info" ITSAppUsesNonExemptEncryption "$encryption"
check "I4 no CFBundleURLTypes" lacks "$info" CFBundleURLTypes
check "I4 no NSAppTransportSecurity" lacks "$info" NSAppTransportSecurity
check "I1 aps-environment is production" is "$ents" aps-environment production
check "I1 get-task-allow is false" is "$ents" get-task-allow false
check "I1 no ?mode=developer domain" eval 'valid_plist "$ents" && hasala_absent "mode=developer" "$ents"'
check "I1 entitlements equal golden/app.release.entitlements.plist" ents_match_golden
check "I5 PrivacyInfo.xcprivacy valid; collects exactly UserID, DeviceID, EmailAddress, Name, OtherFinancialInfo" privacy_manifest_ok
check "I6 no mail, fixtures, databases or keys" no_forbidden_files
# Every file, binaries included (the Mach-O, the binary Info.plist, Assets.car).
check "I7 no secrets in any file" eval '[[ -d "$app" ]] && hasala_absent "GOCSPX-|BEGIN (EC |RSA )?PRIVATE KEY|AuthKey_|HASALA_[A-Z_]*KEY=" "$work/x/Payload"'
check "I8 no JavaScriptCore" no_javascriptcore
check "I10 icon compiled" icon_compiled
check "I11 minos 26.0" minos_26
check "I12 no dev hosts" eval '[[ -s "$strs" ]] && hasala_absent "localhost|127\.0\.0\.1|sandbox\.push|mode=developer" "$strs"'
# Release links no HasalaMocks (spec 04 §1.4): no mock module, scenario or persona.
check "AT-REV-4 no mock data (HasalaMocks)" eval '[[ -s "$strs" ]] && hasala_absent "HasalaMocks|HasalaScenario|Maya Rahman" "$strs"'

size="$(/usr/bin/stat -f '%z' "$ipa" 2>/dev/null || echo '?')"
echo "ipa: $ipa ($size bytes)"
if ((total > 0 && pass == total)); then
	echo "PASS $pass/$total sha256=$sha"
	exit 0
fi
exit 40
