# asc-env.sh: sourced by archive.sh and upload.sh. Resolves the App Store Connect
# API key from the environment only; nothing about the key is ever committed.
#
#   ASC_KEY_ID      key id (e.g. the Mac's upload key)            required
#   ASC_ISSUER_ID   issuer id                                     required
#   ASC_KEY_PATH    path to AuthKey_<ASC_KEY_ID>.p8, mode 0600    default:
#                   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#
# If ASC_KEY_ID or ASC_ISSUER_ID is unset and ~/.config/hasala/asc.env exists, it is
# sourced first (spec 06 §9 keeps the two ids there, mode 0600). The ids are not
# secrets; the .p8 is, and it never leaves its file.

asc_resolve_key() {
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]] && [[ -f "$HOME/.config/hasala/asc.env" ]]; then
		# shellcheck disable=SC1091
		source "$HOME/.config/hasala/asc.env"
	fi
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
		echo "set ASC_KEY_ID and ASC_ISSUER_ID (or create ~/.config/hasala/asc.env)" >&2
		return 14
	fi
	ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
	if [[ ! -f "$ASC_KEY_PATH" ]]; then
		echo "no API key file at $ASC_KEY_PATH" >&2
		return 14
	fi
	local mode
	mode="$(stat -f '%Lp' "$ASC_KEY_PATH")"
	if [[ "$mode" != "600" && "$mode" != "400" ]]; then
		echo "$ASC_KEY_PATH has mode $mode; make it 0600 (chmod 600)" >&2
		return 14
	fi
	local repo keydir
	repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
	keydir="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
	if [[ -n "$repo" && "$keydir/" == "$(cd "$repo" && pwd -P)/"* ]]; then
		echo "$ASC_KEY_PATH is inside the repository; keep keys outside it" >&2
		return 14
	fi
	export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
}
