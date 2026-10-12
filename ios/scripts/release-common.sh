# shellcheck shell=bash
# release-common.sh: sourced by archive.sh, inspect-ipa.sh and upload.sh (and the
# script tests). Pure helpers only: nothing here touches the network, a key or the
# keychain.
#
# The scripts also run inside the repository's Nix devShell (.envrc: use flake),
# where GNU coreutils, grep, sed and findutils come first on PATH. Every tool whose
# BSD and GNU forms differ (stat, date) or that only macOS has (shasum, plutil,
# PlistBuddy, codesign, otool, strings) is called by its absolute path; what is left
# on PATH (grep -E/-q/-c/-a/-r, find, mkdir, tail, ...) behaves the same in both.

# The file archive.sh writes beside summary.txt when the archive is a local trial
# (--allow-dirty or --allow-branch). upload.sh refuses any build that has it.
# shellcheck disable=SC2034 # read by the scripts that source this file
HASALA_TRIAL_MARKER="TRIAL"

# hasala_build_root IOS_DIR: the directory that holds <BUILD>/ (one per archive) and
# last-build-number: IOS_DIR/build. The offline script tests move it with
# HASALA_BUILD_DIR, which counts only together with HASALA_TEST_MODE=1 (and is then
# announced on stderr). A HASALA_BUILD_DIR without HASALA_TEST_MODE=1 is refused: this
# fails, saying so, and archive.sh and upload.sh exit 2 before they do anything, so a
# stray variable in a release shell never moves the builds or last-build-number.
hasala_build_root() {
	if [[ -z "${HASALA_BUILD_DIR:-}" ]]; then
		printf '%s\n' "$1/build"
		return 0
	fi
	if [[ "${HASALA_TEST_MODE:-}" != 1 ]]; then
		echo "HASALA_BUILD_DIR is set ('$HASALA_BUILD_DIR') but HASALA_TEST_MODE is not 1: HASALA_BUILD_DIR is for the offline script tests only; unset it to release from $1/build" >&2
		return 1
	fi
	echo "TEST MODE (HASALA_TEST_MODE=1): builds and last-build-number are in $HASALA_BUILD_DIR, not $1/build" >&2
	printf '%s\n' "$HASALA_BUILD_DIR"
}

