#!/usr/bin/env bash
# asc-env.sh's asc_resolve_key (spec 06 §9): ids from the environment or a 0600
# asc.env, a key file named AuthKey_<ASC_KEY_ID>.p8 with mode 0600, outside the
# repository. Offline: HOME is an empty temporary directory and the "keys" are text
# files; the real ~/.appstoreconnect and ~/.config/hasala are never read. Runs under
# GNU coreutils too (devshell_test.sh), where a bare `stat -f` broke the 0600 case.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
inrepo=""
cleanup() {
	rm -rf "$work"
	if [[ -n "$inrepo" ]]; then rm -rf "$inrepo"; fi
}
trap cleanup EXIT
fail=0
issuer=00000000-0000-0000-0000-000000000000

# resolve NAME WANT [VAR=value...]: asc_resolve_key in a fresh shell with HOME empty
# and only the given ASC_* variables; WANT is its status. Prints ASC_KEY_PATH on success.
resolve() {
	local name="$1" want="$2" rc=0
	shift 2
	env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH HOME="$work/home" "$@" \
		bash -c 'source "$1/asc-env.sh" && asc_resolve_key && echo "path=$ASC_KEY_PATH"' _ "$here" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (status $rc)"; else
		echo "FAIL $name: status $rc, want $want"
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

mkdir -p "$work/home/.config/hasala" "$work/home/.appstoreconnect/private_keys" "$work/keys"
key="$work/keys/AuthKey_TESTKEY000.p8"
echo "not a key" >"$key"
chmod 600 "$key"

resolve "no ids and no asc.env" 14
resolve "ids and a 0600 key named for the id" 0 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key"
said "path=$key" "ASC_KEY_PATH is the given file"
resolve "a key id with a path in it" 14 ASC_KEY_ID=../TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key"
resolve "a key file named for another id" 14 ASC_KEY_ID=OTHERKEY00 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key"
said "is not named AuthKey_OTHERKEY00.p8" "refused for its name"
cp "$key" "$work/keys/key.p8"
resolve "a key file not named AuthKey_<id>.p8" 14 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$work/keys/key.p8"
resolve "no key file at the default path" 14 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer"
said "no API key file at $work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8" "looked at the default path"
chmod 644 "$key"
resolve "a key file with mode 0644" 14 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key"
said "has mode 644" "refused for its mode"
chmod 400 "$key"
resolve "a key file with mode 0400" 0 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$key"
chmod 600 "$key"

# Inside the repository: ios/build is git-ignored, and the "key" is removed on exit.
mkdir -p "$ios/build"
inrepo="$(mktemp -d "$ios/build/asc-env-test.XXXXXX")"
cp "$key" "$inrepo/AuthKey_TESTKEY000.p8"
chmod 600 "$inrepo/AuthKey_TESTKEY000.p8"
resolve "a key file inside the repository" 14 ASC_KEY_ID=TESTKEY000 ASC_ISSUER_ID="$issuer" ASC_KEY_PATH="$inrepo/AuthKey_TESTKEY000.p8"
said "is inside the repository" "refused for where it is"
rm -rf "$inrepo"
inrepo=""

# asc.env, sourced as shell when an id is missing: the owner's, mode 0600 (or 0400).
cp "$key" "$work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8"
chmod 600 "$work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8"
printf 'ASC_KEY_ID=TESTKEY000\nASC_ISSUER_ID=%s\n' "$issuer" >"$work/home/.config/hasala/asc.env"
chmod 600 "$work/home/.config/hasala/asc.env"
resolve "ids from a 0600 asc.env, the key at its default path" 0
said "path=$work/home/.appstoreconnect/private_keys/AuthKey_TESTKEY000.p8" "ASC_KEY_PATH defaults to ~/.appstoreconnect/private_keys"
chmod 644 "$work/home/.config/hasala/asc.env"
resolve "an asc.env with mode 0644" 14
said "must be yours with mode 0600" "refused for its mode"
chmod 640 "$work/home/.config/hasala/asc.env"
resolve "an asc.env with mode 0640" 14
exit "$fail"
