import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { CONFORMANCE_ROOT } from "../../scripts/conformance-io";
import { expand } from "../../scripts/gen-authres-conformance";
import { assertOutlookSenderFresh, KNOWN_SENDERS, REJECT_DOMAINS, type Vector } from "../../scripts/gen-outlook-sender-conformance";
import { AR_REASONS, analyzeOutlookSender } from "./authres";

const doc = JSON.parse(readFileSync(`${CONFORMANCE_ROOT}/outlook-sender/vectors.json`, "utf8")) as {
  known_senders: string[];
  reject_domains: string[];
  reasons: string[];
  vectors: Vector[];
};

test("conformance/outlook-sender is what the oracle writes", async () => {
  await assertOutlookSenderFresh();
});

test("conformance/outlook-sender covers every reason of the rule", () => {
  const reasons = new Set(doc.vectors.map((v) => v.expect.reason));
  expect([...reasons].sort()).toEqual([...doc.reasons].sort());
  for (const r of doc.reasons) expect(AR_REASONS).toContain(r as (typeof AR_REASONS)[number]);
  expect(doc.known_senders).toEqual(KNOWN_SENDERS);
  expect(doc.reject_domains).toEqual(REJECT_DOMAINS);
  for (const v of doc.vectors) expect(v.expect.domain !== null).toBe(v.expect.trusted);
  expect(doc.vectors.filter((v) => v.expect.trusted).length).toBeGreaterThan(10);
});

for (const v of doc.vectors) {
  test(`outlook-sender conformance: ${v.name}`, () => {
    const raw = v.headers ?? expand(v.headers_parts!);
    const got = analyzeOutlookSender(raw, { inInbox: v.in_inbox, knownSenders: doc.known_senders, rejectDomains: doc.reject_domains });
    expect(got).toEqual({ verdict: { trusted: v.expect.trusted, reason: v.expect.reason as never }, domain: v.expect.domain });
  });
}