# hasala_build_newer NEW LAST: true when build NEW is strictly newer than LAST
# under version-string comparison, component-wise integer (spec 06 §8). Both are
# YYMMDD.1HHMM; anything else is refused (false).
hasala_build_newer() {
	local new="$1" last="$2"
	[[ "$new" =~ ^[0-9]{6}\.1[0-9]{4}$ && "$last" =~ ^[0-9]{6}\.1[0-9]{4}$ ]] || return 1
	local nd="${new%%.*}" nt="${new##*.}" ld="${last%%.*}" lt="${last##*.}"
	((10#$nd > 10#$ld)) && return 0
	((10#$nd == 10#$ld && 10#$nt > 10#$lt))
}

# hasala_record_build ROOT BUILD: write BUILD to ROOT/last-build-number, atomically
# (a new file renamed over the old one), so a crash never leaves it half-written.
hasala_record_build() {
	local root="$1" build="$2"
	mkdir -p -- "$root" &&
		printf '%s\n' "$build" >"$root/last-build-number.tmp" &&
		mv -f -- "$root/last-build-number.tmp" "$root/last-build-number"
}

# hasala_marketing_version CONFIG_DIR: prints MARKETING_VERSION (X.Y.Z) from the one
# line in CONFIG_DIR/*.xcconfig that sets it. Fails, saying why, when no line or more
# than one line sets it (a conditional MARKETING_VERSION[config=...] counts), or the
# value is not X.Y.Z. Plain bash: no grep or sed dialect involved.
hasala_marketing_version() {
	local dir="$1" f line found=()
	for f in "$dir"/*.xcconfig; do
		[[ -f "$f" ]] || continue
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ "$line" =~ ^[[:space:]]*MARKETING_VERSION ]] || continue
			if [[ "$line" =~ ^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$ ]]; then
				found+=("${BASH_REMATCH[1]}")
			else
				echo "${f##*/}: cannot read '$line'; set MARKETING_VERSION = X.Y.Z, unconditionally, once" >&2
				return 1
			fi
		done <"$f"
	done
	if ((${#found[@]} != 1)); then
		echo "$dir/*.xcconfig set MARKETING_VERSION ${#found[@]} times; it must be set exactly once" >&2
		return 1
	fi
	if [[ ! "${found[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "MARKETING_VERSION is '${found[0]}', not X.Y.Z" >&2
		return 1
	fi
	printf '%s\n' "${found[0]}"
}

# hasala_sha256 FILE: the file's SHA-256 in lower-case hex.
hasala_sha256() {
	local out
	out="$(/usr/bin/shasum -a 256 -- "$1")" || return 1
	out="${out%% *}"
	[[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$out"
}

# hasala_absent ERE PATH...: true only when grep read every PATH (a file, or a
# directory, recursively; binary files are searched as text) and no line matches
# ERE, i.e. grep exits 1. A match (0) and any error, such as a missing or unreadable
# PATH (2), are false: an absence check never passes because it had nothing to read.
#
# Never pipe a tool into `grep -q` for an absence check: under pipefail, grep -q
# exits at the first match, the writer dies of SIGPIPE (141), the pipeline fails and
# `! ...` turns that into a pass. Write the tool's output to a file and pass the file.
hasala_absent() {
	hasala_grep_absent -E "$@"
}

# hasala_absent_i ERE PATH...: as hasala_absent, but a line matches ERE in any case
# (grep -i; under LC_ALL=C that folds the ASCII letters only). For inspect-ipa.sh's
# dev-host search (I12), where http://LOCALHOST:8080 is as much a dev host as
# http://localhost:8080.
hasala_absent_i() {
	hasala_grep_absent -iE "$@"
}

# hasala_grep_absent GREP-FLAGS ERE PATH...: the one grep behind hasala_absent and
# hasala_absent_i.
hasala_grep_absent() {
	(($# > 2)) || return 1
	local flags="$1" re="$2" rc=0
	shift 2
	LC_ALL=C grep -r -a -q "$flags" -e "$re" -- "$@" || rc=$?
	[[ "$rc" == 1 ]]
}

# The last line of a summary.txt whose every inspection passed (inspect-ipa.sh):
#
#   PASS <n>/<n> sha256=<SHA-256 of the .ipa that was inspected>
HASALA_PASS_RE='^PASS ([0-9]+)/([0-9]+) sha256=([0-9a-f]{64})$'

# hasala_summary_passed SUMMARY IPA BUILD: true when SUMMARY is inspect-ipa.sh's
# summary for BUILD (first line "Hasala BUILD (...)"), has no FAIL line, and ends in
# the PASS line, whose count equals its "ok" lines and whose sha256 is IPA's. A
# summary cut short (header only, or anything without the PASS line last), one for
# another build, and one for other bytes are refused, with the reason on stderr.
hasala_summary_passed() {
	local summary="$1" ipa="$2" build="$3" first last oks want
	if [[ ! -f "$summary" ]]; then
		echo "there is no $summary; only an .ipa that archive.sh exported and inspected can be uploaded" >&2
		return 1
	fi
	first="$(head -n 1 -- "$summary")" || return 1
	if [[ "$first" != "Hasala $build ("* ]]; then
		echo "$summary is for '$first', not build $build" >&2
		return 1
	fi
	if ! hasala_absent '^  FAIL' "$summary"; then
		echo "build $build failed inspection (see $summary)" >&2
		return 1
	fi
	last="$(tail -n 1 -- "$summary")" || return 1
	if [[ ! "$last" =~ $HASALA_PASS_RE ]]; then
		echo "$summary does not end in the PASS line; the inspection did not finish (last line: '$last')" >&2
		return 1
	fi
	local passed="${BASH_REMATCH[1]}" total="${BASH_REMATCH[2]}" hash="${BASH_REMATCH[3]}"
	oks="$(grep -c -e '^  ok    ' -- "$summary" || true)"
	if [[ "$passed" != "$total" || "$total" == 0 || "$oks" != "$total" ]]; then
		echo "$summary says PASS $passed/$total but lists ${oks:-no} passing checks" >&2
		return 1
	fi
	if ! want="$(hasala_sha256 "$ipa")"; then
		echo "cannot hash $ipa" >&2
		return 1
	fi
	if [[ "$hash" != "$want" ]]; then
		echo "$ipa is not the file that was inspected: its sha256 is $want, the summary's is $hash" >&2
		return 1
	fi
}
