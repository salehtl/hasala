/**
 * Writes `conformance/categorize/` — on-device categorization as the Swift port
 * must reproduce it:
 *
 *   - `canon.json`: `canonical`, `foldCase`, `runeLength` and `subjectOf`
 *     (`src/categorize/canon.ts`, `rules.ts`) over hostile strings.
 *   - `order.json`: user rules plus dictionary entries → the prepared order
 *     (`comparePrepared`), the load-time defects, and the `Decision` for each
 *     merchant (`prepare`, `categorize`).
 *   - `dictionary.json`: the dictionary entry gate (`validateDictEntry`) and
 *     lookups against a dictionary with no user rules.
 *
 * `conformance/dict/matching.json` (written by Go) already pins Go's
 * whitespace set, lower-casing, canonical forms and the exact/contains test;
 * this suite pins what only the client does: ordering, the decision, defects
 * and the gates Go never had.
 *
 * Every string is synthetic. Every expectation is the oracle's output.
 *
 *     cd reference/ledgerd-client && bun run gen-categorize-conformance
 *     bun run gen-categorize-conformance --check
 */

import { canonical, foldCase, runeLength } from "../src/categorize/canon";
import {
  MAX_SUBJECT_RUNES,
  categorize,
  prepare,
  subjectOf,
  validateDictEntry,
  type Decision,
  type DictEntry,
  type UserRule,
} from "../src/categorize/rules";
import { asciiJSON, assertFresh, writeOrCheck, type FixtureFile } from "./conformance-io";

export const SUITE = "categorize";
const REGENERATE = "bun run gen-categorize-conformance";

// ---------------------------------------------------------------------------
// canon.json
// ---------------------------------------------------------------------------

export interface CanonVector {
  name: string;
  input: string;
  expect: { canonical: string; fold_case: string; rune_length: number; subject: string };
}

const CANON_INPUTS: readonly (readonly [string, string])[] = [
  ["ascii-upper", "CARREFOUR"],
  ["ascii-mixed-with-digits", "Carrefour City 042"],
  ["empty", ""],
  ["whitespace-only", " \t\r\n\u00a0\u3000"],
  ["collapse-and-trim", "  CARREFOUR \t  Hyper\u00a0\u00a0Market  "],
  ["nel-is-space", "CARREFOUR\u0085HYPER"],
  ["every-go-space", "a\u0009b\u000ac\u000bd\u000ce\u000df g\u0085h\u00a0i\u1680j\u2000k\u200al\u2028m\u2029n\u202fo\u205fp\u3000q"],
  ["zero-width-space-is-not-space", "car\u200bre\u200cfour"],
  ["bom-is-not-space", "X\ufeffCARREFOUR"],
  ["mongolian-vowel-separator-is-not-space", "car\u180efour"],
  ["dotted-capital-i", "\u0130STANBUL"],
  ["dotless-small-i-stays", "\u0131stanbul"],
  ["final-sigma-folds-to-sigma", "\u039f\u0394\u039f\u03a3 \u03bf\u03b4\u03bf\u03c2"],
  ["kelvin-sign", "\u212a-MART"],
  ["angstrom-sign", "\u212bBERG"],
  ["sharp-s-stays", "STRA\u00dfE"],
  ["capital-sharp-s", "STRA\u1e9eE"],
  ["fullwidth-latin", "\uff23\uff21\uff32\uff32\uff25\uff26\uff2f\uff35\uff32"],
  ["cyrillic-homoglyph", "\u0421ARREFOUR"],
  ["greek-capitals", "\u0391\u0392\u0393"],
  ["armenian-capitals", "\u0531\u0532\u0533"],
  ["title-case-digraph", "\u01c5ungla"],
  ["roman-numeral", "\u2160\u2161 STORE"],
  ["circled-letters", "\u24b6\u24b7\u24b8"],
  ["arabic", "\u0643\u0627\u0631\u0641\u0648\u0631  \u0627\u0644\u0645\u0631\u0643\u0632"],
  ["arabic-with-harakat", "\u0643\u064e\u0627\u0631\u0650\u0641\u0648\u0631"],
  ["arabic-indic-digits", "\u0645\u062d\u0644 \u0661\u0662\u0663"],
  ["nfd-latin", "CAFE\u0301"],
  ["nfc-latin", "CAF\u00c9"],
  ["astral-letters", "\u{10400}\u{10401} SHOP"],
  ["emoji", "COFFEE \u2615 \u{1f600}"],
  ["control-characters-kept", "CAR\u0000\u0007FOUR"],
  ["subject-at-512-runes", "A".repeat(MAX_SUBJECT_RUNES)],
  ["subject-truncated-past-512-runes", "B".repeat(MAX_SUBJECT_RUNES) + "CDE"],
  ["subject-truncated-after-collapse", "  " + "C ".repeat(300)],
  ["subject-truncation-keeps-astral-whole", "D".repeat(MAX_SUBJECT_RUNES - 1) + "\u{1f600}\u{1f600}"],
];

