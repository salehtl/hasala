/**
 * The TypeScript half of `conformance/authres/`: the committed vectors are what
 * the oracle writes today, and this executor, reading them the way any other
 * executor must (README.md), reproduces every expectation.
 */

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT } from "../../scripts/conformance-io";
import { assertAuthresFresh, expand, type Vector } from "../../scripts/gen-authres-conformance";
import { analyzeFor, gmailVerdict, outlookVerdict, verifiedDomain, type ArReason } from "./authres";

const doc = JSON.parse(readFileSync(`${CONFORMANCE_ROOT}/authres/vectors.json`, "utf8")) as { vectors: Vector[] };

test("conformance/authres is what the oracle writes", async () => {
  await assertAuthresFresh();
});

test("conformance/authres covers every reason and every group", () => {
  const reasons = new Set(doc.vectors.map((v) => v.expect.reason));
  expect([...reasons].sort()).toEqual(["fail", "multiple_ar", "no_ar", "no_eop", "not_topmost", "parse_error", "pass"]);
  const groups = new Set(doc.vectors.map((v) => v.group));
  expect([...groups].sort()).toEqual(["bounds", "domain", "gmail_shape", "goldens", "outlook", "structure", "unicode_whitespace"]);
  // The outlook group is exactly the Outlook vectors, and it reaches every Outlook reason.
  for (const v of doc.vectors) expect(v.group === "outlook").toBe(v.provider === "outlook");
  const outlookReasons = new Set(doc.vectors.filter((v) => v.provider === "outlook").map((v) => v.expect.reason));
  expect([...outlookReasons].sort()).toEqual(["fail", "multiple_ar", "no_ar", "no_eop", "not_topmost", "parse_error", "pass"]);
  // A trusted verdict always names a domain, and an untrusted one never does.
  for (const v of doc.vectors) expect(v.expect.domain !== null).toBe(v.expect.trusted);
});

for (const v of doc.vectors) {
  test(`authres conformance: ${v.group}/${v.name}`, () => {
    const raw = v.headers ?? expand(v.headers_parts!);
    const want = { trusted: v.expect.trusted, reason: v.expect.reason as ArReason };
    if (v.provider === undefined) {
      expect(gmailVerdict(raw)).toEqual(want);
      expect(verifiedDomain(raw)).toBe(v.expect.domain);
    } else {
      expect(outlookVerdict(raw)).toEqual(want);
      expect(verifiedDomain(raw, v.provider)).toBe(v.expect.domain);
    }
    expect(analyzeFor(raw, v.provider ?? "gmail")).toEqual({ verdict: want, domain: v.expect.domain });
  });
}
