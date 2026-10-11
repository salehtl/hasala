# conformance/categorize

On-device categorization as the v3 matcher does it: canonicalization, the
order of user rules and dictionary entries, the load-time gates, and the
decision for a merchant. The TypeScript reference client
(`reference/ledgerd-client/src/categorize`) is the oracle; the Swift port
(Categorize) must reproduce every vector. All strings are synthetic.

`conformance/dict/matching.json`, written by Go, already pins Go's whitespace
set, lower-casing, canonical forms and the exact/contains test. This suite pins
what only the client does.

Regenerate (never hand-edit):

```sh
cd reference/ledgerd-client && bun run gen-categorize-conformance
bun run gen-categorize-conformance --check   # compare only, exit 1 if stale
```

Generation is deterministic; `src/categorize/oracle-conformance.test.ts` fails
when the committed files differ from what the generator writes, and runs in
`scripts/check.sh`.

Strings are written with every non-ASCII code point escaped as `\uXXXX`.
Lengths ("runes") are Unicode scalar values, never UTF-16 units or grapheme
clusters. Equality and containment are by scalar sequence: no Unicode
normalization (NFC and NFD forms are different strings).

## `canon.json`

`vectors[]`: `{name, input, expect: {canonical, fold_case, rune_length, subject}}`

- `canonical`: split on Go's `unicode.IsSpace` set, rejoin with one U+0020,
  then `fold_case`.
- `fold_case`: per scalar, the first scalar of its lower-case mapping (Go's
  simple mapping: U+0130 becomes `i`, final sigma stays U+03C3).
- `rune_length`: scalars in `input`.
- `subject`: `canonical(input)` truncated to `max_subject_runes` (512) scalars,
  which is what every rule and dictionary entry is matched against.

## `order.json`

`cases[]`: `{name, note, rules, entries, expect}`

- `rules`: user rules `{id, pattern, match, category, priority}` in input order.
- `entries`: dictionary entries `{pattern, match, category}` in input order.
- `expect.rules`, `expect.entries`: what survives the gates, in match order,
  each `{id, pattern, match, category, priority}` with the canonical pattern
  (regex patterns are not canonicalized) and category. A dictionary entry's id
  is `"<match> <pattern>"` and its priority 0.
- `expect.defects`: the refused rules and entries, in input order (rules
  first): `{id, code}` plus `reasons` (the dialect's reason codes) for a regex.
- `expect.decisions`: `{merchant, decision}` where `decision` is
  `{category, source: "rule", id, pattern, match}`,
  `{category, source: "dictionary", pattern, match}` or
  `{category: null, source: "none"}`.

Match order: priority ascending (lower wins), then `match_order`
(`exact` 0, `contains` 1, `regex` 2), then the longer pattern in scalars, then
pattern, category and id compared by scalar value. Every user rule precedes
every dictionary entry. Regex rules use the template dialect with flag `i`; the
patterns here are simple ASCII ones, so engine differences do not arise (the
dialect suites pin the engine).

## `dictionary.json`

- `entries[]`: `{name, entry, expect}` where `expect` is
  `{ok: true, entry: <canonical entry>}` or
  `{ok: false, defect: {id, code}}` (`validateDictEntry`).
- `lookups`: one synthetic dictionary prepared with no user rules:
  `expect.entries` (match order), `expect.defects`, and a decision per merchant.

Version note: `pattern_unprintable` (general category C) and the
alphanumeric test (categories L and N) depend on the Unicode version. Every
code point here has been assigned for many Unicode versions, so the oracle's and
the port's tables agree on all of them.
