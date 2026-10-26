#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/pristine/scripts" "$work/pristine/conformance"
cp "$ROOT/scripts/check.sh" "$work/pristine/scripts/check.sh"
for d in normalizer templates; do
	if [[ -d "$ROOT/conformance/$d" ]]; then
		cp -R "$ROOT/conformance/$d" "$work/pristine/conformance/$d"
	fi
done
git -C "$work/pristine" init -q

cases=0
failures=0

fresh() {
	rm -rf "$work/t"
	cp -R "$work/pristine" "$work/t"
}

plant() {
	mkdir -p "$work/t/$(dirname "$1")"
	printf '%s\n' "$2" >"$work/t/$1"
}

fence() {
	bash "$work/t/scripts/check.sh" --fence-only >/dev/null 2>&1
}

refuses() {
	cases=$((cases + 1))
	fresh
	plant "$1" "$2"
	if fence; then
		echo "fence self-test: the fence let $1 through" >&2
		failures=$((failures + 1))
	fi
}

allows() {
	cases=$((cases + 1))
	fresh
	plant "$1" "$2"
	if ! fence; then
		echo "fence self-test: the fence refused $1" >&2
		failures=$((failures + 1))
	fi
}

cases=$((cases + 1))
fresh
if ! fence; then
	echo "fence self-test: the fence refuses this checkout's own conformance/templates and conformance/normalizer" >&2
	failures=$((failures + 1))
fi

sms_spaced='{"template": "x", "definition": {"id": "x", "channel": "sms"}}'
sms_compact='{"template":"x","definition":{"id":"x","channel":"sms"}}'
sms_escaped='{"definition": "{\"id\":\"x\",\"channel\":\"sms\"}"}'
mail='{"template": "x", "definition": {"id": "x", "match": {"sender_domain": ["example.com"]}}}'

for dir in conformance/templates/sms conformance/sms-extract conformance/sms-later conformance/sms; do
	refuses "$dir/corpus-1.json" "$sms_spaced"
	refuses "$dir/x.json" '{}'
	refuses "$dir/nested/x.json" '{}'
done
refuses conformance/templates/sms/README.md '# x'
refuses conformance/templates/sms/nested/synthetic-x.json "$sms_spaced"
refuses conformance/templates/sms/dib/synthetic-dib-sms-x.json "$sms_compact"
refuses conformance/templates/sms/a/b/synthetic-x.json "$sms_spaced"
refuses conformance/templates/x.json "$sms_spaced"
refuses conformance/templates/synthetic-x.json "$sms_spaced"
refuses conformance/templates/synthetic-x.json "$sms_compact"
refuses conformance/templates/synthetic-x.json "$sms_escaped"
refuses conformance/templates/other/synthetic-x.json "$sms_spaced"
refuses conformance/templates/corpus-1.json "$mail"
refuses conformance/templates/eml/x.eml 'x'
refuses conformance/normalizer/x.json '{}'
refuses conformance/x.eml 'x'

corpus_case='{"cases": [{"name": "x", "sender": "DIB-SMS", "text_base64": "eA==", "read_by": "", "gated": []}]}'
private_note='{"note": "PRIVATE: x", "cases": []}'

for dir in conformance/text-extract conformance/bank-texts conformance/SMS-later conformance/extract/sms conformance/templates/texts; do
	refuses "$dir/x.json" '{}'
	refuses "$dir/corpus-1.json" "$corpus_case"
done
refuses conformance/normalizer/edge-cases.json '{"text_cases": [{"name": "x", "read_by": "dib.sms.debit.v1"}]}'
refuses conformance/dialect/patterns.json "$private_note"
refuses conformance/extract/cases.json "$corpus_case"
refuses conformance/extract/cases.json '{"sender":"DIB-SMS"}'
refuses conformance/extract/cases.json '{"definition": "{\"read_by\":\"x\"}"}'
refuses conformance/extract/cases.txt 'DIB-SMS,2026-06-05,x'
refuses conformance/templates/sms/synthetic-x.json "$private_note"
refuses ios/HasalaCore/Tests/Fixtures/texts.json '{"rows": [{"ts": "x", "sender": "DIB-SMS", "text": "x"}]}'
refuses server/internal/x/testdata/texts.json '{"read_by": "x"}'
refuses web/x.csv '1,DIB-SMS,x'

allows conformance/text-extract/synthetic-x.json '{"sender": "DIB-SMS"}'
allows conformance/text-extract/README.md '# x'
allows conformance/extract/cases.json '{"sender_domain": ["dib.ae"], "sender": "AD-Bank"}'
allows ios/x/dib.sms.x.v1.json '{"match": {"sms_sender": ["DIB-SMS"]}}'
allows conformance/templates/sms/synthetic-x.json "$sms_spaced"
allows conformance/sms-extract/synthetic-x.json '{}'
allows conformance/sms-extract/README.md '# x'
allows conformance/templates/synthetic-x.json "$mail"
allows conformance/templates/x.json "$mail"

if ((failures > 0)); then
	echo "fence self-test: $failures of $cases cases failed" >&2
	exit 1
fi
echo "fence self-test: $cases cases"
