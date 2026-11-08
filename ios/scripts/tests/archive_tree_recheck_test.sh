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
cp "$ios"/Config/*.xcconfig "$mini/ios/Config/"
cp "$ios/Hasala/PrivacyInfo.xcprivacy" "$mini/ios/Hasala/"
echo 'struct App {}' >"$mini/ios/Hasala/App.swift"
echo 'enum Core {}' >"$mini/ios/HasalaCore/Sources/HasalaCore/Core.swift"
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
chmod +x "$work/stub/xcodebuild"
key="$work/keys/AuthKey_TESTKEY000.p8"
echo "not a key" >"$key"
chmod 600 "$key"

n=0
archive() {
	local name="$1" want="$2" rc=0
	shift 2
	n=$((n + 1))
	: >"$work/calls"
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
exit "$fail"
