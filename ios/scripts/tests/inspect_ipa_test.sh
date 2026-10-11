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
# files (grep -I), so a secret in the Mach-O or the binary Info.plist passed.
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
trap 'rm -rf "$work"' EXIT
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

# --- the template: an app that passes every check ------------------------------------
tpl="$work/template/Payload/Hasala.app"
mkdir -p "$tpl"
printf 'int main(void) { return 0; }\n' >"$work/main.c"
compile "$tpl/Hasala" "$work/main.c"
/usr/bin/xcrun actool --compile "$tpl" --platform iphoneos --minimum-deployment-target 26.0 \
	--app-icon AppIcon --output-partial-info-plist "$work/partial.plist" \
	"$ios/Hasala/Resources/Assets.xcassets" >"$work/actool.log" 2>&1
cp "$ios/Hasala/PrivacyInfo.xcprivacy" "$tpl/"
for kv in "CFBundleExecutable string Hasala" "CFBundleIdentifier string app.hasala.ios" \
	"CFBundleVersion string $build" "CFBundleShortVersionString string $marketing" \
	"HasalaGitCommit string $commit" "ITSAppUsesNonExemptEncryption bool false"; do
	/usr/libexec/PlistBuddy -c "Add :$kv" "$tpl/Info.plist" >/dev/null
done
/usr/bin/plutil -convert binary1 "$tpl/Info.plist"

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

# only_failed LABEL: as failed, and no other check failed.
only_failed() {
	failed "$1"
	local n
	n="$(grep -c '^  FAIL  ' "$work/out" || true)"
	if [[ "$n" == 1 ]]; then echo "ok   ...and nothing else failed"; else
		echo "FAIL $n checks failed, want only '$1'"
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
only_failed "I12 no dev hosts"

# --- I7: secrets in binary files ----------------------------------------------------------
app="$(variant secret-plist)"
/usr/bin/plutil -insert HasalaNote -string "GOC$(echo SPX)-synthetic-test-value" "$app/Info.plist"
/usr/bin/plutil -convert binary1 "$app/Info.plist"
seal secret-plist
inspect secret-plist 40
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
only_failed "AT-REV-4 no mock data (HasalaMocks)"

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

# --- I6 ----------------------------------------------------------------------------------
app="$(variant mail)"
echo "From: nobody" >"$app/sample.eml"
seal mail
inspect mail 40
only_failed "I6 no mail, fixtures, databases or keys"

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

if "$here/inspect-ipa.sh" "$work/good.ipa" "$build" "$marketing" "$commit" >/dev/null 2>&1; then
	echo "FAIL inspect-ipa.sh ran without the encryption argument"
	fail=1
else
	echo "ok   inspect-ipa.sh refuses to run without every expectation"
fi
exit "$fail"