function canonVectors(): CanonVector[] {
  return CANON_INPUTS.map(([name, input]) => ({
    name,
    input,
    expect: { canonical: canonical(input), fold_case: foldCase(input), rune_length: runeLength(input), subject: subjectOf(input) },
  }));
}

// ---------------------------------------------------------------------------
// order.json
// ---------------------------------------------------------------------------

interface OrderCaseSpec {
  name: string;
  note: string;
  rules: UserRule[];
  entries: DictEntry[];
  merchants: string[];
}

export interface PreparedOut {
  id: string;
  pattern: string;
  match: string;
  category: string;
  priority: number;
}

export interface OrderCase {
  name: string;
  note: string;
  rules: UserRule[];
  entries: DictEntry[];
  expect: {
    rules: PreparedOut[];
    entries: PreparedOut[];
    defects: { id: string; code: string; reasons?: string[] }[];
    decisions: { merchant: string; decision: Decision }[];
  };
}

const r = (id: string, pattern: string, match: string, category: string, priority = 100): UserRule => ({ id, pattern, match, category, priority });
const d = (pattern: string, match: string, category: string): DictEntry => ({ pattern, match, category });

function orderSpecs(): OrderCaseSpec[] {
  return [
    {
      name: "priority-lower-number-wins",
      note: "Two rules match; the lower priority number decides, whatever the kinds.",
      rules: [r("r-high", "carrefour", "contains", "shopping", 50), r("r-low", "carrefour", "contains", "groceries", 10)],
      entries: [],
      merchants: ["CARREFOUR CITY", "SPINNEYS"],
    },
    {
      name: "input-order-does-not-matter-a",
      note: "The same rule set as case b, listed in the opposite order: the prepared order and every decision are identical.",
      rules: [
        r("r1", "noon", "exact", "shopping", 5),
        r("r2", "noon minutes", "contains", "groceries", 5),
        r("r3", "^noon", "regex", "other", 5),
        r("r4", "minutes", "contains", "groceries", 1),
      ],
      entries: [],
      merchants: ["NOON", "NOON MINUTES", "NOON FOOD", "MINUTES"],
    },
    {
      name: "input-order-does-not-matter-b",
      note: "Case a's rules, reversed.",
      rules: [
        r("r4", "minutes", "contains", "groceries", 1),
        r("r3", "^noon", "regex", "other", 5),
        r("r2", "noon minutes", "contains", "groceries", 5),
        r("r1", "noon", "exact", "shopping", 5),
      ],
      entries: [],
      merchants: ["NOON", "NOON MINUTES", "NOON FOOD", "MINUTES"],
    },
    {
      name: "kind-order-at-equal-priority",
      note: "exact before contains before regex at one priority; each later rule is live, as the merchants that only it matches show.",
      rules: [r("rx", "^talabat", "regex", "regex-cat"), r("rc", "talabat", "contains", "contains-cat"), r("re", "talabat", "exact", "exact-cat")],
      entries: [],
      merchants: ["TALABAT", "TALABAT MART", "TALABATMART", "MY TALABAT"],
    },
    {
      name: "priority-outranks-kind",
      note: "A priority-1 contains rule beats a priority-2 exact rule.",
      rules: [r("exact-2", "careem", "exact", "transport", 2), r("contains-1", "careem", "contains", "food", 1)],
      entries: [],
      merchants: ["CAREEM"],
    },
    {
      name: "longer-pattern-first-in-runes",
      note: "At equal priority and kind the longer pattern (in code points, not UTF-16 units) comes first.",
      rules: [
        r("short", "mall", "contains", "short"),
        r("long", "dubai mall", "contains", "long"),
        r("astral", "\u{1f6d2}\u{1f6d2}\u{1f6d2}\u{1f6d2}", "contains", "astral"),
        r("five", "malls", "contains", "five"),
      ],
      entries: [],
      merchants: ["DUBAI MALL", "MALLS OF X", "MALL \u{1f6d2}\u{1f6d2}\u{1f6d2}\u{1f6d2}"],
    },
    {
      name: "full-tie-broken-by-code-points",
      note: "Same priority, kind and rune length: pattern by code point, then category, then id. U+FF5E sorts before U+1F600 by code point although its UTF-16 unit is larger than the high surrogate.",
      rules: [
        r("id-b", "shop", "contains", "zeta"),
        r("id-a", "shop", "contains", "zeta"),
        r("id-c", "shop", "contains", "alpha"),
        r("wave", "ab\uff5ex", "contains", "wave"),
        r("smile", "ab\u{1f600}x", "contains", "smile"),
      ],
      entries: [],
      merchants: ["SHOP", "AB\uff5eX AB\u{1f600}X"],
    },
    {
      name: "user-rule-beats-dictionary",
      note: "Tier 1 always before tier 2, even at the worst priority; the dictionary entry is live for a merchant no rule matches.",
      rules: [r("worst", "spinneys", "contains", "dining", Number.MAX_SAFE_INTEGER)],
      entries: [d("spinneys", "contains", "groceries"), d("waitrose", "contains", "groceries")],
      merchants: ["SPINNEYS JBR", "WAITROSE DUBAI MALL"],
    },
    {
      name: "negative-and-zero-priorities",
      note: "Priorities are plain integers; negative ones sort first.",
      rules: [r("zero", "enoc", "contains", "zero", 0), r("neg", "enoc", "contains", "neg", -5), r("pos", "enoc", "contains", "pos", 5)],
      entries: [],
      merchants: ["ENOC STATION 12"],
    },
    {
      name: "dictionary-entries-ordered-like-rules",
      note: "Two matching dictionary entries: exact before contains, then the longer pattern.",
      rules: [],
      entries: [d("amazon", "contains", "shopping"), d("amazon prime", "contains", "subscriptions"), d("amazon prime", "exact", "entertainment")],
      merchants: ["AMAZON PRIME", "AMAZON PRIME VIDEO", "AMAZON.AE"],
    },
    {
      name: "no-match-and-empty-merchants",
      note: "Nothing matching is a decision, and an empty or whitespace-only merchant never matches anything.",
      rules: [r("any", "^", "regex", "everything"), r("aaaa", "aaaa", "contains", "a")],
      entries: [],
      merchants: ["", "   ", "\u00a0\u3000", "B"],
    },
    {
      name: "pattern-and-category-canonicalized",
      note: "User exact/contains patterns and every category are canonicalized; a regex pattern is not (its double space can never match a canonical subject), and it runs case-insensitively against the canonical subject.",
      rules: [
        r("padded", "  CARREFOUR   Hyper ", "contains", "  Groceries  "),
        r("regex-mixed-case", "^Lulu hyper", "regex", "GROCERIES"),
        r("regex-double-space", "^spinneys  market", "regex", "groceries"),
      ],
      entries: [],
      merchants: ["carrefour HYPER deira", "LULU HYPERMARKET", "LULUHYPER", "SPINNEYS  MARKET"],
    },
    {
      name: "floors-on-user-rules",
      note: "contains needs 4 runes and exact 2, counted in code points after canonicalization.",
      rules: [
        r("contains-3", "abc", "contains", "x"),
        r("contains-4", "abcd", "contains", "x"),
        r("exact-1", "a", "exact", "x"),
        r("exact-2", "ab", "exact", "x"),
        r("contains-3-astral", "\u{1f600}\u{1f600}\u{1f600}", "contains", "x"),
        r("contains-4-astral", "\u{1f600}\u{1f600}\u{1f600}\u{1f600}", "contains", "x"),
        r("contains-collapses-to-3", "  a  b ", "contains", "x"),
      ],
      entries: [],
      merchants: ["AB", "XABCDX"],
    },
    {
      name: "user-rule-defects",
      note: "Each refused rule is reported with its code, never silently dropped; the valid one still applies.",
      rules: [
        r("ok", "valid", "contains", "fine"),
        r("unknown-match", "valid", "starts_with", "fine"),
        r("empty-category", "valid", "contains", "  "),
        r("multiline-contains", "val\nid", "contains", "fine"),
        r("multiline-exact-ls", "val\u2028id", "exact", "fine"),
        r("empty-pattern", " \t ", "contains", "fine"),
        r("too-long", "x".repeat(513), "contains", "fine"),
        r("at-max", "y".repeat(512), "contains", "fine"),
        r("regex-lookahead", "(?=carrefour)x", "regex", "fine"),
        r("regex-backreference", "(carre)\\1", "regex", "fine"),
        r("regex-two-unbounded", "[0-9]+[0-9]+z", "regex", "fine"),
        r("regex-nested-repetition", "^(?:[a-z0-9 ]{1,8}){8}z$", "regex", "fine"),
        r("regex-too-wide", "[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}z", "regex", "fine"),
        r("regex-malformed-repetition", "^a{,3}$", "regex", "fine"),
        r("regex-multiline-allowed", "^a\nb", "regex", "fine"),
      ],
      entries: [],
      merchants: ["VALID"],
    },
    {
      name: "homoglyphs-do-not-match",
      note: "Fullwidth, Cyrillic and Latin spellings stay different strings; the Kelvin sign folds to k.",
      rules: [r("latin", "carrefour", "contains", "latin"), r("kelvin", "kfc", "exact", "kfc")],
      entries: [d("\uff43\uff41\uff52\uff52\uff45\uff46\uff4f\uff55\uff52", "contains", "shopping")],
      merchants: ["CARREFOUR", "\uff23\uff21\uff32\uff32\uff25\uff26\uff2f\uff35\uff32", "\u0421ARREFOUR", "\u212aFC"],
    },
    {
      name: "arabic-merchants",
      note: "Arabic patterns match by code points; harakat make a different string.",
      rules: [r("ar-exact", "\u0643\u0627\u0631\u0641\u0648\u0631", "exact", "groceries"), r("ar-contains", "\u0627\u0644\u0645\u0631\u0643\u0632", "contains", "shopping")],
      entries: [],
      merchants: ["\u0643\u0627\u0631\u0641\u0648\u0631", "\u0643\u064e\u0627\u0631\u0650\u0641\u0648\u0631", "\u0645\u0648\u0644 \u0627\u0644\u0645\u0631\u0643\u0632"],
    },
    {
      name: "subject-bounded-to-512-runes",
      note: "A needle past the 512th rune of the canonical merchant never matches; one inside it does.",
      rules: [r("needle", "needle", "contains", "found")],
      entries: [],
      merchants: ["a".repeat(MAX_SUBJECT_RUNES) + " needle", "a".repeat(MAX_SUBJECT_RUNES - 20) + " needle"],
    },
    {
      name: "nfc-and-nfd-differ",
      note: "No normalization: a precomposed rule does not match a decomposed merchant.",
      rules: [r("nfc", "caf\u00e9 one", "contains", "nfc")],
      entries: [d("cafe\u0301 two", "contains", "dining")],
      merchants: ["CAF\u00c9 ONE", "CAFE\u0301 ONE", "CAFE\u0301 TWO", "CAF\u00c9 TWO"],
    },
  ];
}

