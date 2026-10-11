#!/usr/bin/env bash
# privacy-lint.sh (spec 06 §5.4) against synthetic trees: a used category must be
# declared, ActiveKeyboards must not be used, a declared category without a hit only
# warns, comments don't count, and the Debug-only and test-only sources are not scanned.
#
# Offline: each case copies privacy-lint.sh into a temporary ios/ tree whose Swift files
# and privacy manifest are written here.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# tree NAME CATEGORY...: a fresh ios/ tree whose manifest declares the given categories.
tree() {
	local t="$work/$1"
	shift
	mkdir -p "$t/scripts" "$t/Hasala" "$t/HasalaCore/Sources/HasalaCore/Store" \
		"$t/HasalaCore/Sources/HasalaCore/TestSupport" "$t/HasalaKit/Sources/HasalaMocks"
	cp "$here/privacy-lint.sh" "$t/scripts/"
	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo '<plist version="1.0"><dict><key>NSPrivacyAccessedAPITypes</key><array>'
		local c
		for c in "$@"; do
			echo "<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory$c</string></dict>"
		done
		echo '</array></dict></plist>'
	} >"$t/Hasala/PrivacyInfo.xcprivacy"
	echo 'struct App {}' >"$t/Hasala/App.swift"
	echo "$t"
}

# lint NAME WANT DIR: privacy-lint.sh in DIR exits WANT.
lint() {
	local rc=0
	"$3/scripts/privacy-lint.sh" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$2" ]]; then echo "ok   $1 (exit $rc)"; else
		echo "FAIL $1: exit $rc, want $2"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

t="$(tree declared UserDefaults FileTimestamp)"
echo 'let d = UserDefaults.standard' >"$t/Hasala/Prefs.swift"
echo 'let a = try FileManager.default.attributesOfItem(atPath: p)' >"$t/HasalaCore/Sources/HasalaCore/Store/F.swift"
lint "used and declared" 0 "$t"
grep -q 'warn' "$work/out" && {
	echo "FAIL ...warned with every category used"
	fail=1
}

t="$(tree undeclared FileTimestamp)"
echo 'let d = UserDefaults.standard' >"$t/Hasala/Prefs.swift"
lint "UserDefaults used but not declared" 1 "$t"
grep -q 'FAIL  UserDefaults' "$work/out" && echo "ok   ...names the category" || {
	echo "FAIL ...does not name UserDefaults"
	fail=1
}

t="$(tree core-undeclared UserDefaults)"
echo 'let s = statfs(path, &buf)' >"$t/HasalaCore/Sources/HasalaCore/Store/Disk.swift"
lint "DiskSpace used in HasalaCore but not declared" 1 "$t"

t="$(tree keyboards UserDefaults)"
echo 'let m = UITextInputMode.activeInputModes' >"$t/Hasala/Keys.swift"
lint "ActiveKeyboards used" 1 "$t"

t="$(tree warn SystemBootTime)"
lint "declared but not used only warns" 0 "$t"
grep -q 'warn  SystemBootTime' "$work/out" && echo "ok   ...and says so" || {
	echo "FAIL ...no warning for SystemBootTime"
	fail=1
}

t="$(tree comment)"
printf '  // never in UserDefaults\n  /// the creationDate of nothing\n' >"$t/Hasala/Notes.swift"
lint "a comment is not a use" 0 "$t"

t="$(tree identifier)"
echo 'let x = lastStat(1) + fstatus(2)' >"$t/Hasala/Stat.swift"
lint "an identifier ending in stat( is not stat(" 0 "$t"
echo 'let r = stat(path, &buf)' >"$t/Hasala/Stat.swift"
lint "...but stat( itself is FileTimestamp" 1 "$t"

t="$(tree excluded)"
echo 'let d = UserDefaults.standard; let m = UITextInputMode.activeInputModes' >"$t/HasalaKit/Sources/HasalaMocks/M.swift"
echo 'let d = UserDefaults.standard' >"$t/HasalaCore/Sources/HasalaCore/TestSupport/T.swift"
lint "HasalaMocks and TestSupport are not scanned" 0 "$t"

t="$(tree missing-manifest)"
rm "$t/Hasala/PrivacyInfo.xcprivacy"
lint "no manifest" 2 "$t"

t="$(tree extra-argument)"
rc=0
"$t/scripts/privacy-lint.sh" extra >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then echo "ok   an extra argument (exit 2)"; else
	echo "FAIL an extra argument: exit $rc, want 2"
	fail=1
fi

exit "$fail"
