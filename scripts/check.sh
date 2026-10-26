#!/usr/bin/env bash
# check.sh — Hasala's build gate. This script IS the build: every change ends by
# running it, from the repo root, through the devShell (it takes Go, Postgres
# and Bun from flake.nix, never from the host):
#
#   direnv exec . nice -n 10 scripts/check.sh
#
# CI (.github/workflows/ci.yml, job `gate`) runs the same script on every push
# to main and every pull request that touches what it reads, without the
# private fixtures (see "CI" below).
#
# It is ledgerd's scripts/v2-check.sh carried over to the monorepo layout:
# server/ (the Go module, and server/oracle/, the separate module that holds
# the frozen v1 reference packages and the corpus gates) and conformance/ (the
# fixtures Go and the Swift port must agree on). The ledgerd TypeScript client
# core that once was a third executor is removed; its last state is the tag
# ts-reference-final.
#
# In order:
#   0. The real-mail fence: no real bank mail has come back into this tree.
#      It needs no toolchain; `scripts/check.sh --fence-only` runs it alone.
#  0b. HasalaCore's source lints (ios/scripts/check-imports.sh and
#      check-forbidden.sh): grep only, so they run on Linux too. Then the
#      bundled bank templates are byte-identical to the server seed. The Swift
#      build and tests themselves run in CI's `swift` job on a Mac.
#   1. The Go toolchain is at least server/go.mod's `toolchain` line.
#   2. The hasalad fences (spec 02 §4.4, cmd/hasalad/fence_test.go): the
#      server's build graph never reaches the oracle module, the test sealers
#      or a retired capability, and its source cannot encrypt or decrypt.
#      Then govulncheck ./cmd/hasalad/... (needs the network; skipped in CI,
#      where the `vuln` job scans every package).
#   3. ONE throwaway Postgres cluster for the whole run (unix socket, no TCP),
#      shared through HASALA_TEST_POSTGRES_URL and stopped on any exit.
#   4. go vet ./... and go test ./... in server/, then in server/oracle/.
#   5. The assist worker (infra/assist): typecheck, then bun test.
#   6. The conformance suites, by name: every fixture set under conformance/
#      must have an entry here, so a new one cannot land without saying what
#      checks it. The Go half is proven from step 4's record (every test of each
#      package ran there); the Swift half runs in CI's `swift` job.
#   7. Known failures: tests skipped in 4 by name, each re-run on its own and
#      required to still fail (see KNOWN_FAILING below).
#
# Real bank mail is NOT in this repository. The conformance cases cut from the
# operator's mailbox (conformance/normalizer/*.json apart from edge-cases.json,
# conformance/templates/corpus-*.json) and the signed .eml messages that were
# under server/internal/origin/testdata live in the private salehtl/hasala-fixtures
# repository, under the same paths. Point HASALA_PRIVATE_FIXTURES at a checkout
# of it to run the tests that read them:
#
#   HASALA_PRIVATE_FIXTURES=/path/to/hasala-fixtures direnv exec . scripts/check.sh
#
# Unset, those tests SKIP with a reason that names the variable, and the run
# says so in its last lines; it is then not the full gate. Set, the checkout must
# match private-fixtures.lock exactly (scripts/private-fixtures-lock.sh: the
# fixtures commit and a sha256 per file), and every real-corpus test must run: a
# missing file is a failure, not a skip. Either way
# the run first checks that no real-mail fixture has crept back into this tree,
# and reports how many real-corpus tests ran and how many were skipped.
#
# CHECK_JOBS (default 8) caps go's package parallelism: the QA host is shared with
# other services, so the gate keeps to about half the machine.
#
# CI: under GitHub Actions (GITHUB_ACTIONS=true) every step but govulncheck runs
# exactly as it does anywhere else, with the same verdicts; govulncheck is left
# to the required `vuln` job, which scans both modules whole. The reporting
# adapts to a runner whose temp directory dies with the job. On failure the postgres log is
# printed instead of named, and the closing real-corpus count is also raised as
# an annotation and written to the job summary, so a run without the private
# fixtures says so on the pull request, not only at the end of a long log. CI
# also runs `scripts/check.sh --fence-only` alone, without a toolchain, in job
# `secrets` on every push and pull request (including those that skip `gate`),
# so the real-mail fence holds on every push even when the rest cannot build.
#
# What this does NOT run is the full-corpus cross-executor diff and the corpus-
# equivalence gate: both need a snapshot of the operator's v1 mailbox
# (HASALA_CORPUS_DB, read only in server/oracle), which no checkout has, and those tests skip without it.
# The recipes are in the ledgerd design archive, which is not published.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${CHECK_JOBS:-8}"
step() { printf '\n== check: %s\n' "$*"; }

