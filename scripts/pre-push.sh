#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: scripts/pre-push.sh [--all]   opt-in local checks for what changed against origin/main (run inside the devShell: direnv exec . scripts/pre-push.sh)"
}

ALL=""
case "${1:-}" in
"") ;;
--all) ALL=1 ;;
-h | --help)
	usage
	exit 0
	;;
-*)
	usage >&2
	exit 2
	;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE="$(git merge-base HEAD origin/main 2>/dev/null || true)"
if [[ -z "$BASE" ]]; then
	echo "pre-push: no origin/main to compare with; running every check" >&2
	ALL=1
	BASE="$(git hash-object -t tree /dev/null)"
fi

CHANGED="$(
	{
		git diff --name-only --diff-filter=d "$BASE"
		git ls-files --others --exclude-standard
	} | LC_ALL=C sort -u
)"

changed() {
	[[ -n "$ALL" ]] && return 0
	printf '%s\n' "$CHANGED" | grep -Eq "$1"
}

changed_files() {
	local f
	printf '%s\n' "$CHANGED" | grep -E "$1" | while IFS= read -r f; do
		[[ -f "$f" ]] && printf '%s\n' "$f"
	done
	return 0
}

all_files() {
	if [[ -n "$ALL" ]]; then
		git ls-files -z -- "$1" | tr '\0' '\n' | while IFS= read -r f; do
			[[ -f "$f" ]] && printf '%s\n' "$f"
		done
		return 0
	fi
	changed_files "$2"
}

LOG="$(mktemp -d "${TMPDIR:-/tmp}/hasala-pre-push.XXXXXX")"
trap 'rm -rf "$LOG"' EXIT
PASSED=0
FAILED=0
SKIPPED=0
T0=$SECONDS

run() {
	local name="$1" start rc=0
	shift
	start=$SECONDS
	("$@") >"$LOG/out" 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		printf 'PASS  %s (%ss)\n' "$name" "$((SECONDS - start))"
		PASSED=$((PASSED + 1))
	else
		printf 'FAIL  %s (%ss)\n' "$name" "$((SECONDS - start))"
		sed 's/^/      /' "$LOG/out"
		FAILED=$((FAILED + 1))
	fi
}

skip() {
	printf 'SKIP  %s (%s)\n' "$1" "$2"
	SKIPPED=$((SKIPPED + 1))
}

have() { command -v "$1" >/dev/null 2>&1; }

gofmt_check() {
	local out
	out="$(printf '%s\n' "$1" | xargs gofmt -l)"
	if [[ -n "$out" ]]; then
		echo "not gofmt-formatted:"
		echo "$out"
		return 1
	fi
}

vet_module() {
	local mod="$1" files="$2" dirs
	dirs="$(printf '%s\n' "$files" | while IFS= read -r f; do
		case "$mod" in
		server/oracle) case "$f" in server/oracle/*) printf './%s\n' "$(dirname "${f#server/oracle/}")" ;; esac ;;
		server) case "$f" in server/oracle/*) ;; server/*) printf './%s\n' "$(dirname "${f#server/}")" ;; esac ;;
		esac
	done | sed 's#^\./\.$#.#' | LC_ALL=C sort -u)"
	[[ -n "$dirs" ]] || return 0
	cd "$ROOT/$mod"
	# shellcheck disable=SC2086
	go vet $dirs
}

templates_check() {
	local bundled="ios/HasalaCore/Sources/HasalaCore/Resources/templates" seed="server/internal/tmpl/seed" f
	if [[ "$(cd "$bundled" && ls -1 ./*.json)" != "$(cd "$seed" && ls -1 ./*.json)" ]]; then
		echo "the bundled template set differs from $seed; run swift ios/tools/templates/sync.swift"
		return 1
	fi
	for f in "$seed"/*.json; do
		if ! cmp -s "$f" "$bundled/${f##*/}"; then
			echo "${f##*/} differs from the server seed; run swift ios/tools/templates/sync.swift"
			return 1
		fi
	done
}

gitleaks_check() {
	gitleaks git --config .gitleaks.toml --log-opts="$BASE..HEAD" --redact --no-banner .
}

echo "pre-push: base ${BASE:0:12}$([[ -n "$ALL" ]] && echo ', --all' || echo ", $(printf '%s\n' "$CHANGED" | grep -c . || true) changed file(s)")"

run "real-mail fence" scripts/check.sh --fence-only
run "HasalaCore import lint" ios/scripts/check-imports.sh --no-manifest
run "HasalaCore forbidden-API lint" ios/scripts/check-forbidden.sh

