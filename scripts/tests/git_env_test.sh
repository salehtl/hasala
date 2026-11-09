#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

w() { git -C "$work/wt" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

git init -q "$work/outer"
git -C "$work/outer" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m outer
git -C "$work/outer" worktree add -q -b side "$work/wt"
printf 'kept\n' >"$work/wt/tracked"
w add tracked
w commit -q -m tracked
gitdir="$(w rev-parse --absolute-git-dir)"

state() {
	w symbolic-ref HEAD
	w rev-parse HEAD
	w for-each-ref
	w ls-files -s
	w status --porcelain
}

runs_with_git_env() {
	local test="$1" rc=0 before after
	before="$(state)"
	(cd "$work/wt" && GIT_DIR="$gitdir" GIT_WORK_TREE="$work/wt" GIT_INDEX_FILE="$gitdir/index" "$ROOT/scripts/tests/$test") >"$work/out" 2>&1 || rc=$?
	after="$(state)"
	if [[ "$rc" != 0 ]]; then
		echo "FAIL $test with the git environment exported: exit $rc"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
	if [[ "$before" == "$after" ]]; then echo "ok   $test with the git environment exported leaves the repository alone"; else
		echo "FAIL $test with the git environment exported changed the repository it runs in:"
		diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/     /' || true
		failures=$((failures + 1))
	fi
}

runs_with_git_env fence_test.sh
runs_with_git_env gate_run_test.sh

if ((failures)); then
	echo "$failures git environment case(s) failed"
	exit 1
fi