FENCE_ONLY=""
case "$*" in
"") ;;
--fence-only) FENCE_ONLY=1 ;;
*)
	echo "usage: scripts/check.sh [--fence-only]" >&2
	exit 2
	;;
esac

# GitHub Actions (see "CI" above). ci_report TITLE TEXT raises TEXT as a notice
# annotation and appends it to the job summary; outside CI it does nothing.
# TITLE is a workflow-command property, so it must not contain ',' or ':'.
CI_RUN=""
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
	CI_RUN=1
fi
ci_report() {
	[[ -n "$CI_RUN" ]] || return 0
	echo "::notice title=$1::$2"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '**%s**: %s\n\n' "$1" "$2" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# --- 0. real mail stays out of this repository ----------------------------------
# These paths held the operator's real bank mail (and the expectations derived
# from it) until the repository went public; they now live only in
# salehtl/hasala-fixtures. A file reappearing here
# is real mail one push away from GitHub, so it fails the gate before anything
# runs. The synthetic families (edge-cases.json, synthetic-*.json, dns.json)
# are what belongs here. This step needs no fixtures and no toolchain and takes
# seconds, so it runs first, and `--fence-only` stops right after it: CI runs
# that on every push and pull request (job `secrets`), so the fence does not
# depend on the rest of the gate building.
step "real-mail fence"
leaked="$(
	cd "$ROOT"
	# A directory that does not exist (internal/origin and test/e2e were
	# deleted with the mail path) holds nothing, which is the passing case;
	# `|| true` keeps find's complaint about it from failing the pipeline.
	{
		find conformance/normalizer -type f ! -name edge-cases.json ! -name charset-tables.ts ! -name '.*' || true
		find conformance/templates -type f -name 'corpus-*' || true
		find conformance/templates/eml -type f || true
		find conformance/templates/sms -type f ! -name 'synthetic-*' ! -name '.*' || true
		find conformance -type f \( -ipath 'conformance/*sms*/*' -o -ipath 'conformance/*text*/*' \) \
			! -name 'synthetic-*' ! -name README.md ! -name '.*' || true
		find conformance/templates -path conformance/templates/sms -prune -o -type f ! -name '.*' \
			-exec grep -lE '\\?"channel\\?"[[:space:]]*:[[:space:]]*\\?"sms\\?"' {} + || true
		{
			find conformance -type f ! -name '.*' || true
			git ls-files -co --exclude-standard -- '*.json' '*.jsonl' '*.csv' '*.txt' || true
		} | sort -u | tr '\n' '\0' | xargs -0 grep -lE '\\?"note\\?"[[:space:]]*:[[:space:]]*\\?"PRIVATE:' /dev/null || true
		{
			find conformance -type f ! -name 'synthetic-*' ! -name '.*' || true
			git ls-files -co --exclude-standard -- '*.json' '*.jsonl' '*.csv' '*.txt' || true
		} | grep -v '/synthetic-[^/]*$' | sort -u | tr '\n' '\0' |
			xargs -0 grep -lE '\\?"read_by\\?"[[:space:]]*:|\\?"sender\\?"[[:space:]]*:[[:space:]]*\\?"DIB-SMS\\?"|^DIB-SMS,|,DIB-SMS(,|$)' /dev/null || true
		find server/internal/origin/testdata -type f ! -name dns.json ! -name '.*' || true
		find server/internal/tmpl/seed/testdata -type f ! -name '.*' || true
		git ls-files -co --exclude-standard -- ':(icase)*.eml' || true
	} 2>/dev/null | sort -u
)"
if [[ -n "$leaked" ]]; then
	echo "check: real bank mail or text fixtures are in the public tree; they belong in salehtl/hasala-fixtures:" >&2
	echo "$leaked" >&2
	exit 1
