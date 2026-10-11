#!/usr/bin/env bash
# check-imports.sh: HasalaCore's import rules (spec 04 §2.3 and §2.4 R1, R6) and
# spec 01 AT-C11's source scan. Pure grep/awk, so it runs anywhere bash does:
# scripts/check.sh runs it on Linux (with --no-manifest) and the CI `swift` job
# runs it on macOS with the manifest cross-check.
#
#   ios/scripts/check-imports.sh [--no-manifest]
#
# 1. Every `import` in ios/HasalaCore/Sources/HasalaCore/<dir>/ is listed for
#    <dir> (or `*`) in ios/HasalaCore/imports.allow. SwiftPM lets a target
#    import any module its dependencies link, transitively, so the compiler
#    alone would let `Sync/` import GRDB; this does not.
# 2. Whatever imports.allow says: GRDB only in Store and Projection (R6),
#    FoundationModels only in Model, CommonCrypto only in Primitives, and none
#    of the modules §2.3 bans from the core.
# 3. AT-C11: `AES.GCM`, `HKDF<`, `Curve25519.Signing` and `SecRandomCopyBytes`
#    only in Primitives/ and Crypto/; `CCKeyDerivationPBKDF` only in
#    Primitives/; `SecureEnclave.P256` only in ios/Hasala/Platform/ApprovalKey/.
#    Every .swift file under ios/ is scanned, tests included.
# 4. Unless --no-manifest, or `swift`/`jq` are missing: each directory's
#    package modules in imports.allow are exactly its target's declared
#    dependencies in Package.swift (`swift package describe`), so the allow
#    list can neither widen the target graph nor drift from it.
#
# Lines whose first non-blank characters are `//` are ignored (block comments
# are not understood: keep tokens out of them).
set -euo pipefail

IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$IOS/HasalaCore"
SRC="$CORE/Sources/HasalaCore"
ALLOW="$CORE/imports.allow"

MANIFEST=1
case "$*" in
"") ;;
--no-manifest) MANIFEST="" ;;
*)
	echo "usage: ios/scripts/check-imports.sh [--no-manifest]" >&2
	exit 2
	;;
esac

fail=0
problem() {
	echo "check-imports: $*" >&2
	fail=1
}

# imports.allow without comments and blank lines: "<dir> <module>...".
allow_lines() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ALLOW" | awk 'NF'; }

# --- the allow file covers exactly the source directories -----------------------
dirs="$(cd "$SRC" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | sort)"
listed="$(allow_lines | awk '$1 != "*" { print $1 }' | sort)"
dups="$(printf '%s\n' "$listed" | uniq -d)"
[[ -z "$dups" ]] || problem "imports.allow lists a directory twice: $(echo $dups)"
for d in $dirs; do
	printf '%s\n' "$listed" | grep -qx "$d" || problem "Sources/HasalaCore/$d/ has no line in imports.allow"
done
for d in $listed; do
	[[ -d "$SRC/$d" ]] || problem "imports.allow lists $d, which is not a directory under Sources/HasalaCore"
done

# --- hard rules on the allow file itself ------------------------------------------
# allowed_only MODULE DIR...: MODULE may be listed for these directories only.
BANNED="UIKit SwiftUI AuthenticationServices UserNotifications BackgroundTasks WidgetKit LocalAuthentication Network VisionKit AVFoundation FoundationNetworking"
hard_rule() { # dir module -> prints a reason when the pair is forbidden outright
	local dir="$1" mod="$2" b
	for b in $BANNED; do
		[[ "$mod" == "$b" ]] && {
			echo "$mod is never imported in HasalaCore (spec 04 §2.3)"
			return
		}
	done
	case "$mod" in
	GRDB) [[ "$dir" == Store || "$dir" == Projection ]] || echo "GRDB is for Store and Projection only (spec 04 §2.4 R6)" ;;
	FoundationModels) [[ "$dir" == Model ]] || echo "FoundationModels is for Model (HasalaModel) only (spec 04 §2.3)" ;;
	CommonCrypto) [[ "$dir" == Primitives ]] || echo "CommonCrypto is for Primitives (CorePrimitives) only (spec 04 §2.3)" ;;
	esac
}
while read -r dir mods; do
	for m in $mods; do
		why="$(hard_rule "$dir" "$m")"
		[[ -z "$why" ]] || problem "imports.allow: $dir lists $m: $why"
	done
done < <(allow_lines)

