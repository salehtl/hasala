#!/usr/bin/env bash
# privacy-lint.sh: the spec 06 §5.4 lint of required-reason API use against the app's
# privacy manifest, run before archiving (Apple rejects an upload that uses one of these
# APIs without declaring it: ITMS-91053).
#
#   ios/scripts/privacy-lint.sh
#
# It greps the Swift sources linked into the app (ios/Hasala, and the HasalaCore and
# HasalaKit products the app links; not the Debug-only HasalaMocks, CoreTestSupport or
# CoreSoftAuth) for each category's trigger symbols, and reads the categories that
# ios/Hasala/PrivacyInfo.xcprivacy declares:
#
#   - a hit in a category the manifest doesn't declare fails the lint;
#   - a declared category with no hit is a warning (use through a wrapper can be indirect);
#   - ActiveKeyboards must have no hit at all.
#
# Lines that are only a comment are not counted. GRDB ships its own manifest (spec 06 §5.3)
# and is not scanned. Exit 0 when clean, 1 on a failure, 2 when it cannot run. Output is one
# line per category ("  ok", "  warn", "  FAIL"), then "PASS" or "FAIL".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
manifest="$ios/Hasala/PrivacyInfo.xcprivacy"
roots=("$ios/Hasala" "$ios/HasalaCore/Sources" "$ios/HasalaKit/Sources")
# Built into test or Debug products only, never into the Release app.
excluded=(HasalaMocks TestSupport SoftAuth)

[[ $# == 0 ]] || {
	echo "usage: privacy-lint.sh" >&2
	exit 2
}
[[ -f "$manifest" ]] || {
	echo "privacy-lint: $manifest is missing" >&2
	exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/hasala-privacy-lint.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The declared categories, from the manifest as XML (it may be stored binary).
if ! /usr/bin/plutil -convert xml1 -o "$work/manifest.xml" "$manifest" >/dev/null 2>&1; then
	echo "privacy-lint: $manifest is not a property list" >&2
	exit 2
fi
grep -oE 'NSPrivacyAccessedAPICategory[A-Za-z]+' "$work/manifest.xml" >"$work/declared.txt" || true

# The sources: every .swift file under the roots, outside the excluded directories.
for root in "${roots[@]}"; do
	[[ -d "$root" ]] || {
		echo "privacy-lint: $root is missing" >&2
		exit 2
	}
done
names=()
for d in "${excluded[@]}"; do names+=(-o -name "$d"); done
find "${roots[@]}" \( -type d \( -false "${names[@]}" \) -prune \) -o \( -type f -name '*.swift' -print \) \
	>"$work/files.txt"
[[ -s "$work/files.txt" ]] || {
	echo "privacy-lint: no Swift sources found" >&2
	exit 2
}

# Spec 06 §5.4's trigger symbols plus the rest of Apple's list for each category, as one
# extended regular expression per category. A bare call such as `stat(` must not be the
# end of a longer identifier (b), and a name such as `systemSize` not the start of one (e).
# getattrlist also covers fgetattrlist, getattrlistat and getattrlistbulk; the date
# patterns cover creationDate, fileCreationDate, (content|file)ModificationDate and their
# URLResourceKey and FileAttributeKey forms.
b='(^|[^A-Za-z0-9_])'
e='([^A-Za-z0-9_]|$)'
categories=(UserDefaults FileTimestamp SystemBootTime DiskSpace ActiveKeyboards)
triggers=(
	"UserDefaults|NSUserDefaults|@AppStorage|${b}AppStorage\\("
	"[cC]reationDate|[mM]odificationDate|attributesOfItem|getattrlist|${b}stat\\(|${b}fstat\\(|${b}fstatat\\(|${b}lstat\\("
	"systemUptime|mach_absolute_time"
	"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize${e}|systemSize${e}|NSFileSystemFreeSize|NSFileSystemSize${e}|getattrlist|${b}statfs\\(|${b}statvfs\\(|${b}fstatfs\\(|${b}fstatvfs\\("
	"activeInputModes"
)

failed=0
for i in "${!categories[@]}"; do
	c="${categories[$i]}"
	hits="$work/$c.txt"
	: >"$hits"
	while IFS= read -r f; do
		# file:line:text for each hit, then drop lines that are only a comment.
		grep -nE "${triggers[$i]}" "$f" | sed "s|^|${f#"$ios/"}:|" >>"$hits" || true
	done <"$work/files.txt"
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' "$hits" >"$hits.code" || true
	declared=0
	grep -qx "NSPrivacyAccessedAPICategory$c" "$work/declared.txt" && declared=1
	n="$(wc -l <"$hits.code" | tr -d ' ')"
	if [[ "$c" == ActiveKeyboards ]]; then
		if ((n > 0)); then
			echo "  FAIL  $c: must not be used ($n hits)"
			sed 's/^/        /' "$hits.code" | head -20
			failed=1
		else
			echo "  ok    $c: not used"
		fi
	elif ((n > 0 && declared == 0)); then
		echo "  FAIL  $c: used but not declared in PrivacyInfo.xcprivacy ($n hits)"
		sed 's/^/        /' "$hits.code" | head -20
		failed=1
	elif ((n > 0)); then
		echo "  ok    $c: declared, $n hits"
	elif ((declared == 1)); then
		echo "  warn  $c: declared, no direct hit (use may be through a wrapper)"
	else
		echo "  ok    $c: not used, not declared"
	fi
done

if ((failed)); then
	echo "FAIL"
	exit 1
fi
echo "PASS"
