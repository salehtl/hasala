#!/usr/bin/env bash
# Runs every release-script test in this directory (each *_test.sh but
# devshell_test.sh, which runs this file inside the Nix devShell) and fails if any
# failed. Offline; see each test for what it fakes.
#
#   ios/scripts/tests/run.sh
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "release-script tests with $(command -v bash) ($BASH_VERSION), stat=$(command -v stat), date=$(command -v date)"
failed=()
for t in "$tests"/*_test.sh; do
	[[ "${t##*/}" == devshell_test.sh ]] && continue
	echo "== ${t##*/}"
	if ! "$t"; then failed+=("${t##*/}"); fi
done
if ((${#failed[@]})); then
	echo "FAILED: ${failed[*]}"
	exit 1
fi
echo "all release-script tests passed"