fi
unread="$(cd "$ROOT" && find conformance/templates/sms -mindepth 2 -type f ! -name '.*' 2>/dev/null | sort)"
if [[ -n "$unread" ]]; then
	echo "check: no template runner reads a subdirectory of conformance/templates/sms, so these cases would never run; move them into conformance/templates/sms itself:" >&2
	echo "$unread" >&2
	exit 1
fi
echo "no real-mail fixture or private expectation file in the public tree"
if [[ -n "$FENCE_ONLY" ]]; then
	exit 0
fi

step "real-mail fence self-test"
"$ROOT/scripts/tests/fence_test.sh"

# --- 0b. HasalaCore source lints ------------------------------------------------
# The import allowlist per directory (spec 04 §2.3, R1, R6), 01 AT-C11's source
# scan and the R2/R3/R7/R8 grep lints. The half of check-imports.sh that
# compares imports.allow with Package.swift needs `swift`; CI's `swift` job
# runs it. CI's `secrets` job also runs these two on every pull request, since
# `gate` is skipped on one that changes only ios/.
step "HasalaCore import and API lints"
"$ROOT/ios/scripts/check-imports.sh" --no-manifest
"$ROOT/ios/scripts/check-forbidden.sh"

# Spec 04 §4.6: the app's bundled templates are the server seed, byte for byte,
# and the same set of files. ios/tools/templates/sync.swift copies them and
# writes the SHA-256 manifest; this needs no toolchain, so drift fails the gate
# and not only the (non-required) swift job.
step "bundled templates equal the server seed"
bundled="$ROOT/ios/HasalaCore/Sources/HasalaCore/Resources/templates"
seed="$ROOT/server/internal/tmpl/seed"
if [ "$(cd "$bundled" && ls -1 ./*.json)" != "$(cd "$seed" && ls -1 ./*.json)" ]; then
  echo "the bundled template set differs from server/internal/tmpl/seed; run swift ios/tools/templates/sync.swift" >&2
  exit 1
fi
for f in "$seed"/*.json; do
  if ! cmp -s "$f" "$bundled/${f##*/}"; then
    echo "${f##*/} differs from the server seed; run swift ios/tools/templates/sync.swift" >&2
    exit 1
  fi
done
echo "$(ls -1 "$seed"/*.json | wc -l | tr -d ' ') templates identical"

GOLDEN_SETS=(authres categorize extract fx merchant-group norm-dates outlook-sender replay)
step "golden fixtures change only with a Swift test change"
cd "$ROOT"
if [[ -n "$CI_RUN" ]]; then
	golden_base="$(git rev-parse -q --verify 'HEAD^1' || true)"
else
	golden_base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
fi
if [[ -z "$golden_base" ]]; then
	echo "no base commit to compare with (CI: HEAD^1, locally: the merge base with origin/main); skipped"
else
	golden_paths=()
	for s in "${GOLDEN_SETS[@]}"; do golden_paths+=("conformance/$s"); done
	changed_since() { { git diff --name-only "$golden_base" -- "$@" && git ls-files --others --exclude-standard -- "$@"; } | sort -u; }
	golden_changed="$(changed_since "${golden_paths[@]}")"
	if [[ -n "$golden_changed" && -z "$(changed_since ios/HasalaCore/Tests)" ]]; then
		echo "check: golden fixtures changed since ${golden_base:0:12} with no change under ios/HasalaCore/Tests:" >&2
		sed 's/^/  /' <<<"$golden_changed" >&2
		echo "regenerate them with HASALA_UPDATE_GOLDEN=1 (conformance/README.md) and change the Swift test that pins the new behaviour" >&2
		exit 1
	fi
	echo "$(grep -c . <<<"$golden_changed" || true) golden fixture file(s) changed since ${golden_base:0:12}"
fi

cd "$ROOT/server"

# --- 1. toolchain floor ------------------------------------------------------
# go.mod's `go` line is the language version and does not stop an old compiler.
# The `toolchain` line is the patched floor: GO-2026-6090 (the TLS KeyUpdate DoS
# in the 2026-08-14 ledgerd security review, not published) and every later
# standard-library advisory govulncheck finds reachable. flake.nix provides exactly that
# Go, and the devShell pins GOTOOLCHAIN=local so nothing downloads another one.
step "toolchain"
want="$(sed -n 's/^toolchain go//p' go.mod)"
have="$(go env GOVERSION)"
have="${have#go}"
if [[ -z "$want" ]]; then
	echo "check: server/go.mod has no toolchain line" >&2
	exit 1
