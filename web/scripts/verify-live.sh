#!/usr/bin/env bash
# Checks the live site after a deploy (CLAUDE.md, "Website"): the security
# headers, one CSP per page, Web Analytics shut out of the pages whose address
# carries a code or a token, the AASA file and the 404 page. Exits non-zero,
# naming every check that failed.
#
#   web/scripts/verify-live.sh [base URL, default https://hasala.app]
set -euo pipefail

base="${1:-https://hasala.app}"
base="${base%/}"
failed=0

fail() {
  echo "FAIL $*" >&2
  failed=1
}
ok() { echo "ok   $*"; }
# check OK-MESSAGE FAIL-MESSAGE TEST...: runs TEST (a `[` expression).
check() {
  local good="$1" bad="$2"
  shift 2
  if "$@"; then ok "$good"; else fail "$bad"; fi
}

# headers PATH: the response headers of one request, redirects not followed,
# lowercased and without CRs. Retries transient network errors.
headers() {
  curl -sS -D- -o /dev/null --max-redirs 0 --retry 3 --retry-all-errors "$base$1" |
    tr -d '\r' | tr '[:upper:]' '[:lower:]'
}
status() { head -n1 <<<"$1" | awk '{print $2}'; }
count() { grep -c -- "$1" <<<"$2" || true; }

expect_status() { # PATH WANT HEADERS
  local got
  got="$(status "$3")"
  if [[ "$got" == "$2" ]]; then ok "$1: $got"; else fail "$1: status $got, want $2"; fi
}

# /: security headers and exactly one CSP, as header and as <meta>.
h="$(headers /)"
expect_status / 200 "$h"
for name in strict-transport-security permissions-policy; do
  check "/: $name" "/: no $name header" [ "$(count "^$name:" "$h")" -ge 1 ]
done
csp="$(grep '^content-security-policy:' <<<"$h" || true)"
if [[ "$(count . "$csp")" -eq 1 && "$csp" == *"frame-ancestors 'none'"* ]]; then
  ok "/: one content-security-policy header, frame-ancestors 'none'"
else
  fail "/: want one content-security-policy header with frame-ancestors 'none', got: ${csp:-none}"
fi
metas="$(curl -sS --retry 3 --retry-all-errors "$base/" | grep -c 'http-equiv="content-security-policy"' || true)"
check "/: one CSP <meta>" "/: $metas CSP <meta> tags, want 1" [ "$metas" -eq 1 ]

# The legal pages, and their trailing-slash redirect.
expect_status /privacy 200 "$(headers /privacy)"
h="$(headers /privacy/)"
loc="$(grep '^location:' <<<"$h" | awk '{print $2}' || true)"
if [[ "$(status "$h")" == 30[178] && ( "$loc" == /privacy || "$loc" == "$base/privacy" ) ]]; then
  ok "/privacy/: redirects to /privacy"
else
  fail "/privacy/: status $(status "$h"), location ${loc:-none}, want a redirect to /privacy"
fi

# Pages whose address carries a code or a token: no Web Analytics.
for path in /i/test /freeze /waitlist/confirm; do
  h="$(headers "$path")"
  expect_status "$path" 200 "$h"
  csp="$(grep '^content-security-policy:' <<<"$h" || true)"
  if [[ "$(count . "$csp")" -eq 1 && "$csp" == *script-src* && "$csp" == *connect-src* &&
    "$csp" == *"frame-ancestors 'none'"* && "$csp" != *cloudflareinsights* ]]; then
    ok "$path: one CSP header, no Web Analytics"
  else
    fail "$path: want one CSP header with script-src, connect-src and frame-ancestors 'none' and no cloudflareinsights, got: ${csp:-none}"
  fi
  if [[ "$path" == /i/test ]]; then
    check "$path: cache-control no-store" "$path: no cache-control: no-store" \
      [ "$(count '^cache-control: no-store' "$h")" -ge 1 ]
    n="$(count '^referrer-policy: no-referrer$' "$h")"
    check "$path: one referrer-policy no-referrer" "$path: $n referrer-policy: no-referrer headers, want 1" \
      [ "$n" -eq 1 ]
  fi
done

# The AASA file: served directly, as JSON.
h="$(headers /.well-known/apple-app-site-association)"
expect_status /.well-known/apple-app-site-association 200 "$h"
check "AASA: application/json" "AASA: content-type is not application/json" \
  [ "$(count '^content-type: application/json' "$h")" -ge 1 ]

expect_status /no-such-page 404 "$(headers /no-such-page)"

if ((failed)); then
  echo "live checks failed for $base" >&2
  exit 1
fi
echo "live checks passed for $base"
