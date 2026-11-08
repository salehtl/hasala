#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
lock="$work/t/private-fixtures.lock"
failures=0

g() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }

fresh() {
	rm -rf "$work/t" "$work/x"
	mkdir -p "$work/t/scripts" "$work/x"
	cp "$ROOT/scripts/private-fixtures-lock.sh" "$work/t/scripts/"
	printf 'commit earlier\n' >"$lock"
}

checkout() {
	git init -q "$1"
	printf 'synthetic fixture\n' >"$1/fixture-a"
	g "$1" add fixture-a
	g "$1" commit -q -m one
}

expect() {
	local name="$1" want="$2" mode="$3" dir="$4" says="${5:-}" rc=0
	"$work/t/scripts/private-fixtures-lock.sh" "$mode" "$dir" >"$work/out" 2>&1 || rc=$?
	if [[ "$rc" == "$want" ]]; then echo "ok   $name (exit $rc)"; else
		echo "FAIL $name: exit $rc, want $want"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
	if [[ -n "$says" ]] && ! grep -qF -- "$says" "$work/out"; then
		echo "FAIL $name: the output does not say '$says'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

lock_kept() {
	if [[ "$(cat "$lock")" == "commit earlier" ]]; then echo "ok   ...left the lock alone"; else
		echo "FAIL $1: the lock changed"
		sed 's/^/     /' "$lock"
		failures=$((failures + 1))
	fi
}

names_commit() {
	local dir="$1" head
	head="$(g "$dir" rev-parse HEAD)"
	if [[ "$(grep -c '^commit ' "$lock")" == 1 ]] && grep -qxF "commit $head" "$lock"; then
		echo "ok   ...the lock names the checkout's commit"
	else
		echo "FAIL the lock does not name commit $head"
		sed 's/^/     /' "$lock"
		failures=$((failures + 1))
	fi
}

fresh
mkdir "$work/x/plain"
printf 'synthetic fixture\n' >"$work/x/plain/fixture-a"
expect "write from a plain directory" 1 write "$work/x/plain" "not the top of a git checkout"
lock_kept "write from a plain directory"

fresh
checkout "$work/x/outer"
mkdir "$work/x/outer/inner"
printf 'synthetic fixture\n' >"$work/x/outer/inner/fixture-a"
g "$work/x/outer" add inner
g "$work/x/outer" commit -q -m inner
expect "write from a directory inside another repository" 1 write "$work/x/outer/inner" "not the top of a git checkout"
lock_kept "write from a directory inside another repository"

fresh
git init -q "$work/x/unborn"
expect "write from a repository with no commit" 1 write "$work/x/unborn" "has no commit"
lock_kept "write from a repository with no commit"

fresh
checkout "$work/x/dirty"
printf 'edited\n' >>"$work/x/dirty/fixture-a"
expect "write from a checkout with uncommitted changes" 1 write "$work/x/dirty" "uncommitted changes"
lock_kept "write from a checkout with uncommitted changes"

fresh
checkout "$work/x/clean"
expect "write from a clean checkout" 0 write "$work/x/clean" "wrote 1 file(s)"
names_commit "$work/x/clean"
expect "...and that checkout passes check" 0 check "$work/x/clean" "all 1 pinned files match"

fresh
checkout "$work/x/main"
g "$work/x/main" worktree add -q -b side "$work/x/linked"
expect "write from a linked worktree" 0 write "$work/x/linked" "wrote 1 file(s)"
names_commit "$work/x/linked"

fresh
checkout "$work/x/clean"
expect "write before a plain copy is checked" 0 write "$work/x/clean"
mkdir "$work/x/copy"
cp "$work/x/clean/fixture-a" "$work/x/copy/"
expect "check still reads a plain copy of the files" 0 check "$work/x/copy" "at commit unknown"
printf 'edited\n' >>"$work/x/copy/fixture-a"
expect "...and refuses it when a file differs" 1 check "$work/x/copy" "CHANGED fixture-a"

if ((failures)); then
	echo "$failures private fixtures lock case(s) failed"
	exit 1
fi