const preparedOut = (p: { id: string; pattern: string; match: string; category: string; priority: number }): PreparedOut => ({
  id: p.id,
  pattern: p.pattern,
  match: p.match,
  category: p.category,
  priority: p.priority,
});

function orderCases(): OrderCase[] {
  return orderSpecs().map((c) => {
    const p = prepare(c.rules, c.entries);
    return {
      name: c.name,
      note: c.note,
      rules: c.rules,
      entries: c.entries,
      expect: {
        rules: p.rules.map(preparedOut),
        entries: p.entries.map(preparedOut),
        defects: p.defects.map((x) => (x.reasons === undefined ? { id: x.id, code: x.code } : { id: x.id, code: x.code, reasons: [...x.reasons] })),
        decisions: c.merchants.map((m) => ({ merchant: m, decision: categorize(m, p) })),
      },
    };
  });
}

// ---------------------------------------------------------------------------
// dictionary.json
// ---------------------------------------------------------------------------

export interface EntryVector {
  name: string;
  entry: DictEntry;
  expect: { ok: true; entry: DictEntry } | { ok: false; defect: { id: string; code: string } };
}

const ENTRY_INPUTS: readonly (readonly [string, DictEntry])[] = [
  ["plain-contains", d("CARREFOUR", "contains", "Groceries")],
  ["plain-exact", d("Noon.com", "exact", "shopping")],
  ["canonicalized", d("  Dubai \u00a0 Mall ", "contains", "  shopping  ")],
  ["regex-not-allowed", d("^carrefour", "regex", "groceries")],
  ["unknown-match", d("carrefour", "starts_with", "groceries")],
  ["multiline-pattern", d("carre\nfour", "contains", "groceries")],
  ["multiline-category", d("carrefour", "contains", "groc\reries")],
  ["paragraph-separator", d("carre\u2029four", "contains", "groceries")],
  ["empty-pattern", d("   ", "contains", "groceries")],
  ["no-letter-or-digit", d("----", "contains", "groceries")],
  ["arabic-letters-are-alnum", d("\u0643\u0627\u0631\u0641\u0648\u0631", "contains", "groceries")],
  ["arabic-indic-digits-are-alnum", d("\u0661\u0662\u0663\u0664", "contains", "other")],
  ["unprintable-format-char", d("car\u200bfour", "contains", "groceries")],
  ["unprintable-control", d("car\u0007four", "contains", "groceries")],
  ["unprintable-private-use", d("car\ue000four", "contains", "groceries")],
  ["empty-category", d("carrefour", "contains", " ")],
  ["category-one-rune", d("carrefour", "contains", "g")],
  ["category-two-runes", d("carrefour", "contains", "gx")],
  ["category-32-runes", d("carrefour", "contains", "c".repeat(32))],
  ["category-33-runes", d("carrefour", "contains", "c".repeat(33))],
  ["category-label-charset", d("carrefour", "contains", "food & drink/takeaway_1-2")],
  ["category-leading-symbol", d("carrefour", "contains", "&food")],
  ["category-non-ascii", d("carrefour", "contains", "\u0628\u0642\u0627\u0644\u0629")],
  ["category-upper-folds", d("carrefour", "contains", "GROCERIES")],
  ["pattern-64-runes", d("p".repeat(64), "contains", "other")],
  ["pattern-65-runes", d("p".repeat(65), "contains", "other")],
  ["contains-3-runes", d("abc", "contains", "other")],
  ["contains-4-runes", d("abcd", "contains", "other")],
  ["exact-1-rune", d("a", "exact", "other")],
  ["exact-2-runes", d("ab", "exact", "other")],
  ["astral-pattern-runes", d("\u{1f600}\u{1f600}\u{1f600}a", "contains", "other")],
];

