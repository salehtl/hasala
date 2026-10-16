#!/usr/bin/env bash
# check-bundle.sh (spec 04 §1's bundle content check, spec 06 I6b) against synthetic
# apps: a minimal Hasala.app carrying the committed sample seed passes, as an .app, an
# .xcarchive and an .ipa; each case below breaks one rule and must fail. Code, fonts and
# the merchant dictionary may be larger than 5 MB; nothing else may.
#
# Offline: the apps are directories and zip files made here. The golden-against-manifest
# case copies the scripts into a temporary ios/ tree whose SampleManifest.swift differs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
seed="HasalaCore_CoreResources.bundle/sample/maya-v1.json"

# app NAME: a fresh minimal Hasala.app that passes; prints its path.
app() {
	local a="$work/$1/Hasala.app"
	rm -rf "${work:?}/$1"
	mkdir -p "$a/HasalaCore_CoreResources.bundle/sample"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' >"$a/Info.plist"
	printf '\317\372\355\376' >"$a/Hasala"
	cp "$ios/HasalaCore/Sources/HasalaCore/Resources/sample/maya-v1.json" "$a/$seed"
	echo "$a"
}
# check NAME WANT TARGET [SCRIPT]: check-bundle.sh (or SCRIPT) on TARGET exits WANT.
check() {
	local rc=0
	"${4:-$here/check-bundle.sh}" "$3" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$2" ]]; then echo "ok   $1 (exit $rc)"; else
		echo "FAIL $1: exit $rc, want $2"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
# said TEXT: the last run's output says TEXT.
said() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...says: $1"; else
		echo "FAIL ...the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
big() { head -c 5000001 /dev/zero >"$1"; }

a="$(app good)"
check "the committed seed, nothing else" 0 "$a"
check "...given with a trailing slash" 0 "$a/"
mkdir -p "$work/good.xcarchive/Products/Applications"
cp -R "$a" "$work/good.xcarchive/Products/Applications/"
check "...inside an .xcarchive" 0 "$work/good.xcarchive"
mkdir -p "$work/ipa/Payload"
cp -R "$a" "$work/ipa/Payload/"
(cd "$work/ipa" && zip -qry "$work/good.ipa" Payload)
check "...inside an .ipa" 0 "$work/good.ipa"

# Large files: code, fonts and the merchant dictionary may be; a resource may not.
a="$(app large-allowed)"
{
	printf '\317\372\355\376'
	head -c 5000001 /dev/zero
} >"$a/Hasala"
big "$a/Font.ttf"
big "$a/HasalaCore_CoreResources.bundle/merchant-dictionary.json"
check "a large Mach-O, font and merchant dictionary" 0 "$a"
big "$a/HasalaCore_CoreResources.bundle/templates.json"
check "a large resource" 1 "$a"
said "templates.json is larger than 5 MB"
a="$(app at-limit)"
head -c 5000000 /dev/zero >"$a/exactly.bin"
check "a resource of exactly 5,000,000 bytes" 0 "$a"

# Test and private data.
for f in "conformance/ops.json" "Resources/conformance" "a.EML" "corpus-2026.jsonl" "manifest.synthetic.json"; do
	a="$(app "data-${f//\//-}")"
	mkdir -p "$(dirname "$a/$f")"
	echo '{}' >"$a/$f"
	check "test data: $f" 1 "$a"
done

# Outlook message ids, default and immutable, anywhere in the bundle. Built here (44
# synthetic characters) so the shapes are never written out whole in this repository.
tail44="$(printf 'x%.0s' {1..44})"
for prefix in AAMkAD AQMkAD AAkALgAA; do
	a="$(app "outlook-$prefix")"
	printf '{"id":"%s%s"}\n' "$prefix" "$tail44" >"$a/HasalaCore_CoreResources.bundle/cached.json"
	check "an Outlook message id ($prefix…) in a resource" 1 "$a"
	said "shaped like an Outlook message id"
done
a="$(app outlook-short)"
printf 'AAkALgAA-synthetic-1 AAMkAD-short\n' >"$a/notes.txt"
check "short id-like test strings are not ids" 0 "$a"
a="$(app seed-outlook)"
printf '{"format":"hasala.sample","ops":[{"payload":{"message_id":"sample-1","ref":"AAkALgAA%s"}}]}\n' "$tail44" >"$a/$seed"
check "a seed holding an Outlook message id" 1 "$a"
said "ref looks like an Outlook message id"

# The seed.
a="$(app seed-missing)"
rm "$a/$seed"
check "no sample seed" 1 "$a"
said "is missing"
a="$(app seed-changed)"
printf '\n' >>"$a/$seed"
check "a changed sample seed" 1 "$a"
said "not golden/maya-v1.sha256's"
a="$(app seed-email)"
printf '{"format":"hasala.sample","ops":[{"payload":{"to":"%s@%s","message_id":"sample-1"}}]}\n' someone example.com >"$a/$seed"
check "a seed with an email address" 1 "$a"
said "an email address in to"
a="$(app seed-review)"
printf '{"format":"hasala.sample","ops":[{"payload":{"to":"review@hasala.app","message_id":"@message:x"}}]}\n' >"$a/$seed"
"$here/check-bundle.sh" "$a" >"$work/out" 2>&1 || true
if grep -qE 'email address|placeholder|Gmail' "$work/out"; then
	echo "FAIL review@hasala.app and an @message: placeholder were counted as real data"
	sed 's/^/     /' "$work/out"
	fail=1
else
	echo "ok   review@hasala.app and an @message: placeholder are synthetic (only the hash differs)"
fi
a="$(app seed-not-json)"
echo 'not json' >"$a/$seed"
check "a seed that isn't JSON" 1 "$a"
said "not JSON"

# The golden hash must be the generator's (SampleManifest.sha256).
t="$work/tree"
mkdir -p "$t/scripts/golden" "$t/HasalaCore/Sources/HasalaCore/Resources"
cp "$here/check-bundle.sh" "$here/release-common.sh" "$t/scripts/"
cp "$here/golden/maya-v1.sha256" "$t/scripts/golden/"
sed 's/let sha256 = "[0-9a-f]*"/let sha256 = "'"$(printf '0%.0s' {1..64})"'"/' \
	"$ios/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift" >"$t/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift"
check "golden/maya-v1.sha256 is not SampleManifest.sha256" 1 "$(app tree-app)" "$t/scripts/check-bundle.sh"
said "is not SampleManifest.sha256"
rm "$t/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift"
check "no SampleManifest.swift" 1 "$(app tree-app2)" "$t/scripts/check-bundle.sh"
said "cannot read SampleManifest.sha256"

# Arguments.
rc=0
"$here/check-bundle.sh" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then echo "ok   no argument (exit 2)"; else
	echo "FAIL no argument: exit $rc, want 2"
	fail=1
fi
check "an empty argument" 2 ""
check "not an app" 2 "$work/none.txt"
mkdir -p "$work/empty.app"
check "an .app without Info.plist" 1 "$work/empty.app"
exit "$fail"
