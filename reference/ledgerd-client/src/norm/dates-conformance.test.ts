/**
 * The TypeScript half of `conformance/norm-dates/`: the committed vectors are
 * what the oracle writes today, and this executor reproduces each one when it
 * reads the file the way the README describes.
 */

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT } from "../../scripts/conformance-io";
import { assertNormDatesFresh, type DatesDoc } from "../../scripts/gen-norm-dates-conformance";
import { utcDay } from "../replay/state";
import { canonicalTime, parseInstantMs } from "../wire/op";
import { emailDateOf, formatRFC3339UTC } from "./norm";
import { parseForwardDate } from "./unwrap";

const doc = JSON.parse(readFileSync(`${CONFORMANCE_ROOT}/norm-dates/dates.json`, "utf8")) as DatesDoc;

test("conformance/norm-dates is what the oracle writes", async () => {
  await assertNormDatesFresh();
});

test("conformance/norm-dates exercises both outcomes of every section", () => {
  expect(doc.forward_dates.some((v) => v.expect === null)).toBe(true);
  expect(doc.forward_dates.some((v) => v.expect !== null)).toBe(true);
  expect(new Set(doc.email_dates.map((v) => v.expect.date_source)).size).toBe(2);
  expect(doc.instants.some((v) => v.expect.ok)).toBe(true);
  expect(doc.instants.some((v) => !v.expect.ok)).toBe(true);
});

for (const v of doc.forward_dates) {
  test(`norm-dates forward: ${v.name}`, () => {
    const d = parseForwardDate(v.input);
    expect(d === null ? null : formatRFC3339UTC(d)).toBe(v.expect);
  });
}

for (const v of doc.email_dates) {
  test(`norm-dates email: ${v.name}`, () => {
    const r = emailDateOf(v.forward_date, v.received_at);
    expect(r.emailDate).toBe(v.expect.email_date);
    expect(r.dateSource).toBe(v.expect.date_source as typeof r.dateSource);
  });
}

for (const v of doc.instants) {
  test(`norm-dates instant: ${v.name}`, () => {
    if (!v.expect.ok) {
      expect(() => canonicalTime(v.input)).toThrow();
      return;
    }
    const ms = parseInstantMs(v.input);
    expect(`${ms}`).toBe(v.expect.epoch_ms);
    expect(canonicalTime(v.input)).toBe(v.expect.canonical);
    expect(utcDay(ms)).toBe(v.expect.utc_day);
  });
}