function entryVectors(): EntryVector[] {
  return ENTRY_INPUTS.map(([name, entry]) => {
    const v = validateDictEntry(entry);
    return { name, entry, expect: "entry" in v ? { ok: true, entry: v.entry } : { ok: false, defect: { id: v.defect.id, code: v.defect.code } } };
  });
}

/** A synthetic dictionary: generic merchant brands, no personal data. */
const LOOKUP_DICTIONARY: readonly DictEntry[] = [
  d("carrefour", "contains", "groceries"),
  d("carrefour market", "contains", "groceries market"),
  d("spinneys", "contains", "groceries"),
  d("talabat", "contains", "dining"),
  d("talabat mart", "contains", "groceries"),
  d("careem", "contains", "transport"),
  d("careem food", "contains", "dining"),
  d("noon.com", "exact", "shopping"),
  d("noon", "exact", "shopping"),
  d("enoc", "contains", "fuel"),
  d("adnoc", "contains", "fuel"),
  d("dewa", "exact", "utilities"),
  d("netflix.com", "exact", "subscriptions"),
  d("\u0643\u0627\u0631\u0641\u0648\u0631", "contains", "groceries"),
  d("\u0637\u0644\u0628\u0627\u062a", "contains", "dining"),
  d("on", "contains", "charity"),
  d("^regex", "regex", "never"),
];

