#!/usr/bin/env bash
# inspect-ipa.sh (spec 06 §10.3) against synthetic .ipa files. A small app built here
# (a C program compiled for iOS 26.0, the app's own asset catalog and privacy
# manifest, an Info.plist like Xcode's, signed ad hoc with the golden entitlements)
# passes every check and gets the PASS line; each case below breaks one thing and
# must get that check's FAIL line and no PASS line.
#
# Regressions: I12 once piped strings into `grep -q` under pipefail, so a large
# binary with a dev host near its start passed (grep exits at the match, strings dies
# of SIGPIPE, `!` turns the failed pipeline into success); I7 once skipped binary
# files (grep -I), so a secret in the Mach-O or the binary Info.plist passed; I12 and
# AT-REV-4 once read only the main binary, so a dev host in Info.plist (where
# HasalaAPIBaseURL lives) or in a resource passed; I12 once searched for dev hosts in
# lower case only, so http://LOCALHOST:8080 in a resource passed; an .ipa that unpacks
# to mode 000 once left the inspection's temporary directory behind. I6b (the sample
# seed, through check-bundle.sh) and I9 (third-party crypto symbols, imported or
# exported, in any Mach-O) each get a case that breaks them.
#
# Offline and local: Xcode's clang, actool and codesign (ad hoc, no identity, no
# keychain, no provisioning). The "secrets" are assembled at run time, so this file
# holds none of the patterns it tests for.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=../release-common.sh
source "$here/release-common.sh"
work="$(mktemp -d)"
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
fail=0
golden="$here/golden/app.release.entitlements.plist"
marketing="$(hasala_marketing_version "$ios/Config")"
build=991231.12359
commit=0123456789ab

# compile OUT C-FILE [CLANG-ARG...]: an arm64 iOS 26.0 executable.
compile() {
	local out="$1" src="$2"
	shift 2
	/usr/bin/xcrun -sdk iphoneos clang -target arm64-apple-ios26.0 -o "$out" "$src" "$@"
}
# compile_swift OUT SWIFT-FILE: the same, from Swift, optimised as a Release build is.
compile_swift() {
	/usr/bin/xcrun -sdk iphoneos swiftc -O -target arm64-apple-ios26.0 -module-name Hasala -o "$1" "$2"
}

# --- the template: an app that passes every check ------------------------------------
tpl="$work/template/Payload/Hasala.app"
mkdir -p "$tpl"
printf 'int main(void) { return 0; }\n' >"$work/main.c"
compile "$tpl/Hasala" "$work/main.c"
/usr/bin/xcrun actool --compile "$tpl" --platform iphoneos --minimum-deployment-target 26.0 \
	--app-icon AppIcon --output-partial-info-plist "$work/partial.plist" \
	"$ios/Hasala/Resources/Assets.xcassets" >"$work/actool.log" 2>&1
cp "$ios/Hasala/PrivacyInfo.xcprivacy" "$tpl/"
# HasalaCore's resource bundle with the committed sample seed (I6b).
seed_dir="$tpl/HasalaCore_CoreResources.bundle/sample"
mkdir -p "$seed_dir"
cp "$ios/HasalaCore/Sources/HasalaCore/Resources/sample/maya-v1.json" "$seed_dir/"
for kv in "CFBundleExecutable string Hasala" "CFBundleIdentifier string app.hasala.ios" \
	"CFBundleVersion string $build" "CFBundleShortVersionString string $marketing" \
	"HasalaGitCommit string $commit" "ITSAppUsesNonExemptEncryption bool false" \
	"HasalaAPIBaseURL string https://api.hasala.app" "HasalaAssistBaseURL string https://assist.hasala.app"; do
	/usr/libexec/PlistBuddy -c "Add :$kv" "$tpl/Info.plist" >/dev/null
done
/usr/bin/plutil -convert binary1 "$tpl/Info.plist"
# The widget extension, signed ad hoc with its golden entitlements (I1w, I3w, I5w).
appex_golden="$here/golden/widgets.release.entitlements.plist"
tpl_appex="$tpl/PlugIns/HasalaWidgets.appex"
mkdir -p "$tpl_appex"
compile "$tpl_appex/HasalaWidgets" "$work/main.c"
cp "$ios/HasalaWidgets/PrivacyInfo.xcprivacy" "$tpl_appex/"
for kv in "CFBundleExecutable string HasalaWidgets" "CFBundleIdentifier string app.hasala.ios.widgets" \
	"CFBundlePackageType string XPC!" "CFBundleVersion string $build" "CFBundleShortVersionString string $marketing"; do
	/usr/libexec/PlistBuddy -c "Add :$kv" "$tpl_appex/Info.plist" >/dev/null
