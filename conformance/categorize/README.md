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

The expected output is also a golden file: the Swift test rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`).

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

`cases[]`: `{name, note, requires?, rules, entries, expect}`

- `requires`: present as `["regex"]` exactly when a user rule in the case has
  `match: "regex"`. Such a case needs a regex rule executor (the template
  dialect validator, its cost limits and an engine); see "The v4 matcher"
  below.

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

## The v4 matcher

This suite pins the **v3** matcher (`rules.ts`), the one the TypeScript oracle
implements. The Swift port implements the v4 matcher (spec 03c §5.2), which
extends it. A v4 executor reads the vectors as follows:

- Every rule is a v3 rule as 03c §5.1 says a reader treats one: one
  alternative (`patterns: [pattern]`), enabled, not removed. Each
  `expect.rules` entry is that one alternative.
- Every named category is active. The vectors carry no category table, so the
  v4 gates `category_unknown` and `category_retired` never fire; categories
  such as `zeta` or `regex-cat` are just labels here.
- No direction gate: the vectors have no transaction direction, and every
  decision is the matcher's, before the pipeline's refund handling.
- `match_order` is relative: v4 inserts `starts_with` between `exact` and
  `contains`, which leaves the order of the three v3 kinds unchanged. No
  vector uses `starts_with`; `unknown-match` uses `fuzzy`, which neither
  version knows.
- Priorities are compared as plain integers. The v4 op range (0–1000) bounds
  what an author writes, not what the matcher compares; the vectors use
  negative values and `9007199254740991`, which fit `Int64`.
- A port that does not execute regex rules skips exactly the `order.json`
  cases with `"requires": ["regex"]`. Every other case has no regex rule and
  must pass unchanged. Refusing a regex **dictionary** entry
  (`regex_not_allowed` in `dictionary.json`) needs no engine, so those vectors
  carry no tag.

Whether a v4 device still executes a v3 regex rule it finds in state is open:
03c §5.1 keeps such a rule in its v3 shape and §5.2's total order still ranks
`regex`, while spec 04's module table says the v4 matcher has no regex. The
tag lets either answer use this suite.

Version note: `pattern_unprintable` (general category C) and the
alphanumeric test (categories L and N) depend on the Unicode version. Every
code point here has been assigned for many Unicode versions, so the oracle's and
the port's tables agree on all of them.