const LOOKUP_MERCHANTS: readonly string[] = [
  "CARREFOUR",
  "CARREFOUR MARKET JLT",
  "MAF CARREFOUR MARKET",
  "TALABAT",
  "TALABAT MART",
  "CAREEM FOOD",
  "CAREEM RIDE",
  "NOON",
  "NOON.COM",
  "NOON MINUTES",
  "ENOC 1043",
  "ADNOC 556",
  "DEWA",
  "DEWA BILL",
  "NETFLIX.COM",
  "AMAZON",
  "\u0643\u0627\u0631\u0641\u0648\u0631 \u0627\u0644\u0628\u0631\u0634\u0627\u0621",
  "\u0637\u0644\u0628\u0627\u062a",
  "TALABATMART",
  "",
];

function lookups(): { dictionary: DictEntry[]; expect: { entries: PreparedOut[]; defects: { id: string; code: string }[]; decisions: { merchant: string; decision: Decision }[] } } {
  const p = prepare([], LOOKUP_DICTIONARY);
  return {
    dictionary: [...LOOKUP_DICTIONARY],
    expect: {
      entries: p.entries.map(preparedOut),
      defects: p.defects.map((x) => ({ id: x.id, code: x.code })),
      decisions: LOOKUP_MERCHANTS.map((m) => ({ merchant: m, decision: categorize(m, p) })),
    },
  };
}

