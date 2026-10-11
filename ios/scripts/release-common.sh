# shellcheck shell=bash
# release-common.sh: sourced by archive.sh and upload.sh (and the script tests).
# Pure helpers only: nothing here touches the network, a key or the keychain.

# The file archive.sh writes beside summary.txt when the archive is a local trial
# (--allow-dirty or --allow-branch). upload.sh refuses any build that has it.
# shellcheck disable=SC2034 # read by the scripts that source this file
HASALA_TRIAL_MARKER="TRIAL"

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
