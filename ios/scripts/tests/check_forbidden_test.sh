#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

tree() {
	local t="$work/$1"
	mkdir -p "$t/scripts" "$t/HasalaCore/Sources/HasalaCore/Money" "$t/HasalaCore/Sources/HasalaCore/Replay" \
		"$t/HasalaCore/Tests/CoreMoneyTests" "$t/HasalaKit/Sources/HasalaModels" "$t/HasalaKit/Tests/HasalaModelsTests" \
		"$t/Hasala/Features" "$t/HasalaTests" "$t/HasalaUITests"
	cp "$here/check-forbidden.sh" "$t/scripts/"
	echo 'public enum MinorExponent { public static let v1 = 2 }' >"$t/HasalaCore/Sources/HasalaCore/Money/Minor.swift"
	echo 'let e = MinorExponent.v1' >"$t/HasalaCore/Tests/CoreMoneyTests/T.swift"
	echo 'let e = MinorExponent.v1' >"$t/HasalaKit/Tests/HasalaModelsTests/T.swift"
	echo 'let e = MinorExponent.v1' >"$t/HasalaTests/T.swift"
	echo 'let e = MinorExponent.v1' >"$t/HasalaUITests/T.swift"
	echo 'struct App {}' >"$t/Hasala/App.swift"
	echo "$t"
}

check() {
	local rc=0
	"$3/scripts/check-forbidden.sh" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$2" ]]; then echo "ok   $1 (exit $rc)"; else
		echo "FAIL $1: exit $rc, want $2"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

names() {
	if grep -qF "$2" "$work/out"; then echo "ok   ...names $2"; else
		echo "FAIL $1: does not name $2"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

t="$(tree clean)"
check "Money/ and the tests may use MinorExponent" 0 "$t"

t="$(tree core)"
echo 'let x = MinorExponent.v1["KWD"]' >"$t/HasalaCore/Sources/HasalaCore/Replay/FX2.swift"
check "MinorExponent in Replay/" 1 "$t"
names "MinorExponent in Replay/" "HasalaCore/Sources/HasalaCore/Replay/FX2.swift:1"

t="$(tree kit)"
echo 'let x = MinorExponent.v1' >"$t/HasalaKit/Sources/HasalaModels/M.swift"
check "MinorExponent in HasalaKit" 1 "$t"
names "MinorExponent in HasalaKit" "HasalaKit/Sources/HasalaModels/M.swift:1"

t="$(tree app)"
printf 'import HasalaCore\nfunc f() { _ = MinorExponent.v1 }\n' >"$t/Hasala/Features/F.swift"
check "MinorExponent in the app" 1 "$t"
names "MinorExponent in the app" "Hasala/Features/F.swift:2"

t="$(tree comment)"
echo '// MinorExponent stays in Money/' >"$t/Hasala/Features/F.swift"
echo 'let MinorExponentish = 1' >"$t/Hasala/Features/G.swift"
check "a comment or a longer name is not a use" 0 "$t"

exit "$fail"
