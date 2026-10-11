#!/usr/bin/env bash
# upload.sh refuses, before it reads a key or touches the network, any .ipa that is
# not archive.sh's own export for its build, whose inspection did not pass for that
# very file, or that is a local trial, and any build number that is not newer than the
# last upload; and it records the build number before the upload starts (spec 06
# §10.3–§10.4).
#
# Offline. The builds are fake .ipa files under HASALA_BUILD_DIR in a temporary
# directory, so the real ios/build (and its last-build-number) is never read or
# written; HOME is an empty temporary directory. The cases that get past the key
# check use a fake key file and a stub `xcrun` first on PATH that records its
# arguments and never runs altool; DEVELOPER_DIR points nowhere, so the real xcrun
# could not run altool either.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release-common.sh
source "$here/release-common.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
root="$work/build"
mkdir -p "$root" "$work/home" "$work/stub" "$work/keys"

# The stub only stands in for altool if upload.sh reaches it through PATH.
if grep -nE '/usr/bin/xcrun|/altool' "$here/upload.sh"; then
	echo "FAIL upload.sh calls xcrun or altool by path; the stub cannot replace it, so this test stops here"
	exit 1
fi
cat >"$work/stub/xcrun" <<STUB
#!/bin/sh
# upload_precheck_test.sh's xcrun: records the call; never runs altool.
printf '%s\n' "\$*" >>"$work/calls"
[ "\$1" = altool ] || exit 64
case "\$2" in
--validate-app)
	echo '{"stub": "validate"}'
	exit "\${STUB_VALIDATE_RC:-0}"
	;;
--upload-package)
	cat "\$HASALA_BUILD_DIR/last-build-number" >"$work/recorded-at-upload" 2>/dev/null || echo none >"$work/recorded-at-upload"
	echo '{"stub": "upload"}'
	exit "\${STUB_UPLOAD_RC:-1}"
	;;
esac
exit 64
STUB
chmod +x "$work/stub/xcrun"
key="$work/keys/AuthKey_TESTKEY000.p8"
echo "not a key" >"$key"
chmod 600 "$key"
issuer=00000000-0000-0000-0000-000000000000

