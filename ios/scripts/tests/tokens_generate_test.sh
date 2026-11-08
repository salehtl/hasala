#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
input=design/tokens/paper-tokens.json
output=ios/HasalaKit/Sources/HasalaDesign/Generated/Tokens.swift

swiftc -o "$work/generate" "$repo/ios/tools/tokens/generate.swift"

generate() {
	local rc=0
	(cd "$work/t" && "$work/generate" "$@") >"$work/out" 2>&1 || rc=$?
	return "$rc"
}

expect_exit() {
	local name="$1" want="$2" rc=0
	shift 2
	generate "$@" || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

token_set() {
	printf '{"hash":"%s","count":1,"tokens":[{"name":"--color-ink","value":"%s"}]}\n' "$1" "$2" >"$work/t/$input"
}

fresh() {
	rm -rf "$work/t"
	mkdir -p "$work/t/$(dirname "$input")" "$work/t/$(dirname "$output")"
	token_set aaaa1111 "#000000"
	generate --accept-hash
	cp "$work/t/$output" "$work/before"
}

said() {
	if grep -qF -- "$1" "$work/out"; then echo "ok   ...says $1"; else
		echo "FAIL the output does not say '$1'"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

unchanged() {
	if cmp -s "$work/t/$output" "$1"; then echo "ok   ...left Tokens.swift alone"; else
		echo "FAIL Tokens.swift changed"
		fail=1
	fi
}

absent() {
	if [[ -e "$work/t/$output" ]]; then
		echo "FAIL Tokens.swift was written"
		fail=1
	else echo "ok   ...wrote no Tokens.swift"; fi
}

records() {
	if grep -qF "paperHash = \"$1\"" "$work/t/$output"; then echo "ok   ...records set $1"; else
		echo "FAIL Tokens.swift does not record set $1"
		fail=1
	fi
}

fresh
expect_exit "the same set regenerates with no flag" 0
unchanged "$work/before"
expect_exit "...and --check agrees" 0 --check

fresh
token_set bbbb2222 "#111111"
expect_exit "a new set with no flag" 1
said "generated from aaaa1111"
unchanged "$work/before"

fresh
token_set bbbb2222 "#111111"
expect_exit "a new set with --accept-hash" 0 --accept-hash
records bbbb2222

fresh
token_set bbbb2222 "#111111"
rm "$work/t/$output"
expect_exit "a missing Tokens.swift with no flag" 1
said "records no token set"
absent

fresh
rm "$work/t/$output"
expect_exit "a missing Tokens.swift under --check" 1 --check
absent

fresh
token_set bbbb2222 "#111111"
rm "$work/t/$output"
expect_exit "a missing Tokens.swift with --accept-hash" 0 --accept-hash
records bbbb2222

fresh
token_set bbbb2222 "#111111"
sed -i.bak 's/paperHash/otherName/' "$work/t/$output"
rm "$work/t/$output.bak"
cp "$work/t/$output" "$work/edited"
expect_exit "a Tokens.swift with its hash line gone" 1
said "records no token set"
unchanged "$work/edited"

exit "$fail"
