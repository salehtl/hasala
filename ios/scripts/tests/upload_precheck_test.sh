#!/usr/bin/env bash
# upload.sh refuses, before it reads a key or touches the network, any .ipa whose
# archive inspection did not pass for that very build, and any local trial
# (spec 06 §10.3–§10.4). Runs offline with fake .ipa files; no key is needed.
# The build numbers are far in the future so a real ios/build/last-build-number
# never makes the clean case exit 21.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# make_build DIR BUILD: a fake ios/build/<BUILD> with export/Hasala.ipa.
make_build() {
	local dir="$1" build="$2"
	mkdir -p "$dir/export" "$dir/stage/Payload/Hasala.app"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$dir/stage/Payload/Hasala.app/Info.plist" >/dev/null
	(cd "$dir/stage" && zip -qr "$dir/export/Hasala.ipa" Payload)
	rm -rf "$dir/stage"
}
expect() {
	local name="$1" want="$2" dir="$3" rc=0
	# An empty HOME and no ASC_* variables: a run that gets past the prechecks
	# stops at the key (14) and never reaches altool.
	env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH HOME="$work/home" \
		"$here/upload.sh" "$dir/export/Hasala.ipa" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}
mkdir -p "$work/home"

b="$work/991231.12359"
make_build "$b" 991231.12359
expect "no summary.txt" 40 "$b"

printf 'Hasala 991231.12358 (0123456789ab)\n  ok    I3\n' >"$b/summary.txt"
expect "summary.txt for another build" 40 "$b"

printf 'Hasala 991231.12359 (0123456789ab)\n  ok    I3\n  FAIL  I1 entitlements\n' >"$b/summary.txt"
expect "summary.txt with a FAIL" 40 "$b"

printf 'Hasala 991231.12359 (0123456789ab)\n  ok    I3\n' >"$b/summary.txt"
echo "local trial, not for upload: dirty tree" >"$b/TRIAL"
expect "a local trial" 40 "$b"

rm "$b/TRIAL"
expect "a clean, inspected build reaches the key check" 14 "$b"

# asc.env is sourced as shell, so a group- or world-readable one is refused.
mkdir -p "$work/home/.config/hasala"
printf 'ASC_KEY_ID=TESTKEY000\nASC_ISSUER_ID=00000000-0000-0000-0000-000000000000\n' >"$work/home/.config/hasala/asc.env"
chmod 644 "$work/home/.config/hasala/asc.env"
expect "an asc.env with mode 0644" 14 "$b"
if grep -q "must be yours with mode 0600" "$work/out"; then echo "ok   ...refused for its mode"; else
	echo "FAIL the 0644 asc.env was not refused for its mode"
	fail=1
fi

exit "$fail"
