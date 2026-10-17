#!/usr/bin/env bash
# check-bundle.sh: what a built Hasala.app may carry (spec 04 §1's bundle content check,
# AT-PROJ-5 and AT-REV-4; spec 06 I6b). inspect-ipa.sh runs it on every exported .ipa
# (I6b); run it by hand, or in CI, on a build product.
#
#   ios/scripts/check-bundle.sh <Hasala.app | Hasala.xcarchive | Hasala.ipa>
#
# It fails when the app holds:
#   - a path with a `conformance` component, an .eml file, or a corpus-* or
#     manifest.synthetic* file (test and private data);
#   - a file larger than 5 MB (5,000,000 bytes) that is not code (a Mach-O), a font or
#     the merchant dictionary;
#   - anywhere in its files, a string shaped like an Outlook message id: Graph's default
#     REST id (`A[AQ]MkAD` + 40 or more base64url characters) or its immutable id
#     (`AAkALgAA` + 40 or more), real mail's ids leaking into a resource;
#   - a sample seed that is not the committed one: HasalaCore's CoreResources bundle
#     must hold sample/maya-v1.json, whose SHA-256 must be golden/maya-v1.sha256's,
#     which must be SampleManifest.sha256 (the digest the generator wrote and the app
#     checks before it loads the seed), and the seed must be synthetic: no email
#     address but review@hasala.app, and no message id but the generator's placeholders
#     (@message:<name>, rewritten to sample-<n> at load), so no Gmail or Outlook message id.
#
# Exit 0 when the bundle passes, 1 when a check fails (each failure is named on stderr),
# 2 on bad arguments. Fails closed: a file that is missing or a tool that fails is a
# failure. Offline; macOS tools by absolute path, so it also runs in the Nix devShell.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

golden="$here/golden/maya-v1.sha256"
manifest="$ios/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift"
seed_path="HasalaCore_CoreResources.bundle/sample/maya-v1.json"
limit=5000000

usage() {
	echo "usage: check-bundle.sh <Hasala.app | Hasala.xcarchive | Hasala.ipa>" >&2
	exit 2
}
(($# == 1)) || usage
target="${1%/}"

work="$(mktemp -d "${TMPDIR:-/tmp}/hasala-check-bundle.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work" || true' EXIT

case "$target" in
*.app) app="$target" ;;
*.xcarchive) app="$target/Products/Applications/Hasala.app" ;;
*.ipa)
	[[ -f "$target" ]] || usage
	if ! unzip -q "$target" -d "$work/x"; then
		echo "check-bundle: cannot unzip $target" >&2
		exit 1
	fi
	app="$work/x/Payload/Hasala.app"
	;;
*) usage ;;
esac
if [[ ! -d "$app" || ! -f "$app/Info.plist" ]]; then
	echo "check-bundle: no app at $app" >&2
	exit 1
fi

failed=0
fail() {
	echo "check-bundle: $1" >&2
	failed=1
}

# --- test and private data ---------------------------------------------------------------
if ! find "$app" \( -name conformance -o -path '*/conformance/*' -o -iname '*.eml' -o -name 'corpus-*' \
	-o -name 'manifest.synthetic*' \) -print >"$work/forbidden.txt"; then
	fail "cannot list $app"
elif [[ -s "$work/forbidden.txt" ]]; then
	fail "test or private data in the bundle:"
	sed "s|^$app/|    |" "$work/forbidden.txt" >&2
fi

# --- large files -------------------------------------------------------------------------
if ! find "$app" -type f -size +"$limit"c -print0 >"$work/large.bin"; then
	fail "cannot list the large files in $app"
else
	while IFS= read -r -d '' f; do
		case "${f##*/}" in
		*.ttf | *.otf | *.ttc | merchant-dictionary.json) continue ;;
		esac
		hasala_is_macho "$f" && continue
		fail "${f#"$app/"} is larger than 5 MB and is not code, a font or the merchant dictionary"
	done <"$work/large.bin"
fi

# --- Outlook message ids -----------------------------------------------------------------
outlook_id='A[AQ]MkAD[A-Za-z0-9_=-]{40,}|AAkALgAA[A-Za-z0-9_=-]{40,}'
rc=0
grep -rlaE -- "$outlook_id" "$app" >"$work/outlook.txt" 2>"$work/outlook.err" || rc=$?
if ((rc == 0)); then
	fail "a string shaped like an Outlook message id in:"
	sed "s|^$app/|    |" "$work/outlook.txt" >&2
elif ((rc != 1)); then
	fail "cannot search $app for Outlook message ids"
fi

# --- the sample seed (I6b) ---------------------------------------------------------------
seed="$app/$seed_path"
want=""
if [[ ! -f "$golden" ]] || ! want="$(head -n 1 -- "$golden")" || [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
	fail "golden/maya-v1.sha256 is missing or is not one SHA-256 in hex"
	want=""
fi
pinned=""
if [[ -f "$manifest" ]]; then
	line="$(grep -E '^[[:space:]]*public static let sha256 = "[0-9a-f]{64}"' -- "$manifest" || true)"
	[[ "$line" =~ \"([0-9a-f]{64})\" ]] && pinned="${BASH_REMATCH[1]}"
fi
if [[ -z "$pinned" ]]; then
	fail "cannot read SampleManifest.sha256 from ${manifest#"$ios/"}"
elif [[ -n "$want" && "$want" != "$pinned" ]]; then
	fail "golden/maya-v1.sha256 ($want) is not SampleManifest.sha256 ($pinned); regenerate the seed (HASALA_WRITE_SAMPLE=1) and update both"
fi
if [[ ! -f "$seed" ]]; then
	fail "the sample seed $seed_path is missing"
else
	if ! got="$(hasala_sha256 "$seed")"; then
		fail "cannot hash $seed_path"
	elif [[ -n "$want" && "$got" != "$want" ]]; then
		fail "$seed_path has SHA-256 $got, not golden/maya-v1.sha256's $want"
	fi
	if ! /usr/bin/python3 -I - "$seed" <<'PY'; then
import json, re, sys

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
GMAIL_ID = re.compile(r"[0-9a-f]{16}")
OUTLOOK_ID = re.compile(r"A[AQ]MkAD[A-Za-z0-9_=-]{40,}|AAkALgAA[A-Za-z0-9_=-]{40,}")
bad = []

def walk(v, key=None):
    if isinstance(v, dict):
        for k, x in v.items():
            walk(x, k)
    elif isinstance(v, list):
        for x in v:
            walk(x, key)
    elif isinstance(v, str):
        for m in EMAIL.finditer(v):
            if m.group(0) != "review@hasala.app":
                bad.append(f"an email address in {key}")
        if key == "message_id" and not (v.startswith("@message:") or v.startswith("sample-")):
            bad.append(f"message_id {v!r} is not a placeholder")
        if GMAIL_ID.fullmatch(v):
            bad.append(f"{key} looks like a Gmail message id")
        if OUTLOOK_ID.search(v):
            bad.append(f"{key} looks like an Outlook message id")

try:
    with open(sys.argv[1], "rb") as f:
        doc = json.load(f)
except Exception as e:
    print(f"    not JSON: {type(e).__name__}", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict) or doc.get("format") != "hasala.sample" or not isinstance(doc.get("ops"), list):
    bad.append("not a hasala.sample document with ops")
walk(doc)
for b in sorted(set(bad)):
    print("    " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
		fail "$seed_path is not synthetic (above)"
	fi
fi

if ((failed)); then
	exit 1
fi
echo "check-bundle: ok (no test data, no oversized resources, no Outlook message ids, the sample seed is golden/maya-v1.sha256)"