done
/usr/bin/codesign -s - -f --entitlements "$appex_golden" "$tpl_appex" 2>/dev/null

# variant NAME: a fresh copy of the template; prints its Hasala.app.
variant() {
	rm -rf "${work:?}/$1"
	mkdir -p "$work/$1"
	cp -R "$work/template/Payload" "$work/$1/"
	echo "$work/$1/Payload/Hasala.app"
}
# seal NAME [ENTITLEMENTS|unsigned]: sign NAME's app ad hoc (with the golden
# entitlements unless told otherwise) and zip it into $work/NAME.ipa.
seal() {
	local ents="${2:-$golden}"
	if [[ "$ents" != unsigned ]]; then
		/usr/bin/codesign -s - -f --entitlements "$ents" "$work/$1/Payload/Hasala.app" 2>/dev/null
	fi
	(cd "$work/$1" && zip -qry "$work/$1.ipa" Payload)
}
# inspect NAME WANT [MARKETING [ENCRYPTION]]: inspect-ipa.sh on $work/NAME.ipa with
# the template's expectations; WANT is the exit code it must give.
inspect() {
	local name="$1" want="$2" rc=0
	"$here/inspect-ipa.sh" "$work/$name.ipa" "$build" "${3:-$marketing}" "$commit" "${4:-false}" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
# failed LABEL: the last inspection has "  FAIL  LABEL..." and no PASS line.
failed() {
	if grep -qF -- "  FAIL  $1" "$work/out" && hasala_absent '^PASS ' "$work/out"; then echo "ok   ...FAIL $1, no PASS line"; else
		echo "FAIL the inspection did not fail '$1' (or it still has a PASS line)"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

# only_failed LABEL...: as failed, for each LABEL, and no other check failed.
only_failed() {
	local label n
	for label in "$@"; do failed "$label"; done
	n="$(grep -c '^  FAIL  ' "$work/out" || true)"
	if [[ "$n" == "$#" ]]; then echo "ok   ...and nothing else failed"; else
		echo "FAIL $n checks failed, want only: $*"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

# --- the good app ---------------------------------------------------------------------
variant good >/dev/null
seal good
inspect good 0
if hasala_summary_passed "$work/out" "$work/good.ipa" "$build" 2>"$work/why" &&
	[[ "$(tail -n 1 "$work/out")" == "PASS "*"/"*" sha256=$(hasala_sha256 "$work/good.ipa")" ]]; then
	echo "ok   ...every check passed, and the PASS line, last, has the .ipa's sha256 ($(tail -n 1 "$work/out" | cut -d' ' -f2))"
else
	echo "FAIL the good app's summary is not one upload.sh accepts: $(cat "$work/why")"
	sed 's/^/     /' "$work/out"
	fail=1
fi

# --- I12: a large binary with a dev host near its start (the SIGPIPE regression) ---------
app="$(variant devhost)"
{
	echo 'const char *const table[] = {'
	echo '"http://localhost:8080/",'
	awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\"filler string %06d abcdefghijklmnopqrstuvwxyz\",\n", i }'
	echo '};'
	echo 'int main(int argc, char **argv) { (void)argv; return table[argc][0]; }'
} >"$work/devhost.c"
compile "$app/Hasala" "$work/devhost.c"
/usr/bin/strings - -- "$app/Hasala" >"$work/devhost.strings"
echo "     (the binary is $(wc -c <"$app/Hasala" | tr -d ' ') bytes, its strings $(wc -c <"$work/devhost.strings" | tr -d ' '))"
if (! /usr/bin/strings "$app/Hasala" | grep -qE 'localhost'); then
	echo "     note: on this binary the old I12 (! strings | grep -q) passes; it fails open"
fi
if hasala_absent 'localhost' "$work/devhost.strings"; then
	echo "FAIL hasala_absent missed localhost at the start of a large strings file"
	fail=1
else
	echo "ok   hasala_absent finds localhost at the start of a large strings file"
fi
seal devhost
inspect devhost 40
only_failed "I12 no dev hosts in any file"

# --- I12: every file, not only the main binary -------------------------------------------
# A dev host as the API endpoint, in the binary Info.plist.
app="$(variant api-devhost)"
/usr/bin/plutil -replace HasalaAPIBaseURL -string "http://localhost:8080" "$app/Info.plist"
seal api-devhost
inspect api-devhost 40
only_failed "I12 no dev hosts in any file" "I12 HasalaAPIBaseURL is https://api.hasala.app"

# A dev host in another Info.plist value that has a non-ASCII character, which a
# binary plist stores as UTF-16: no byte search of Info.plist finds it, its XML does.
app="$(variant devhost-utf16)"
/usr/bin/plutil -insert HasalaNote -string "http://localhost:8080/ $(printf '\342\200\223') dev" "$app/Info.plist"
/usr/bin/plutil -convert binary1 "$app/Info.plist"
if hasala_absent 'localhost' "$app/Info.plist"; then
	echo "     (the binary Info.plist holds the dev host as UTF-16; its bytes have no 'localhost')"
else
	echo "FAIL the test's binary Info.plist has 'localhost' in ASCII; this case would not test the XML conversion"
	fail=1
fi
seal devhost-utf16
inspect devhost-utf16 40
only_failed "I12 no dev hosts in any file"

# A dev host in a resource file.
app="$(variant devhost-resource)"
printf '{"api": "http://127.0.0.1:8080/"}\n' >"$app/endpoints.json"
seal devhost-resource
inspect devhost-resource 40
only_failed "I12 no dev hosts in any file"

# A dev host in capitals in a resource file: the dev-host search ignores case.
app="$(variant devhost-upper)"
printf '{"api": "http://LOCALHOST:8080/"}\n' >"$app/endpoints.json"
if hasala_absent 'localhost' "$app/endpoints.json"; then
	echo "     (the resource has no lower-case 'localhost'; only a search that ignores case finds it)"
else
	echo "FAIL the test's resource has 'localhost' in lower case; this case would not test the case-insensitive search"
	fail=1
fi
seal devhost-upper
inspect devhost-upper 40
only_failed "I12 no dev hosts in any file"

# A dev host in a localized .strings resource (a binary plist, the value UTF-16).
app="$(variant devhost-strings)"
mkdir -p "$app/en.lproj"
/usr/libexec/PlistBuddy -c "Add :push string gateway.sandbox.push.apple.com $(printf '\342\200\223') dev" "$app/en.lproj/Localizable.strings" >/dev/null
/usr/bin/plutil -convert binary1 "$app/en.lproj/Localizable.strings"
seal devhost-strings
inspect devhost-strings 40
only_failed "I12 no dev hosts in any file"

# Another endpoint that is not a dev host: only the exact HasalaAPIBaseURL check sees it.
app="$(variant api-staging)"
/usr/bin/plutil -replace HasalaAPIBaseURL -string "https://staging.hasala.app" "$app/Info.plist"
seal api-staging
inspect api-staging 40
only_failed "I12 HasalaAPIBaseURL is https://api.hasala.app"

app="$(variant api-missing)"
/usr/bin/plutil -remove HasalaAPIBaseURL "$app/Info.plist"
seal api-missing
inspect api-missing 40
only_failed "I12 HasalaAPIBaseURL is https://api.hasala.app"

app="$(variant assist-staging)"
/usr/bin/plutil -replace HasalaAssistBaseURL -string "https://staging-assist.hasala.app" "$app/Info.plist"
seal assist-staging
inspect assist-staging 40
only_failed "I12 HasalaAssistBaseURL is https://assist.hasala.app"

app="$(variant assist-devhost)"
/usr/bin/plutil -replace HasalaAssistBaseURL -string "http://localhost:8787" "$app/Info.plist"
seal assist-devhost
inspect assist-devhost 40
only_failed "I12 no dev hosts in any file" "I12 HasalaAssistBaseURL is https://assist.hasala.app"

app="$(variant assist-empty)"
/usr/bin/plutil -replace HasalaAssistBaseURL -string "" "$app/Info.plist"
seal assist-empty
inspect assist-empty 40
only_failed "I12 HasalaAssistBaseURL is https://assist.hasala.app"

app="$(variant assist-missing)"
/usr/bin/plutil -remove HasalaAssistBaseURL "$app/Info.plist"
seal assist-missing
inspect assist-missing 40
only_failed "I12 HasalaAssistBaseURL is https://assist.hasala.app"

# --- I7: secrets in binary files ----------------------------------------------------------
app="$(variant secret-plist)"
/usr/bin/plutil -insert HasalaNote -string "GOC$(echo SPX)-synthetic-test-value" "$app/Info.plist"
/usr/bin/plutil -convert binary1 "$app/Info.plist"
seal secret-plist
inspect secret-plist 40
only_failed "I7 no secrets in any file"

app="$(variant secret-plist-utf16)"
/usr/bin/plutil -insert HasalaNote -string "GOC$(echo SPX)-synthetic $(printf '\342\200\223') test value" "$app/Info.plist"
/usr/bin/plutil -convert binary1 "$app/Info.plist"
seal secret-plist-utf16
inspect secret-plist-utf16 40
only_failed "I7 no secrets in any file"

app="$(variant secret-macho)"
printf 'const char *const note = "%s%s";\nint main(void) { return note[0] == 0; }\n' Auth Key_SYNTHETIC0.p8 >"$work/secret.c"
compile "$app/Hasala" "$work/secret.c"
seal secret-macho
inspect secret-macho 40
only_failed "I7 no secrets in any file"

# --- I8, AT-REV-4 ---------------------------------------------------------------------
app="$(variant jsc)"
compile "$app/Hasala" "$work/main.c" -framework JavaScriptCore
seal jsc
inspect jsc 40
only_failed "I8 no JavaScriptCore"

app="$(variant mocks)"
printf 'const char *const persona = "%s";\nint main(void) { return persona[0] == 0; }\n' "HasalaMocks.Maya Rahman" >"$work/mocks.c"
compile "$app/Hasala" "$work/mocks.c"
seal mocks
inspect mocks 40
only_failed "AT-REV-4 no mock data (HasalaMocks) in any file"

app="$(variant mocks-resource)"
printf '{"persona": "%s"}\n' "Maya Rahman" >"$app/persona.json"
seal mocks-resource
inspect mocks-resource 40
only_failed "AT-REV-4 no mock data (HasalaMocks) in any file"

# The Debug launch hook's arguments (-HasalaScreen, -HasalaMotion) are mock code too.
app="$(variant screen-hook)"
printf 'const char *const hook = "%s";\nint main(void) { return hook[0] == 0; }\n' "-HasalaScreen" >"$work/hook.c"
compile "$app/Hasala" "$work/hook.c"
seal screen-hook
inspect screen-hook 40
only_failed "AT-REV-4 no mock data (HasalaMocks) in any file"

app="$(variant motion-hook)"
printf '{"launch": "%s"}\n' "-HasalaMotion off" >"$app/motion.json"
seal motion-hook
inspect motion-hook 40
only_failed "AT-REV-4 no mock data (HasalaMocks) in any file"

# The hook as the app writes it, in Swift: "-HasalaScreen" inline is 13 bytes, which the
# optimiser keeps inside instructions, so no byte search sees it. The mock-only type it
# sits in is what AT-REV-4 finds.
app="$(variant swift-hook)"
cat >"$work/hook.swift" <<'SWIFT'
enum ScreenLaunch {
  static func isMockLaunch(_ arguments: [String]) -> Bool { arguments.contains("-HasalaScreen") }
}
if ScreenLaunch.isMockLaunch(CommandLine.arguments) { print("mock") }
SWIFT
compile_swift "$app/Hasala" "$work/hook.swift"
if hasala_absent 'HasalaScreen' "$app/Hasala"; then
	echo "ok   (swiftc keeps the inline -HasalaScreen out of the binary's bytes)"
else
	echo "note swiftc stored the inline -HasalaScreen as bytes this time"
fi
seal swift-hook
inspect swift-hook 40
only_failed "AT-REV-4 no mock data (HasalaMocks) in any file"

# --- I3, I4: Info.plist against archive.sh's expectations ----------------------------------
variant marketing >/dev/null
seal marketing
inspect marketing 40 9.9.9
only_failed "I3 CFBundleShortVersionString is 9.9.9"
inspect marketing 40 "$marketing" true
only_failed "I4 ITSAppUsesNonExemptEncryption is true"

app="$(variant urltypes)"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$app/Info.plist" >/dev/null
seal urltypes
inspect urltypes 40
only_failed "I4 no CFBundleURLTypes"

# --- I5: the privacy manifest ------------------------------------------------------------
app="$(variant privacy-four)"
/usr/libexec/PlistBuddy -c "Print :NSPrivacyCollectedDataTypes:4:NSPrivacyCollectedDataType" "$app/PrivacyInfo.xcprivacy" >"$work/fifth"
/usr/libexec/PlistBuddy -c "Delete :NSPrivacyCollectedDataTypes:4" "$app/PrivacyInfo.xcprivacy"
seal privacy-four
inspect privacy-four 40
only_failed "I5 PrivacyInfo.xcprivacy valid"
echo "     (removed $(cat "$work/fifth"))"

app="$(variant privacy-missing)"
rm "$app/PrivacyInfo.xcprivacy"
seal privacy-missing
inspect privacy-missing 40
only_failed "I5 PrivacyInfo.xcprivacy valid"

# --- I1w, I3w, I5w: the widget extension ------------------------------------------------
app="$(variant widget-ents)"
cp "$appex_golden" "$work/widget-ents-golden.plist"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string 8CFG28JHP3.app.hasala.shared" \
	"$work/widget-ents-golden.plist" >/dev/null
/usr/bin/codesign -s - -f --entitlements "$work/widget-ents-golden.plist" "$app/PlugIns/HasalaWidgets.appex" 2>/dev/null
seal widget-ents
inspect widget-ents 40
only_failed "I1w widget extension entitlements equal golden/widgets.release.entitlements.plist"

app="$(variant widget-version)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" "$app/PlugIns/HasalaWidgets.appex/Info.plist"
/usr/bin/codesign -s - -f --entitlements "$appex_golden" "$app/PlugIns/HasalaWidgets.appex" 2>/dev/null
seal widget-version
inspect widget-version 40
only_failed "I3w widget extension is app.hasala.ios.widgets"

app="$(variant widget-tracking)"
/usr/libexec/PlistBuddy -c "Set :NSPrivacyTracking true" "$app/PlugIns/HasalaWidgets.appex/PrivacyInfo.xcprivacy"
/usr/bin/codesign -s - -f --entitlements "$appex_golden" "$app/PlugIns/HasalaWidgets.appex" 2>/dev/null
seal widget-tracking
inspect widget-tracking 40
only_failed "I5w widget extension PrivacyInfo.xcprivacy valid"

app="$(variant widget-missing)"
rm -rf "$app/PlugIns"
seal widget-missing
inspect widget-missing 40
only_failed "I1w widget extension entitlements" "I3w widget extension" "I5w widget extension"

# --- I6 ----------------------------------------------------------------------------------
app="$(variant mail)"
echo "From: nobody" >"$app/sample.eml"
seal mail
inspect mail 40
only_failed "I6 no mail, fixtures, databases or keys" "I6b sample seed is golden/maya-v1.sha256"

# --- I6b: the sample seed and the bundle's content (check-bundle.sh) ------------------------
seed="HasalaCore_CoreResources.bundle/sample/maya-v1.json"
app="$(variant seed-missing)"
rm "$app/$seed"
seal seed-missing
inspect seed-missing 40
only_failed "I6b sample seed is golden/maya-v1.sha256"

app="$(variant seed-changed)"
printf ' ' >>"$app/$seed"
seal seed-changed
inspect seed-changed 40
only_failed "I6b sample seed is golden/maya-v1.sha256"
grep -q 'not golden/maya-v1.sha256' "$work/out" && echo "ok   ...and says the hash differs" || {
	echo "FAIL ...the output does not say the seed's hash differs"
	fail=1
}

# A seed with a real-looking address and a Gmail message id: not synthetic.
app="$(variant seed-real)"
printf '{"format":"hasala.sample","ops":[{"payload":{"message_id":"18c2f3a4b5d6e7f8","from":"%s@%s"}}]}\n' \
	someone example.com >"$app/$seed"
seal seed-real
inspect seed-real 40
only_failed "I6b sample seed is golden/maya-v1.sha256"
for why in "an email address" "is not a placeholder" "looks like a Gmail message id"; do
	grep -q "$why" "$work/out" && echo "ok   ...says: $why" || {
		echo "FAIL ...the output does not say '$why'"
		sed 's/^/     /' "$work/out"
		fail=1
	}
done

# A resource over 5 MB that is not code, a font or the merchant dictionary.
app="$(variant large-resource)"
head -c 5000001 /dev/zero >"$app/big.bin"
seal large-resource
inspect large-resource 40
only_failed "I6b sample seed is golden/maya-v1.sha256"

# A conformance directory: I6 and I6b both refuse it.
app="$(variant conformance)"
mkdir -p "$app/conformance"
echo '{}' >"$app/conformance/case.json"
seal conformance
inspect conformance 40
only_failed "I6 no mail, fixtures, databases or keys" "I6b sample seed is golden/maya-v1.sha256"

# --- I9: third-party crypto symbols, exported or imported, in any Mach-O ----------------------
# Exported by the main binary.
app="$(variant crypto-export)"
printf 'int crypto_box_keypair(void) { return 0; }\nint main(void) { return crypto_box_keypair(); }\n' >"$work/export.c"
compile "$app/Hasala" "$work/export.c" -Wl,-exported_symbol,_crypto_box_keypair -Wl,-exported_symbol,_main
seal crypto-export
inspect crypto-export 40
only_failed "I9 no third-party crypto symbols"

# Imported by the main binary from a library the payload doesn't even carry.
app="$(variant crypto-import)"
mkdir -p "$work/libevp"
printf 'int EVP_EncryptInit(void) { return 0; }\n' >"$work/libevp/evp.c"
compile "$work/libevp/libevp.dylib" "$work/libevp/evp.c" -dynamiclib -install_name @rpath/libevp.dylib
printf 'int EVP_EncryptInit(void);\nint main(void) { return EVP_EncryptInit(); }\n' >"$work/import.c"
compile "$app/Hasala" "$work/import.c" -L"$work/libevp" -levp
seal crypto-import
inspect crypto-import 40
only_failed "I9 no third-party crypto symbols"

# Exported by a library in Frameworks/.
app="$(variant crypto-dylib)"
mkdir -p "$app/Frameworks"
printf 'int argon2id_hash_raw(void) { return 0; }\n' >"$work/argon.c"
compile "$app/Frameworks/libargon2.dylib" "$work/argon.c" -dynamiclib -install_name @rpath/libargon2.dylib
seal crypto-dylib
inspect crypto-dylib 40
only_failed "I9 no third-party crypto symbols"
grep -q 'Frameworks/libargon2.dylib' "$work/out" && echo "ok   ...and names the library" || {
	echo "FAIL ...the output does not name Frameworks/libargon2.dylib"
	sed 's/^/     /' "$work/out"
	fail=1
}

# --- I1: entitlements ------------------------------------------------------------------------
variant unsigned >/dev/null
seal unsigned unsigned
inspect unsigned 40
failed "I1 aps-environment is production"
failed "I1 no ?mode=developer domain"
failed "I1 entitlements equal golden"

app="$(variant devmode)"
cp "$golden" "$work/devmode.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.associated-domains:0 string webcredentials:hasala.app?mode=developer" "$work/devmode.plist"
seal devmode "$work/devmode.plist"
inspect devmode 40
failed "I1 no ?mode=developer domain"

# --- not an .ipa at all ----------------------------------------------------------------------
echo "not a zip" >"$work/broken.ipa"
inspect broken 40
failed "the .ipa can be hashed and unzipped"

# --- an .ipa whose every entry is mode 000 ---------------------------------------------------
# The good app with every file and directory stored as mode 000, which unzip restores.
# Every check that reads the app fails (40), and the inspection's temporary directory,
# made under TMPDIR, is removed all the same.
/usr/bin/python3 -I - "$work/good.ipa" "$work/mode000.ipa" <<'PY2'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as src, zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as dst:
    for i in src.infolist():
        o = zipfile.ZipInfo(i.filename, i.date_time)
        o.create_system = 3
        o.external_attr = (0o040000 << 16) | 0x10 if i.is_dir() else 0o100000 << 16
        dst.writestr(o, src.read(i), zipfile.ZIP_DEFLATED)
PY2
mkdir "$work/tmp"
rc=0
TMPDIR="$work/tmp" "$here/inspect-ipa.sh" "$work/mode000.ipa" "$build" "$marketing" "$commit" false >"$work/out" 2>&1 || rc=$?
if [[ "$rc" == 40 ]]; then echo "ok   mode000 (exit $rc)"; else
	echo "FAIL mode000: exit $rc, want 40"
	sed 's/^/     /' "$work/out"
	fail=1
fi
failed "I3 CFBundleVersion is $build"
failed "I12 no dev hosts in any file"
left="$(ls -A "$work/tmp")"
if [[ -z "$left" ]]; then echo "ok   ...and it left nothing in TMPDIR"; else
	echo "FAIL the inspection of mode000 left $left in TMPDIR"
	fail=1
fi

if "$here/inspect-ipa.sh" "$work/good.ipa" "$build" "$marketing" "$commit" >/dev/null 2>&1; then
	echo "FAIL inspect-ipa.sh ran without the encryption argument"
	fail=1
else
	echo "ok   inspect-ipa.sh refuses to run without every expectation"
fi
exit "$fail"
