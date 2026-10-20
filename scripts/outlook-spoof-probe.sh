#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: scripts/outlook-spoof-probe.sh --server HOST[:PORT] --auth-user USER --from-domain DOMAIN --to ADDRESS

Prints a swaks command for the C3 spoof probe of docs/decisions/outlook-mailbox.md.
It sends nothing. Run the printed command yourself; swaks asks for the SMTP password.

  --server       your SMTP submission server (port 587 uses STARTTLS, 465 uses TLS)
  --auth-user    your SMTP login
  --from-domain  a domain you control; the probe comes from hasala-probe@DOMAIN
  --to           the Outlook.com test address
EOF
	exit 64
}

server="" user="" domain="" to=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--server) server="${2:-}" ;;
	--auth-user) user="${2:-}" ;;
	--from-domain) domain="${2:-}" ;;
	--to) to="${2:-}" ;;
	*) usage ;;
	esac
	[[ $# -ge 2 ]] || usage
	shift 2
done
[[ -n "$server" && -n "$user" && -n "$domain" && -n "$to" ]] || usage

ldh='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
host="${server%:*}"
port="587"
[[ "$server" == *:* ]] && port="${server##*:}"
host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"

[[ "$domain" =~ $ldh ]] || { echo "outlook-spoof-probe: --from-domain is not a domain name" >&2; exit 64; }
[[ "$host" =~ $ldh ]] || { echo "outlook-spoof-probe: --server is not HOST or HOST:PORT" >&2; exit 64; }
[[ "$port" =~ ^[0-9]{1,5}$ ]] || { echo "outlook-spoof-probe: the port is not a number" >&2; exit 64; }
[[ "$user" =~ ^[A-Za-z0-9._%+@-]{1,128}$ ]] || { echo "outlook-spoof-probe: --auth-user has unexpected characters" >&2; exit 64; }
[[ "$to" =~ ^[A-Za-z0-9._%+-]{1,64}@(outlook|hotmail|live|msn)\.[a-z.]{2,8}$ ]] || {
	echo "outlook-spoof-probe: --to must be an Outlook.com consumer address (outlook, hotmail, live or msn)" >&2
	exit 64
}
case "$domain" in
*bank* | *outlook.com | *microsoft.com | *google.com) echo "outlook-spoof-probe: use a domain you own, not a bank's or a provider's" >&2; exit 64 ;;
esac

tls="--tls"
[[ "$port" == "465" ]] && tls="--tls-on-connect"

body='This is a synthetic Hasala trust test (check C3 of docs/decisions/outlook-mailbox.md).
It is not from a bank, it is not a transaction alert, and it carries no account or amount.
It adds forged authentication headers on purpose, to see what Outlook.com keeps.
Delete it after you export it.'

cmd=(
	swaks
	--server "$host" --port "$port" "$tls"
	--auth --auth-user "$user"
	--from "hasala-probe@$domain"
	--to "$to"
	--header "Subject: HASALA C3 SPOOF PROBE (synthetic test, not a bank alert)"
	--header "From: Hasala probe <hasala-probe@$domain>"
	--add-header "Authentication-Results: spf=pass smtp.mailfrom=bank.example; dkim=pass header.d=bank.example; dmarc=pass action=none header.from=bank.example; compauth=pass reason=100"
	--add-header "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example"
	--add-header "X-MS-Exchange-Organization-AuthAs: Internal"
	--add-header "X-MS-Exchange-Organization-AuthSource: relay.evil.example"
	--body "$body"
)

echo "# C3 spoof probe: review it, then run it yourself. swaks will ask for the SMTP password."
echo "# Then export the message from Outlook on the web into ~/hasala-private/outlook-trust/spoof/"
echo "# and run: scripts/outlook-trust-check.sh --expect untrusted ~/hasala-private/outlook-trust/spoof"
quote() {
	if [[ "$1" =~ ^[A-Za-z0-9@._:/=+-]+$ ]]; then
		printf '%s' "$1"
	else
		printf "'%s'" "${1//\'/\'\\\'\'}"
	fi
}
first=1
for a in "${cmd[@]}"; do
	if [[ $first -eq 1 ]]; then
		quote "$a"
		first=0
	elif [[ "$a" == --* ]]; then
		printf ' \\\n  '
		quote "$a"
	else
		printf ' '
		quote "$a"
	fi
done
printf '\n'