# make_build BUILD: a fake $root/BUILD/export/Hasala.ipa.
make_build() {
	local dir="$root/$1"
	mkdir -p "$dir/export" "$dir/stage/Payload/Hasala.app"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" "$dir/stage/Payload/Hasala.app/Info.plist" >/dev/null
	(cd "$dir/stage" && zip -qr "$dir/export/Hasala.ipa" Payload)
	rm -rf "$dir/stage"
}
# summary BUILD KIND: writes $root/BUILD/summary.txt as inspect-ipa.sh would, or cut
# short or tampered with.
summary() {
	local build="$1" kind="$2" s="$root/$1/summary.txt" sha
	sha="$(hasala_sha256 "$root/$build/export/Hasala.ipa")"
	{
		case "$kind" in
		other-build) echo "Hasala 991231.10000 (0123456789ab)" ;;
		*) echo "Hasala $build (0123456789ab)" ;;
		esac
		[[ "$kind" == header-only ]] && return
		echo "  ok    I3 CFBundleVersion is $build"
		echo "  ok    I4 no CFBundleURLTypes"
		[[ "$kind" == fail-line ]] && echo "  FAIL  I1 entitlements equal golden/app.release.entitlements.plist"
		echo "ipa: $root/$build/export/Hasala.ipa (1 bytes)"
		case "$kind" in
		pass | other-build) echo "PASS 2/2 sha256=$sha" ;;
		fail-line) echo "PASS 3/3 sha256=$sha" ;;
		wrong-hash) echo "PASS 2/2 sha256=$(printf '%064d' 0)" ;;
		wrong-count) echo "PASS 3/3 sha256=$sha" ;;
		no-pass-line) ;;
		pass-not-last) printf 'PASS 2/2 sha256=%s\nlocal trial, not for upload: dirty tree\n' "$sha" ;;
		esac
	} >"$s"
}
# upload NAME WANT [VAR=value...] -- ARG...: runs upload.sh ARG... with HOME empty,
# no ASC_* variables, HASALA_BUILD_DIR=$root, the stub xcrun first on PATH and
# DEVELOPER_DIR nowhere, plus the given variables; WANT is the exit code it must give.
upload() {
	local name="$1" want="$2" rc=0
	shift 2
	local vars=(HOME="$work/home" HASALA_BUILD_DIR="$root" PATH="$work/stub:$PATH" DEVELOPER_DIR="$work/no-xcode")
	while [[ "$1" != "--" ]]; do
		vars+=("$1")
		shift
	done
	shift
	env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH "${vars[@]}" "$here/upload.sh" "$@" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
said() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...$2"; else
		echo "FAIL $2: the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
equal() {
	if [[ "$1" == "$2" ]]; then echo "ok   $3"; else
		echo "FAIL $3: got '$1', want '$2'"
		fail=1
	fi
}

b=991231.12357
ipa="$root/$b/export/Hasala.ipa"
make_build "$b"
upload "no summary.txt" 40 -- "$ipa"

summary "$b" other-build
upload "summary.txt for another build" 40 -- "$ipa"
summary "$b" fail-line
upload "summary.txt with a FAIL" 40 -- "$ipa"
summary "$b" header-only
upload "summary.txt cut short after its header" 40 -- "$ipa"
said "does not end in the PASS line" "refused for the missing PASS line"
summary "$b" no-pass-line
upload "summary.txt with every check but no PASS line" 40 -- "$ipa"
summary "$b" pass-not-last
upload "summary.txt whose PASS line is not the last" 40 -- "$ipa"
summary "$b" wrong-hash
upload "summary.txt whose PASS line has another sha256" 40 -- "$ipa"
said "is not the file that was inspected" "refused for the sha256"
summary "$b" wrong-count
upload "summary.txt whose PASS count is not its ok lines" 40 -- "$ipa"

summary "$b" pass
mkdir -p "$work/elsewhere/$b/export"
cp "$ipa" "$work/elsewhere/$b/export/Hasala.ipa"
cp "$root/$b/summary.txt" "$work/elsewhere/$b/summary.txt"
upload "an inspected .ipa copied out of the build directory" 40 -- "$work/elsewhere/$b/export/Hasala.ipa"
said "only the .ipa that archive.sh exported and inspected" "refused for where it is"

cp "$ipa" "$work/ipa.orig"
printf 'x' >>"$ipa"
upload "an .ipa changed after its inspection" 40 -- "$ipa"
cp "$work/ipa.orig" "$ipa"

echo "local trial, not for upload: dirty tree" >"$root/$b/TRIAL"
upload "a local trial" 40 -- "$ipa"
rm "$root/$b/TRIAL"

# Build numbers (21): the .ipa's must be newer than ios/build/last-build-number.
echo "$b" >"$root/last-build-number"
upload "a build equal to the last upload" 21 -- "$ipa"
echo 991231.12358 >"$root/last-build-number"
upload "a build older than the last upload" 21 -- "$ipa"
echo 991231.12356 >"$root/last-build-number"
upload "a clean, inspected, newer build reaches the key check" 14 -- "$ipa"

# The key (14). asc.env is sourced as shell, so a group- or world-readable one is refused.
mkdir -p "$work/home/.config/hasala"
printf 'ASC_KEY_ID=TESTKEY000\nASC_ISSUER_ID=%s\n' "$issuer" >"$work/home/.config/hasala/asc.env"
chmod 644 "$work/home/.config/hasala/asc.env"
upload "an asc.env with mode 0644" 14 -- "$ipa"
said "must be yours with mode 0600" "refused for its mode"
upload "a key file not named AuthKey_<ASC_KEY_ID>.p8" 14 ASC_KEY_ID=OTHERKEY00 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key" -- "$ipa"
said "is not named AuthKey_OTHERKEY00.p8" "refused for its name"

# Past the key: the stub altool. An asc.env with mode 0600 and the key at its
# default path under HOME (this is the case GNU stat used to break).
chmod 600 "$work/home/.config/hasala/asc.env"
mkdir -p "$work/home/.appstoreconnect/private_keys"
cp "$key" "$work/home/.appstoreconnect/private_keys/"
chmod 600 "$work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8"
: >"$work/calls"
upload "an asc.env with mode 0600 and the key: validation only" 0 -- "$ipa"
equal "$(cat "$work/calls")" "altool --validate-app $ipa --api-key TESTKEY000 --api-issuer $issuer --p8-file-path $work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8 --output-format json" \
	"...altool --validate-app <ipa> --api-key --api-issuer --p8-file-path"
equal "$(cat "$root/last-build-number")" 991231.12356 "...a validation records no build number"

upload "validation fails" 50 STUB_VALIDATE_RC=1 -- "$ipa" --yes
equal "$(cat "$root/last-build-number")" 991231.12356 "...a failed validation records no build number"

: >"$work/calls"
upload "the upload fails" 60 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key" STUB_UPLOAD_RC=1 -- "$ipa" --yes
equal "$(cat "$work/recorded-at-upload")" "$b" "...the build number was recorded before the upload started"
equal "$(cat "$root/last-build-number")" "$b" "...and stays recorded after the upload failed"
equal "$(sed -n 2p "$work/calls")" "altool --upload-package $ipa --api-key TESTKEY000 --api-issuer $issuer --p8-file-path $key --wait --output-format json" \
	"...altool --upload-package <ipa> --api-key --api-issuer --p8-file-path --wait"
upload "the same build again after a failed upload" 21 -- "$ipa" --yes

b2=991231.12358
make_build "$b2"
summary "$b2" pass
upload "a newer build uploads" 0 STUB_UPLOAD_RC=0 -- "$root/$b2/export/Hasala.ipa" --yes
equal "$(cat "$root/last-build-number")" "$b2" "...and is recorded"

upload "an extra argument" 2 -- "$ipa" --yes --force
exit "$fail"