fi
if [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" != "$want" ]]; then
	echo "check: go $have is older than server/go.mod's toolchain go$want; run through the devShell" >&2
	exit 1
fi
echo "go $have (floor go$want)"

# --- 1b. the private fixtures, if this run has them -------------------------------
step "private fixtures (HASALA_PRIVATE_FIXTURES)"
if [[ -n "${HASALA_PRIVATE_FIXTURES:-}" ]]; then
	if [[ ! -d "$HASALA_PRIVATE_FIXTURES" ]]; then
		echo "check: HASALA_PRIVATE_FIXTURES=$HASALA_PRIVATE_FIXTURES is not a directory" >&2
		exit 1
	fi
	# Absolute, because go test runs each package from its own directory.
	HASALA_PRIVATE_FIXTURES="$(cd "$HASALA_PRIVATE_FIXTURES" && pwd -P)"
	# The exact private state this commit expects: every pinned file present and
	# unchanged, nothing unpinned. A partial or stale checkout fails here, before
	# any test can pass on whatever happens to be left.
	"$ROOT/scripts/private-fixtures-lock.sh" check "$HASALA_PRIVATE_FIXTURES"
	export HASALA_PRIVATE_FIXTURES
	echo "real-corpus tests will RUN against $HASALA_PRIVATE_FIXTURES"
else
	echo "HASALA_PRIVATE_FIXTURES is unset: real-corpus tests will SKIP (this run is not the full gate)"
fi

# --- 2. the hasalad fences ---------------------------------------------------------
# Spec 02 §4.4. The frozen v1 reference packages and the corpus gates live in
# server/oracle/, a separate Go module that server/go.mod does not require, so
# the server's build graph cannot reach them at all; cmd/hasalad/fence_test.go
# asserts that, and the rest of the fences (no test sealer, no oracle package,
# no retired capability, no encrypt or decrypt call, no review bypass). They
# need no database, so they run here, first and by name, before anything slow;
# step 4 runs them again with everything else.
step "hasalad fences"
go test -count=1 -run '^TestFence' ./cmd/hasalad

# --- 2b. no reachable vulnerability in the shipped binary ----------------------------
# Spec 02 §3.2. Only hasalad's own build graph, at symbol level: a finding in a
# module it requires but never calls is reported without failing. It reads the
# Go vulnerability database (vuln.go.dev), so this step needs the network. CI's
# `vuln` job scans every package of both modules, so CI skips this step.
step "govulncheck ./cmd/hasalad/..."
if [[ -n "$CI_RUN" ]]; then
	echo "skipped in CI: the vuln job runs govulncheck ./... in server/ and server/oracle/"
else
	govulncheck ./cmd/hasalad/...
fi

# --- 3. one throwaway Postgres cluster -------------------------------------------
PG_STOP=""
# The detached server inherits boot's stderr, so its log goes to a file rather
# than through this script's output. Kept, and named, only if the gate fails.
PG_LOG="$(mktemp "${TMPDIR:-/tmp}/hasala-check-pg.XXXXXX")"
# Real-corpus counts from step 4.
REAL_GO="$(mktemp)"
# Step 4's `go test -json` streams (server/ and server/oracle/), which step 6
# checks the conformance packages against, and step 6's `go test -list`. Step 6
# relies on step 4 running every test exactly as a run of its own would (only
# -count=1 and the KNOWN_FAILING -skip, which names top-level tests): a flag
# there that makes tests skip themselves, such as -short, would pass unseen.
GO_RECORD="$(mktemp)"
ORACLE_RECORD="$(mktemp)"
GO_LIST="$(mktemp)"
cleanup() {
	local status=$?
	if [[ -n "$PG_STOP" && -x "$PG_STOP" ]]; then
		"$PG_STOP" || true
	fi
	rm -f "$REAL_GO" "$GO_RECORD" "$ORACLE_RECORD" "$GO_LIST"
	if [[ "$status" -eq 0 ]]; then
		rm -f "$PG_LOG"
	else
		echo "check: FAILED; the postgres server log is at $PG_LOG" >&2
		# On a runner that file goes with the job (and with the devShell's
		# TMPDIR before that), so print it while it still exists.
		if [[ -n "$CI_RUN" && -s "$PG_LOG" ]]; then
			echo "::group::postgres server log"
			cat "$PG_LOG"
			echo "::endgroup::"
		fi
	fi
}
trap cleanup EXIT INT TERM

# Reap clusters a PREVIOUS run leaked. The EXIT trap cannot run on SIGKILL (the
# OOM killer), and on ledgerd's 4 GB box stranded clusters piled up for days.
# Only this user's orphans (parent gone, PPID 1) whose data directory is a
# pgtest- scratch directory under the temp dir are touched.
reap_orphaned_clusters() {
	local pid ppid dir reaped=0 tmp="${TMPDIR:-/tmp}"
	tmp="${tmp%/}"
	while read -r pid ppid dir; do
		[[ "$ppid" == 1 ]] || continue
		[[ "$dir" == "$tmp"/pgtest-*/data ]] || continue
		kill -QUIT "$pid" 2>/dev/null || true
		rm -rf "${dir%/data}" 2>/dev/null || true
		reaped=$((reaped + 1))
	done < <(ps -u "$(id -u)" -o pid=,ppid=,args= | awk '/postgres -D .*\/pgtest-/ {for (i=1;i<=NF;i++) if ($i=="-D") print $1, $2, $(i+1)}')
	if [[ "$reaped" -gt 0 ]]; then
		echo "check: reaped $reaped orphaned scratch cluster(s) from an earlier run"
	fi
	return 0
}

step "postgres"
reap_orphaned_clusters
# Captured, then checked: `eval "$(go run ...)"` alone would swallow a failed
# boot (empty stdout, eval "" succeeds) and every package would quietly boot
# its own cluster instead.
BOOT_OUT="$(go run ./internal/pgtest/cmd/boot 2>"$PG_LOG")" || {
	cat "$PG_LOG" >&2
	echo "check: failed to boot the postgres cluster (see the error above)" >&2
	exit 1
}
eval "$BOOT_OUT" # sets HASALA_TEST_POSTGRES_URL and PG_STOP
export HASALA_TEST_POSTGRES_URL
echo "cluster up (unix socket only; listen_addresses is empty)"

# --- 7 (declared here, used in 4). known failures ---------------------------------
# Tests that fail for a reason outside this change's reach. Each is skipped BY
# NAME in step 4 so the rest of the run stays a gate, and re-run on its own in
# step 7, where it must still fail: the day it passes, the gate fails until the
# entry is removed, so nothing healthy stays skipped. Format:
# "module dir (under server/)|package|regexp". The regexp names top-level tests
# only (no "/"): step 6 proves the conformance packages' tests ran in step 4 from
# `go test -list`, which lists top-level tests, so a subtest skipped here would
# go unseen there. A pattern with a slash fails the gate below.
#
# oracle/v1ref/store TestSelectMonthlyTotals is clock-dependent: it seeds
# June 2026 rows and asks SelectMonthlyTotals(3), whose window starts from
# time.Now(). June left that window on 2026-09-01, so the test fails on every
# machine from that date on, ledgerd's own checkout included. oracle/v1ref is
# byte-frozen reference code (see its README), so it is not "fixed" here.
# (`go test -skip` applies its pattern in every package; each name below is
# unique in both modules, so it skips exactly the one test.)
KNOWN_FAILING=(
	"oracle|./v1ref/store|^TestSelectMonthlyTotals\$"
)
skip_re="$(printf '%s\n' "${KNOWN_FAILING[@]}" | cut -d'|' -f3 | paste -sd'|' -)"
if [[ "$skip_re" == */* ]]; then
	echo "check: a KNOWN_FAILING regexp names a subtest ('/' in $skip_re); name top-level tests only (see above)" >&2
	exit 1
fi

# --- 4. go vet and go test -------------------------------------------------------
# -count=1 defeats the test cache: a cached pass from a previous cluster is not
# a run against this one.
step "go vet ./..."
go vet -p "$JOBS" ./...

step "go test ./... (known failures skipped by name: $skip_re)"
go test -count=1 -p "$JOBS" -skip "$skip_re" -json ./... 2>&1 | tee "$GO_RECORD" | REALCORPUS_COUNTS="$REAL_GO" bun "$ROOT/scripts/gotest-summary.ts"

# The oracle module (spec 02 §4.3): the frozen v1 reference packages and the
# corpus gates. Its real-corpus tests are counted with the server's.
REAL_ORACLE="$(mktemp)"
step "oracle: go vet ./... and go test ./..."
(
	cd oracle
	go vet -p "$JOBS" ./...
	go test -count=1 -p "$JOBS" -skip "$skip_re" -json ./... 2>&1 | tee "$ORACLE_RECORD" | REALCORPUS_COUNTS="$REAL_ORACLE" bun "$ROOT/scripts/gotest-summary.ts"
)
read -r s_ran s_skipped <"$REAL_GO"
read -r o_ran o_skipped <"$REAL_ORACLE"
rm -f "$REAL_ORACLE"
echo "$((s_ran + o_ran)) $((s_skipped + o_skipped))" >"$REAL_GO"

# --- 5. the assist worker -----------------------------------------------------------
# `--bun` runs node-shebang tools (tsc) on Bun, so nothing needs a host Node.
step "assist worker (infra/assist)"
cd "$ROOT/infra/assist"
if [[ ! -d node_modules ]]; then
	bun install --frozen-lockfile
fi
bun run --bun typecheck
bun test

# --- 6. conformance suites ------------------------------------------------------------
# Every fixture set under conformance/, with the Go packages that check it:
# "set|go packages (in server/)". The Go half already ran in step 4. It is
# checked again here by name because this table is the record of which tests
# make up each contract, so narrowing step 4 cannot quietly drop one, and
# because every directory under conformance/ must appear here: a new fixture
# set cannot land without saying what checks it.
#
# The Go half is not run a second time (it was the slowest part of this step:
# internal/api again, for the same verdict against the same cluster). Instead
# `go test -list` names every test of each package in the table, and
# scripts/gotest-ran.ts requires each package to have passed in step 4's record
# and each of those tests to have a result there (pass, or its own skip). A
# package left out of step 4, or one of its tests that step 4 did not run (a
# -run, a -skip, a KNOWN_FAILING pattern that also matches it), fails here.
#
# The Swift port (HasalaCore's HasalaCoreConformanceTests, CI's `swift` job)
# reads every set. Some sets have no Go executor, on purpose and visibly:
#   authres, categorize, extract, fx, merchant-group, norm-dates, outlook-sender, replay
#           Golden files. The ledgerd TypeScript reference wrote them; the
#           Swift tests now own their expected output and rewrite it with
#           HASALA_UPDATE_GOLDEN=1 (conformance/README.md), and the step
#           "golden fixtures change only with a Swift test change" refuses a
#           branch that changes one of them without touching
#           ios/HasalaCore/Tests. Go has no reader: the server never reads
#           mail or folds ops.
#   swift   Written by the Swift executor (HasalaCore's SwiftGoldenTests and
#           SwiftFoldGoldenTests); Go opens and verifies the crypto half once
#           WS-2's reader lands (spec 01 §15.2 step 2).
#   crypto-v3, api-v1  Go writes them (cmd/gen-crypto-vectors, spec 01 §15.1,
#           spec 02 §22) and checks them: the committed files must regenerate
#           byte for byte, the anchors A01–A26 reproduce, the predicate cases
#           agree with Postgres, and every tamper upload gets its verdict from
#           the real handler. Swift (GoCryptoV3Tests) reads them and never
#           writes them. ledgerd's encv2 set (conformance/crypto/, with a
#           committed private key) is deleted (spec 01 §15.1).
#
# A Go package under ./oracle/ is run from the oracle module.
CONFORMANCE=(
	"api-v1|./cmd/gen-crypto-vectors ./internal/cryptoref"
	"authres|"
	"blob|./internal/oplog/opref"
	"categorize|"
	"crypto-v3|./cmd/gen-crypto-vectors ./internal/cryptoref ./internal/pg ./internal/api"
	"dialect|./internal/tmpl"
	"dict|./internal/dict"
	"extract|"
	"fx|"
	"import|./oracle/v1ref/importer"
	"merchant-group|"
	"norm-dates|"
	"normalizer|./internal/norm"
	"op|./internal/oplog/opref"
	"outlook-sender|"
	"replay|"
	"swift|"
	"templates|./internal/tmpl"
	"ts|./internal/oplog/opref"
)
step "conformance"
cd "$ROOT"
listed="$(printf '%s\n' "${CONFORMANCE[@]}" | cut -d'|' -f1 | sort)"
on_disk="$(cd conformance && for d in */; do echo "${d%/}"; done | sort)"
if [[ "$listed" != "$on_disk" ]]; then
	echo "check: conformance/ and the CONFORMANCE table in scripts/check.sh disagree" >&2
	echo "(< table, > conformance/):" >&2
	diff <(echo "$listed") <(echo "$on_disk") >&2 || true
	exit 1
fi
go_pkgs="$(printf '%s\n' "${CONFORMANCE[@]}" | cut -d'|' -f2 | tr ' ' '\n' | awk 'NF' | sort -u)"
for entry in "${CONFORMANCE[@]}"; do
	IFS='|' read -r set go <<<"$entry"
	printf '  %-14s go: %s\n' "$set" "${go:-(none)}"
done
server_pkgs="$(grep -v '^\./oracle/' <<<"$go_pkgs" || true)"
oracle_pkgs="$(grep '^\./oracle/' <<<"$go_pkgs" | sed 's|^\./oracle/|./|' || true)"
# shellcheck disable=SC2086 # word splitting is the point: one package/file per word
(cd server && go test -count=1 -p "$JOBS" -json -list . $server_pkgs) >"$GO_LIST"
if [[ -n "$oracle_pkgs" ]]; then
	# shellcheck disable=SC2086
	(cd server/oracle && go test -count=1 -p "$JOBS" -json -list . $oracle_pkgs) >>"$GO_LIST"
fi
bun "$ROOT/scripts/gotest-ran.ts" "$GO_LIST" "$GO_RECORD" "$ORACLE_RECORD"

# --- 7. known failures still fail -------------------------------------------------------
# A build error must not pass for "still failing": the named test has to have
# run and reported FAIL.
step "known failures"
cd "$ROOT/server"
for entry in "${KNOWN_FAILING[@]}"; do
	IFS='|' read -r mod pkg re <<<"$entry"
	if out="$(cd "$ROOT/server/$mod" && go test -count=1 -v -run "$re" "$pkg" 2>&1)"; then
		echo "check: $pkg $re now PASSES; remove it from KNOWN_FAILING in scripts/check.sh" >&2
		exit 1
	fi
	if ! grep -q -- '^--- FAIL: ' <<<"$out"; then
		printf '%s\n' "$out" >&2
		echo "check: $pkg $re did not run to a FAIL (see above); it is not the recorded failure" >&2
		exit 1
	fi
	echo "still failing, as recorded: $pkg $re"
	{ grep -E '^\s+\S+_test\.go:[0-9]+:' <<<"$out" || true; } | sed 's/^/    /'
done

# --- the real corpus, accounted for -----------------------------------------------
read -r go_ran go_skipped <"$REAL_GO"
corpus="go ${go_ran} ran / ${go_skipped} skipped"
echo
echo "real corpus: $corpus"
if [[ -n "${HASALA_PRIVATE_FIXTURES:-}" ]]; then
	if [[ "$go_skipped" -ne 0 || "$go_ran" -eq 0 ]]; then
		echo "check: HASALA_PRIVATE_FIXTURES is set, so every real-corpus test must run and none may skip" >&2
		exit 1
	fi
	echo "check: OK (real-mail fence, toolchain, fence, govulncheck, go vet, go test, assist worker, conformance; real corpus included)"
	ci_report "Real corpus included" "$corpus."
else
	echo "check: OK (real-mail fence, toolchain, fence, govulncheck, go vet, go test, assist worker, conformance)"
	echo "check: WITHOUT the real corpus: HASALA_PRIVATE_FIXTURES is unset, so the tests above that read real bank mail were skipped"
	ci_report "Real corpus skipped" "$corpus. HASALA_PRIVATE_FIXTURES is unset, so every test that reads real bank mail skipped by name (listed in the log); this run is the gate without the real corpus."
fi