if ! have gitleaks; then
	skip "gitleaks" "not on PATH"
elif [[ "$BASE" == "$(git rev-parse HEAD)" ]]; then
	skip "gitleaks" "no new commits"
else
	run "gitleaks ($(git rev-list --count "$BASE..HEAD") new commit(s))" gitleaks_check
fi

if changed '\.go$'; then
	GOFILES="$(all_files '*.go' '\.go$' | grep -v '^server/oracle/v1ref/' || true)"
	if ! have gofmt || ! have go; then
		skip "gofmt, go vet" "go not on PATH"
	elif [[ -z "$GOFILES" ]]; then
		skip "gofmt, go vet" "no Go files"
	else
		run "gofmt" gofmt_check "$GOFILES"
		if [[ -n "$ALL" ]]; then
			run "go vet server/" bash -c 'cd server && go vet ./...'
			run "go vet server/oracle/" bash -c 'cd server/oracle && go vet ./...'
		else
			if printf '%s\n' "$GOFILES" | grep -qv '^server/oracle/'; then
				run "go vet server/ (changed packages)" vet_module server "$GOFILES"
			fi
			if printf '%s\n' "$GOFILES" | grep -q '^server/oracle/'; then
				run "go vet server/oracle/ (changed packages)" vet_module server/oracle "$GOFILES"
			fi
		fi
	fi
else
	skip "gofmt, go vet" "no Go changes"
fi

if changed '\.nix$'; then
	NIXFILES="$(all_files '*.nix' '\.nix$')"
	if have nixfmt; then
		run "nixfmt --check" bash -c 'printf "%s\n" "$1" | xargs nixfmt --check' _ "$NIXFILES"
	else
		skip "nixfmt" "nixfmt not on PATH"
	fi
else
	skip "nixfmt" "no Nix changes"
fi

if changed '^(ios/|design/tokens/)'; then
	if changed '^(design/tokens/|ios/tools/tokens/|ios/HasalaKit/.*(Generated|Tokens))'; then
		if have swift; then
			run "design tokens are generated" swift ios/tools/tokens/generate.swift --check
		else
			skip "design tokens" "swift not on PATH"
		fi
	else
		skip "design tokens" "no token changes"
	fi
	if changed '^ios/(project\.yml|Hasala\.xcodeproj/|scripts/generate-project\.sh)'; then
		if have xcodegen || [[ -n "${XCODEGEN:-}" ]]; then
			run "Xcode project matches project.yml" ios/scripts/generate-project.sh --check
		else
			skip "Xcode project" "xcodegen not on PATH"
		fi
	else
		skip "Xcode project" "no project changes"
	fi
	if changed '^ios/(HasalaCore/(Package\.resolved|Tools/)|Hasala\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/|scripts/check-tool-pins\.sh)'; then
		if have jq; then
			run "HasalaCore tool pins equal HasalaCore's" ios/scripts/check-tool-pins.sh
		else
			skip "HasalaCore tool pins" "jq not on PATH"
		fi
	else
		skip "HasalaCore tool pins" "no Package.resolved or tool changes"
	fi
else
	skip "design tokens, Xcode project, tool pins" "no ios/ changes"
fi

if changed '^(ios/HasalaCore/Sources/HasalaCore/Resources/templates/|server/internal/tmpl/seed/)'; then
	run "bundled templates equal the server seed" templates_check
else
	skip "bundled templates" "no template or seed changes"
fi

if changed '\.sh$'; then
	SHFILES="$(all_files '*.sh' '\.sh$' | grep -v '^reference/' || true)"
	if [[ -z "$SHFILES" ]]; then
		skip "shellcheck" "only reference/ scripts changed"
	elif have shellcheck; then
		run "shellcheck" bash -c 'printf "%s\n" "$1" | xargs shellcheck -S warning' _ "$SHFILES"
	else
		skip "shellcheck" "not on PATH"
	fi
else
	skip "shellcheck" "no shell changes"
fi

if changed '^(web/|docs/legal/)'; then
	if [[ -d web/node_modules ]] && have bun; then
		run "web: astro check" bash -c 'cd web && bun run check'
	else
		skip "web: astro check" "web/node_modules missing or bun not on PATH (cd web && bun install --frozen-lockfile)"
	fi
else
	skip "web: astro check" "no web or legal changes"
fi

echo "pre-push: $PASSED passed, $FAILED failed, $SKIPPED skipped in $((SECONDS - T0))s"
[[ $FAILED -eq 0 ]]