# --- every import is allowed --------------------------------------------------------
IMPORT_RE='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]'
star="$(allow_lines | awk '$1 == "*" { $1 = ""; print }')"
n_imports=0
while IFS= read -r hit; do
	[[ -n "$hit" ]] || continue
	file="${hit%%:*}"
	rest="${hit#*:}"
	line="${rest%%:*}"
	text="${rest#*:}"
	mod="$(printf '%s\n' "$text" | sed -nE 's/^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\7/p')"
	dir="${file%%/*}"
	n_imports=$((n_imports + 1))
	if [[ -z "$mod" ]]; then
		problem "Sources/HasalaCore/$file:$line: cannot read this import"
		continue
	fi
	why="$(hard_rule "$dir" "$mod")"
	if [[ -n "$why" ]]; then
		problem "Sources/HasalaCore/$file:$line: import $mod: $why"
		continue
	fi
	mods="$star $(allow_lines | awk -v d="$dir" '$1 == d { $1 = ""; print }')"
	case " $(echo $mods) " in
	*" $mod "*) ;;
	*) problem "Sources/HasalaCore/$file:$line: import $mod is not allowed in $dir/ (ios/HasalaCore/imports.allow)" ;;
	esac
done < <(cd "$SRC" && grep -rnE --include='*.swift' "$IMPORT_RE" . | sed 's|^\./||')
echo "imports: $n_imports import lines in $(echo $dirs | wc -w | tr -d ' ') directories checked against imports.allow"

# --- AT-C11 (spec 01) --------------------------------------------------------------
# token_only TOKEN_REGEX LABEL PATH_PREFIX...: TOKEN may appear (outside `//`
# comment lines) only in files under these ios/-relative prefixes.
token_only() {
	local re="$1" label="$2"
	shift 2
	local hit file ok p
	while IFS= read -r hit; do
		[[ -n "$hit" ]] || continue
		file="${hit%%:*}"
		ok=""
		for p in "$@"; do
			[[ "$file" == "$p"* ]] && ok=1
		done
		[[ -n "$ok" ]] || problem "ios/${hit%%:*}:$(echo "$hit" | cut -d: -f2): $label is only for $* (spec 01 AT-C11)"
	done < <(cd "$IOS" && grep -rnE --include='*.swift' --exclude-dir=.build --exclude-dir=DerivedData "$re" . |
		sed 's|^\./||' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
}
PRIM="HasalaCore/Sources/HasalaCore/Primitives/"
CRYP="HasalaCore/Sources/HasalaCore/Crypto/"
token_only 'AES\.GCM' 'AES.GCM' "$PRIM" "$CRYP"
token_only 'HKDF<' 'HKDF<' "$PRIM" "$CRYP"
token_only 'Curve25519\.Signing' 'Curve25519.Signing' "$PRIM" "$CRYP"
token_only 'SecRandomCopyBytes' 'SecRandomCopyBytes' "$PRIM" "$CRYP"
token_only 'CCKeyDerivationPBKDF' 'CCKeyDerivationPBKDF' "$PRIM"
token_only 'SecureEnclave\.P256' 'SecureEnclave.P256' "Hasala/Platform/ApprovalKey/"
echo "AT-C11: source scan of ios/ done"

# --- imports.allow against Package.swift ---------------------------------------------
if [[ -n "$MANIFEST" ]]; then
	if ! command -v swift >/dev/null || ! command -v jq >/dev/null; then
		echo "manifest: swift or jq not found, so imports.allow was not compared with Package.swift (CI's swift job does)"
	else
		before="$fail"
		fail=0
		described="$(cd "$CORE" && swift package describe --type json)"
		# All package-side module names: the targets and the products they use.
		pkgmods=" $(printf '%s' "$described" | jq -r '[.targets[].name, (.targets[].product_dependencies // [])[]] | unique | .[]' | tr '\n' ' ') "
		while IFS=$'\t' read -r tdir deps; do
			want="$(echo $deps | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ')"
			got=""
			for m in $(allow_lines | awk -v d="$tdir" '$1 == d { $1 = ""; print }'); do
				case "$pkgmods" in *" $m "*) got="$got $m" ;; esac
			done
			got="$(echo $got | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ')"
			[[ "$want" == "$got" ]] ||
				problem "imports.allow: $tdir/ lists package modules [${got% }] but Package.swift declares [${want% }]"
		done < <(printf '%s' "$described" | jq -r '.targets[] | select(.type != "test")
			| select(.path | startswith("Sources/HasalaCore/"))
			| [(.path | ltrimstr("Sources/HasalaCore/")), (((.target_dependencies // []) + (.product_dependencies // [])) | join(" "))]
			| @tsv')
		[[ "$fail" != 0 ]] || echo "manifest: imports.allow matches the target graph in Package.swift"
		[[ "$before" == 0 ]] || fail=1
	fi
fi

if [[ "$fail" != 0 ]]; then
	echo "check-imports: FAILED" >&2
	exit 1
fi
echo "check-imports: ok"
