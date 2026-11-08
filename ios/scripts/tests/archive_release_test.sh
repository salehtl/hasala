#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
mini="$work/mini"
mkdir -p "$work/home" "$work/stub" "$work/keys"
mkdir -p "$mini/ios/scripts" "$mini/ios/Config" "$mini/ios/Hasala" "$mini/ios/HasalaCore/Sources/HasalaCore/Wire" \
	"$mini/ios/HasalaKit/Sources/HasalaDesign"
cp "$here"/{archive.sh,asc-env.sh,release-common.sh,privacy-lint.sh,build_number.sh} "$mini/ios/scripts/"
mkdir -p "$mini/ios/scripts/golden" "$mini/ios/HasalaCore/Sources/HasalaCore/Resources/sample"
cp "$here/golden/maya-v1.sha256" "$mini/ios/scripts/golden/"
cp "$ios/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift" "$mini/ios/HasalaCore/Sources/HasalaCore/Resources/"
cp "$ios/HasalaCore/Sources/HasalaCore/Resources/sample/maya-v1.json" "$mini/ios/HasalaCore/Sources/HasalaCore/Resources/sample/"
cp "$ios"/Config/*.xcconfig "$mini/ios/Config/"
cp "$ios/Hasala/PrivacyInfo.xcprivacy" "$mini/ios/Hasala/"
echo 'struct App {}' >"$mini/ios/Hasala/App.swift"
echo 'enum Core {}' >"$mini/ios/HasalaCore/Sources/HasalaCore/Core.swift"
op_swift() {
	printf 'public enum SchemaVersion {\n  public static let current = %s\n  public static let author = %s\n}\n' "$1" "$1" >"$mini/ios/HasalaCore/Sources/HasalaCore/Wire/Op.swift"
}
op_swift 4
echo 'enum Design {}' >"$mini/ios/HasalaKit/Sources/HasalaDesign/Design.swift"
printf 'build/\n' >"$mini/ios/.gitignore"
git -C "$mini" init -q
git -C "$mini" checkout -q -b main
gitc() { git -C "$mini" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
git -C "$mini" add -A
gitc commit -q -m mini

cat >"$work/stub/xcodebuild" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$work/calls"
case "\$1" in
-version)
	echo "Xcode 27.0"
	echo "Build version 27A000"
	exit 0
	;;
archive)
	if [ -n "\${STUB_ARCHIVE_DOES:-}" ]; then sh -c "\$STUB_ARCHIVE_DOES"; fi
	exit 0
	;;
esac
exit 65
STUB
cat >"$work/stub/curl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$work/curl-calls"
if [ -e "$work/curl-fails" ]; then
	echo "curl stub: refusing" >&2
	exit 22
fi
cat "$work/meta"
STUB
chmod +x "$work/stub/xcodebuild" "$work/stub/curl"
meta() { printf '%s\n' "$1" >"$work/meta"; }
meta '{"rp_id":"hasala.app","min_ios_build":0,"op_version_ceiling":4,"log_generation":1}'
key="$work/keys/AuthKey_TESTKEY000.p8"
echo "not a key" >"$key"
chmod 600 "$key"

n=0
archive() {
	local name="$1" want="$2" rc=0
	shift 2
	n=$((n + 1))
	: >"$work/calls"
	: >"$work/curl-calls"
	env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH HOME="$work/home" HASALA_BUILD_DIR="$work/build-$n" HASALA_TEST_MODE=1 \
		PATH="$work/stub:$PATH" ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
		ASC_KEY_PATH="$key" STUB_ARCHIVE_DOES="${STUB_ARCHIVE_DOES:-}" "$mini/ios/scripts/archive.sh" "$@" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
said() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...says $1"; else
		echo "FAIL the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
exported() { grep -c '^-exportArchive ' "$work/calls" || true; }
expect_exports() {
	if [[ "$(exported)" == "$2" ]]; then echo "ok   ...$1"; else
		echo "FAIL $1: $(exported) export(s), want $2"
		fail=1
	fi
}
archives() { grep -c '^archive ' "$work/calls" || true; }
expect_no_archive() {
	if [[ "$(archives)" == 0 ]]; then echo "ok   ...nothing was built"; else
		echo "FAIL a refused gate reached xcodebuild archive"
		fail=1
	fi
}
commit_all() {
	git -C "$mini" add -A
	gitc commit -q -m "$1"
}
reset_tree() {
	git -C "$mini" checkout -q main
	git -C "$mini" reset -q --hard "$start"
	git -C "$mini" clean -qfd
}
start="$(git -C "$mini" rev-parse HEAD)"
commit_cmd="git -C '$mini' -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m later"

archive "a tree nobody touches reaches the export (the stub refuses it)" 31
expect_exports "the export ran" 1

STUB_ARCHIVE_DOES="echo 'struct Other {}' >'$mini/ios/Hasala/Other.swift'" archive "a new file while xcodebuild reads the tree" 10
said "changed while"
expect_exports "no export" 0
reset_tree

STUB_ARCHIVE_DOES="echo 'struct App2 {}' >'$mini/ios/Hasala/App.swift'" archive "an edited file while xcodebuild reads the tree" 10
expect_exports "no export" 0
reset_tree

STUB_ARCHIVE_DOES="$commit_cmd" archive "a new commit while xcodebuild reads the tree" 10
said "changed while"
expect_exports "no export" 0
reset_tree

STUB_ARCHIVE_DOES="git -C '$mini' checkout -q -b elsewhere" archive "another branch while xcodebuild reads the tree" 10
expect_exports "no export" 0
reset_tree
git -C "$mini" branch -q -D elsewhere

STUB_ARCHIVE_DOES="echo 'struct Other {}' >'$mini/ios/Hasala/Other.swift'" archive "--allow-dirty on a clean tree is a release, so a change still stops it" 10 --allow-dirty
expect_exports "no export" 0
reset_tree

echo 'struct Dirty {}' >"$mini/ios/Hasala/Dirty.swift"
STUB_ARCHIVE_DOES="echo 'struct Other {}' >'$mini/ios/Hasala/Other.swift'" archive "a local trial from a dirty tree is not stopped (upload refuses it anyway)" 31 --allow-dirty
expect_exports "the export ran" 1
reset_tree

archive "a deployed ceiling equal to the build's schema passes the gate" 31
if grep -qF 'https://api.hasala.app/api/v1/meta' "$work/curl-calls"; then echo "ok   ...it asked the release API"; else
	echo "FAIL archive.sh did not ask https://api.hasala.app/api/v1/meta"
	cat "$work/curl-calls"
	fail=1
fi

meta '{"op_version_ceiling":5}'
archive "a deployed ceiling above the build's schema passes the gate" 31

meta '{"op_version_ceiling":3}'
archive "a deployed ceiling below the build's schema" 13
said "raise OpVersionCeiling and deploy hasalad first"
expect_no_archive

meta '{"rp_id":"hasala.app"}'
archive "a server that does not report a ceiling" 13
said "cannot read op_version_ceiling"
expect_no_archive

meta '{"op_version_ceiling":"4"}'
archive "a ceiling that is not a number" 13
expect_no_archive

meta '{"op_version_ceiling":4}'
touch "$work/curl-fails"
archive "a server that does not answer" 13
said "cannot read op_version_ceiling"
expect_no_archive

echo 'struct Dirty {}' >"$mini/ios/Hasala/Dirty.swift"
archive "a local trial does not need the server" 31 --allow-dirty
if [[ ! -s "$work/curl-calls" ]]; then echo "ok   ...it did not call it"; else
	echo "FAIL a local trial called the server"
	fail=1
fi
reset_tree
rm "$work/curl-fails"

op_swift 5
commit_all "next schema"
start="$(git -C "$mini" rev-parse HEAD)"
archive "a build that writes the next schema before the ceiling is deployed" 13
said "this build writes op schema 5"
expect_no_archive
meta '{"op_version_ceiling":5}'
archive "...and once the ceiling is deployed" 31

printf 'public enum SchemaVersion {}\n' >"$mini/ios/HasalaCore/Sources/HasalaCore/Wire/Op.swift"
commit_all "no schema"
start="$(git -C "$mini" rev-parse HEAD)"
archive "a tree with no readable schema" 13
said "cannot read SchemaVersion.author"
expect_no_archive
exit "$fail"