// ---------------------------------------------------------------------------

function uniqueNames(list: { name: string }[], what: string): void {
  const seen = new Set<string>();
  for (const x of list) {
    if (seen.has(x.name)) throw new Error(`duplicate ${what} name ${x.name}`);
    seen.add(x.name);
  }
}

const HEADER = "Written by reference/ledgerd-client/scripts/gen-categorize-conformance.ts from the TypeScript oracle (src/categorize); do not hand-edit. See README.md. ";

export function build(): FixtureFile[] {
  const canon = canonVectors();
  const order = orderCases();
  const entries = entryVectors();
  uniqueNames(canon, "canon vector");
  uniqueNames(order, "order case");
  uniqueNames(entries, "entry vector");
  return [
    {
      file: "canon.json",
      text: asciiJSON({
        note: HEADER + "canonical(), foldCase(), runeLength() (code points) and subjectOf() (canonical, truncated to max_subject_runes code points) of each input.",
        schema_version: 1,
        max_subject_runes: MAX_SUBJECT_RUNES,
        vectors: canon,
      }),
    },
    {
      file: "dictionary.json",
      text: asciiJSON({
        note:
          HEADER +
          "`entries`: validateDictEntry(entry), the canonical entry or the defect. `lookups`: prepare([], dictionary) — the prepared order and the defects — and categorize(merchant) for each merchant.",
        schema_version: 1,
        entries,
        lookups: lookups(),
      }),
    },
    {
      file: "order.json",
      text: asciiJSON({
        note:
          HEADER +
          "Each case: prepare(rules, entries) gives the prepared rules and entries in match order and the load-time defects in input order (rules first); categorize(merchant) gives each decision.",
        schema_version: 1,
        match_order: { exact: 0, contains: 1, regex: 2 },
        cases: order,
      }),
    },
  ];
}

export async function assertCategorizeFresh(): Promise<void> {
  await assertFresh(SUITE, build(), REGENERATE);
}

if (import.meta.main) {
  await writeOrCheck(SUITE, build(), REGENERATE);
}
