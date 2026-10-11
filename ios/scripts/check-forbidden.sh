#!/usr/bin/env bash
# check-forbidden.sh: the grep lints of spec 04 §2.4 over HasalaCore's sources
# (ios/HasalaCore/Sources/HasalaCore). Pure grep, so scripts/check.sh runs it on
# Linux and the CI `swift` job on macOS.
#
#   R2  byte-exact modules (JSON/, Time/, Wire/, Norm/, Template/Exec/, Mail/,
#       Categorize/Canon/, Replay/) never use JSONSerialization, JSONDecoder,
#       JSONEncoder, DateFormatter, ISO8601DateFormatter, Calendar, Regex,
#       `#/` regex literals, NSRegularExpression, Double, Float, Decimal,
#       lowercased(), uppercased(), trimmingCharacters or
#       components(separatedBy:).
#   R3  no `[String:` or `Set<` in Replay/ or Domain/Fold* (OrderedDictionary
#       and OrderedSet instead).
#   R7  no print, NSLog, debugPrint or dump (log through CoreLog).
#   R8  no Date(), Date.now, UUID() or SystemRandomNumberGenerator outside
#       Primitives/ and Time/.
#
# The escape is per file, reviewed: a line `// lint-allow: <name> <reason>`
# allows <name> (the token as named above, e.g. `Double`, `Date`, `print`) in
# that file. Lines whose first non-blank characters are `//` are not scanned.
#
# What grep cannot see stays with review (§2.4): bare `/.../` regex literals,
# `String <`, `String.contains`/`range(of:)` on content, and iteration over
# `Character`.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../HasalaCore/Sources/HasalaCore" && pwd)"
fail=0

# Word boundaries, spelled out (grep -w would also demand one AFTER `print(`).
B='(^|[^A-Za-z0-9_])'
E='([^A-Za-z0-9_]|$)'

# lint RULE NAME REGEX PATH...: REGEX (grep -E) must not appear in the .swift
# files under the Sources/HasalaCore-relative PATHs, unless the file carries
# `// lint-allow: NAME <reason>`. A PATH ending in `*` is a name prefix
# (Domain/Fold*).
lint() {
	local rule="$1" name="$2" re="$3"
	shift 3
	local p f hit file targets=()
	for p in "$@"; do
		if [[ "$p" == *"*" ]]; then
			while IFS= read -r f; do targets+=("$f"); done < <(cd "$SRC" && find "${p%/*}" -path "$p" 2>/dev/null)
		elif [[ -e "$SRC/$p" ]]; then
			targets+=("$p")
		fi
	done
	[[ ${#targets[@]} -gt 0 ]] || return 0
	while IFS= read -r hit; do
		[[ -n "$hit" ]] || continue
		file="${hit%%:*}"
		grep -qF "// lint-allow: $name " "$SRC/$file" && continue
		echo "check-forbidden: Sources/HasalaCore/$(echo "$hit" | cut -d: -f1-2): $rule forbids $name here (spec 04 §2.4)" >&2
		fail=1
	done < <(cd "$SRC" && grep -rnE --include='*.swift' -- "$re" "${targets[@]}" |
		sed "s|^\./||" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
}

BYTE_EXACT=(JSON Time Wire Norm Template/Exec Mail Categorize/Canon Replay)
for t in JSONSerialization JSONDecoder JSONEncoder DateFormatter ISO8601DateFormatter Calendar \
	Regex NSRegularExpression Double Float Decimal trimmingCharacters; do
	lint R2 "$t" "$B$t$E" "${BYTE_EXACT[@]}"
done
lint R2 'lowercased()' '\.lowercased\(\)' "${BYTE_EXACT[@]}"
lint R2 'uppercased()' '\.uppercased\(\)' "${BYTE_EXACT[@]}"
lint R2 'components(separatedBy:)' "${B}components\\(separatedBy:" "${BYTE_EXACT[@]}"
lint R2 'regex-literal' '#/' "${BYTE_EXACT[@]}"

lint R3 '[String:' '\[String:' Replay 'Domain/Fold*'
lint R3 'Set<' "${B}Set<" Replay 'Domain/Fold*'

for t in print NSLog debugPrint dump; do
	lint R7 "$t" "$B$t\\(" .
done

NOT_ADAPTERS=()
for d in "$SRC"/*/; do
	d="$(basename "$d")"
	[[ "$d" == Primitives || "$d" == Time ]] || NOT_ADAPTERS+=("$d")
done
lint R8 Date "${B}Date(\\(\\)|\\.now$E)" "${NOT_ADAPTERS[@]}"
lint R8 UUID "${B}UUID\\(\\)" "${NOT_ADAPTERS[@]}"
lint R8 SystemRandomNumberGenerator "${B}SystemRandomNumberGenerator$E" "${NOT_ADAPTERS[@]}"

if [[ "$fail" != 0 ]]; then
	echo "check-forbidden: FAILED" >&2
	exit 1
fi
echo "check-forbidden: ok (R2, R3, R7, R8 over Sources/HasalaCore)"
