#!/usr/bin/env bash
# The release scripts inside the repository's Nix devShell (.envrc: use flake), where
# GNU coreutils, grep, sed and findutils come first on PATH: GNU `stat -f` and
# `date -j -f` once broke asc-env.sh, build_number.sh and archive.sh there. Runs
# every release-script test (build_number_test.sh, upload_precheck_test.sh and the
# rest, through run.sh) under `nix develop -c`, after checking that the shell really
# puts GNU stat and date first, so a pass means something.
#
#   ios/scripts/tests/devshell_test.sh
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$tests/../../.." && pwd)"
nix="$(command -v nix || echo /nix/var/nix/profiles/default/bin/nix)"
if [[ ! -x "$nix" ]]; then
	echo "FAIL nix is not installed; this test needs the repository's devShell"
	exit 1
fi
if ! "$nix" develop "$repo" --command bash -c 'stat --version && date --version' >/dev/null 2>&1; then
	echo "FAIL the devShell does not put GNU stat and date first on PATH; this test would prove nothing"
	exit 1
fi
echo "ok   the devShell puts GNU stat and date first on PATH"
"$nix" develop "$repo" --command "$tests/run.sh"
