#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
fail=0
seed=server/internal/tmpl/seed
out=ios/HasalaCore/Sources/HasalaCore/Resources/templates
manifest=ios/HasalaCore/Sources/HasalaCore/Resources/TemplatesManifest.swift

swiftc -o "$work/sync" "$repo/ios/tools/templates/sync.swift"

sync() {
	local rc=0
	(cd "$work/t" && "$work/sync" "$@") >"$work/out" 2>&1 || rc=$?
	return "$rc"
}

expect_exit() {
	local name="$1" want="$2" rc=0
	shift 2
	sync "$@" || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		fail=1
	fi
}

same() {
	if cmp -s "$work/t/$2" "$work/before/$2"; then echo "ok   ...$1"; else
		echo "FAIL $1: $2 changed"
		fail=1
	fi
}

there() {
	if [[ -e "$work/t/$2" ]]; then echo "ok   ...$1"; else
		echo "FAIL $1: $2 is gone"
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

fresh() {
	chmod -R u+w "$work/t" 2>/dev/null || true
	rm -rf "$work/t" "$work/before"
	mkdir -p "$work/t/$seed"
	printf '{"id":"a","version":1}\n' >"$work/t/$seed/a.json"
	printf '{"id":"b","version":1}\n' >"$work/t/$seed/b.json"
	sync
	printf '{"id":"old","version":1}\n' >"$work/t/$out/old.json"
	cp -R "$work/t" "$work/before"
}

fresh
expect_exit "a stale file in the bundle fails --check" 1 --check
rm "$work/t/$out/old.json"
expect_exit "...and the tree passes once it is gone" 0 --check

fresh
printf '{"id":"a","version":2}\n' >"$work/t/$seed/a.json"
printf '{"id":"z"}\n' >"$work/t/$seed/z.json"
expect_exit "a seed with no version" 1
said "z.json has no string id and integer version"
same "the earlier seed was not copied" "$out/a.json"
same "the manifest was not written" "$manifest"
there "the stale file was not removed" "$out/old.json"

fresh
printf '{"id":"a","version":2}\n' >"$work/t/$seed/a.json"
printf '{"id":"not-z","version":1}\n' >"$work/t/$seed/z.json"
expect_exit "a seed named for another template" 1
said "z.json holds template not-z"
same "the earlier seed was not copied" "$out/a.json"
same "the manifest was not written" "$manifest"

fresh
printf '{"id":"a","version":2}\n' >"$work/t/$seed/a.json"
chmod 555 "$work/t/$out"
expect_exit "a stale file that cannot be removed" 1
said "cannot remove"
same "the manifest was not written" "$manifest"
chmod 755 "$work/t/$out"

fresh
printf '{"id":"a","version":2}\n' >"$work/t/$seed/a.json"
printf '{"id":"c","version":1}\n' >"$work/t/$seed/c.json"
expect_exit "good seeds sync" 0
if [[ ! -e "$work/t/$out/old.json" ]] && cmp -s "$work/t/$seed/a.json" "$work/t/$out/a.json" && cmp -s "$work/t/$seed/c.json" "$work/t/$out/c.json"; then
	echo "ok   ...copied them and removed the stale file"
else
	echo "FAIL the good sync left the bundle different from the seed"
	fail=1
fi
expect_exit "...and --check agrees" 0 --check
exit "$fail"
