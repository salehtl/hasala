/**
 * The TypeScript half of `conformance/categorize/`: the committed files are
 * what the oracle writes today, and this executor reproduces every expectation
 * when it reads them the way the README describes.
 */

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT } from "../../scripts/conformance-io";
import {
  assertCategorizeFresh,
  type CanonVector,
  type EntryVector,
  type OrderCase,
  type PreparedOut,
} from "../../scripts/gen-categorize-conformance";
import { canonical, foldCase, runeLength } from "./canon";
import { categorize, prepare, subjectOf, validateDictEntry, type DictEntry, type PreparedRules } from "./rules";

const read = <T>(file: string): T => JSON.parse(readFileSync(`${CONFORMANCE_ROOT}/categorize/${file}`, "utf8")) as T;
const canon = read<{ vectors: CanonVector[] }>("canon.json");
const order = read<{ cases: OrderCase[] }>("order.json");
const dict = read<{
  entries: EntryVector[];
  lookups: { dictionary: DictEntry[]; expect: { entries: PreparedOut[]; defects: unknown[]; decisions: { merchant: string; decision: unknown }[] } };
}>("dictionary.json");

/** A value as JSON sees it, so typed results compare against the fixture's plain objects. */
const plain = (v: unknown): unknown => JSON.parse(JSON.stringify(v));

const prepared = (p: PreparedRules): { rules: PreparedOut[]; entries: PreparedOut[] } => {
  const out = (x: PreparedOut): PreparedOut => ({ id: x.id, pattern: x.pattern, match: x.match, category: x.category, priority: x.priority });
  return { rules: p.rules.map(out), entries: p.entries.map(out) };
};

test("conformance/categorize is what the oracle writes", async () => {
  await assertCategorizeFresh();
});

test("conformance/categorize reaches every decision source and refuses something", () => {
  const sources = new Set(order.cases.flatMap((c) => c.expect.decisions.map((d) => d.decision.source)));
  expect([...sources].sort()).toEqual(["dictionary", "none", "rule"]);
  expect(order.cases.some((c) => c.expect.defects.length > 0)).toBe(true);
  expect(dict.entries.some((v) => v.expect.ok) && dict.entries.some((v) => !v.expect.ok)).toBe(true);
});

for (const v of canon.vectors) {
  test(`categorize canon: ${v.name}`, () => {
    const got = { canonical: canonical(v.input), fold_case: foldCase(v.input), rune_length: runeLength(v.input), subject: subjectOf(v.input) };
    expect(got).toEqual(v.expect);
  });
}

for (const c of order.cases) {
  test(`categorize order: ${c.name}`, () => {
    const p = prepare(c.rules, c.entries);
    expect(prepared(p)).toEqual({ rules: c.expect.rules, entries: c.expect.entries });
    expect(plain(p.defects)).toEqual(c.expect.defects);
    for (const d of c.expect.decisions) expect(plain(categorize(d.merchant, p))).toEqual(d.decision);
  });
}

for (const v of dict.entries) {
  test(`categorize dictionary entry: ${v.name}`, () => {
    const got = validateDictEntry(v.entry);
    expect(plain("entry" in got ? { ok: true, entry: got.entry } : { ok: false, defect: got.defect })).toEqual(v.expect);
  });
}

test("categorize dictionary lookups", () => {
  const p = prepare([], dict.lookups.dictionary);
  expect(prepared(p).entries).toEqual(dict.lookups.expect.entries);
  expect(plain(p.defects)).toEqual(dict.lookups.expect.defects);
  for (const d of dict.lookups.expect.decisions) expect(plain(categorize(d.merchant, p))).toEqual(d.decision);
});
