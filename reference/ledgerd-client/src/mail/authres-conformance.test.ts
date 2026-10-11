/**
 * The TypeScript half of `conformance/authres/`: the committed vectors are what
 * the oracle writes today, and this executor, reading them the way any other
 * executor must (README.md), reproduces every expectation.
 */

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT } from "../../scripts/conformance-io";
import { assertAuthresFresh, expand, type Vector } from "../../scripts/gen-authres-conformance";
import { gmailVerdict, verifiedDomain, type ArReason } from "./authres";

const doc = JSON.parse(readFileSync(`${CONFORMANCE_ROOT}/authres/vectors.json`, "utf8")) as { vectors: Vector[] };

test("conformance/authres is what the oracle writes", async () => {
  await assertAuthresFresh();
});

test("conformance/authres covers every reason and every group", () => {
  const reasons = new Set(doc.vectors.map((v) => v.expect.reason));
  expect([...reasons].sort()).toEqual(["fail", "multiple_ar", "no_ar", "not_topmost", "parse_error", "pass"]);
  const groups = new Set(doc.vectors.map((v) => v.group));
  expect([...groups].sort()).toEqual(["bounds", "domain", "goldens", "structure", "unicode_whitespace"]);
  // A trusted verdict always names a domain, and an untrusted one never does.
  for (const v of doc.vectors) expect(v.expect.domain !== null).toBe(v.expect.trusted);
});

for (const v of doc.vectors) {
  test(`authres conformance: ${v.group}/${v.name}`, () => {
    const raw = v.headers ?? expand(v.headers_parts!);
    expect(gmailVerdict(raw)).toEqual({ trusted: v.expect.trusted, reason: v.expect.reason as ArReason });
    expect(verifiedDomain(raw)).toBe(v.expect.domain);
  });
}
