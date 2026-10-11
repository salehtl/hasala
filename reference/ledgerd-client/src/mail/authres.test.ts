/**
 * Adversarial goldens for the Gmail Authentication-Results verdict.
 *
 * This is the trust decision for the whole mailbox lane (spec D4), so it is
 * treated as the highest-risk parser in the client. There is no second executor
 * and therefore no cross-language conformance vector — the goldens below are the
 * only thing pinning the rule, so they are deliberately hostile.
 *
 * Every fixture is SYNTHETIC. The repo's history was rewritten once because real
 * mail was committed; no real headers appear here.
 *
 * The hardened rule (spec D4): trust a verdict ONLY when exactly one A-R header
 * has authserv-id == mx.google.com, AND it precedes every other A-R header, AND
 * it reports dkim=pass (with a d= domain) OR dmarc=pass. Everything else is
 * untrusted with a specific reason.
 */

import { expect, test } from "bun:test";

import { gmailVerdict, verifiedDomain } from "./authres.ts";

/** Joins header lines with CRLF and terminates the block, the wire shape. */
const block = (...lines: string[]): string => lines.join("\r\n") + "\r\n\r\n";

test("single passing mx.google.com A-R with dkim=pass ⇒ trusted", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=pass header.i=@bank.example header.d=bank.example;",
    "       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=bank.example",
    "From: Bank <alerts@bank.example>",
    "Subject: Transaction alert",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("dmarc=pass alone (no dkim d=) still trusts, verified domain from header.from", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=neutral;",
    "       dmarc=pass header.from=Bank.Example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  // header.from carried mixed case; domains are case-insensitive.
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("no Authentication-Results header ⇒ no_ar (drafts / POP-importer case)", () => {
  const raw = block("From: someone@bank.example", "Subject: hi");
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("only a foreign authserv-id A-R (no mx.google.com) ⇒ no_ar", () => {
  const raw = block(
    "Authentication-Results: mail.attacker.test; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("TWO mx.google.com A-R headers ⇒ multiple_ar", () => {
  const raw = block(
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "multiple_ar" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("forged TOPMOST foreign authserv-id above the real mx.google.com ⇒ not_topmost", () => {
  // The attacker prepends their own A-R claiming a real-looking verdict. The
  // genuine mx.google.com one is now second, so it is not the topmost A-R.
  const raw = block(
    "Authentication-Results: attacker.test; dkim=pass header.d=bank.example",
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "not_topmost" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("mx.google.com topmost with a later foreign A-R below ⇒ still trusted", () => {
  const raw = block(
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    "Authentication-Results: some-forwarder.test; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("dkim=fail and no dmarc pass ⇒ fail", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=fail header.d=bank.example;",
    "       dmarc=fail header.from=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "fail" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("dkim=pass WITHOUT a d= domain and no dmarc pass ⇒ fail", () => {
  const raw = block(
    "Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "fail" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("folded / continued A-R value across many lines ⇒ parses, trusted", () => {
  // Continuation lines start with whitespace (RFC 5322 folding). A tab and
  // spaces mix, and the semicolons land at line boundaries.
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "\tdkim=pass",
    "        header.d=bank.example;",
    "\tspf=pass (google.com: domain of alerts@bank.example designates ...)",
    "        smtp.mailfrom=alerts@bank.example;",
    "\tdmarc=pass header.from=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("CFWS comments (parenthesised, nested) in the value do not confuse parsing", () => {
  const raw = block(
    "Authentication-Results: mx.google.com (Google mail server);",
    "       dkim=pass (2048-bit key; unprotected) header.d=bank.example;",
    "       dmarc=pass (policy applied (nested comment)) header.from=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("a comment containing a semicolon does not split resinfo", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=pass (key; note; with; semicolons) header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("authserv-id with a port (mx.google.com:25) does NOT match — bare-only", () => {
  // RFC 8601 authserv-id is a value that may carry a port; Gmail emits a bare
  // mx.google.com. Bare-only match is the safest rule: a port-bearing token is
  // treated as a different, untrusted authserv-id.
  const raw = block(
    "Authentication-Results: mx.google.com:25; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("ARC-Authentication-Results is NOT an Authentication-Results header", () => {
  const raw = block(
    "ARC-Authentication-Results: i=1; mx.google.com; dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("field name match is case-insensitive; authserv-id compared case-insensitively", () => {
  const raw = block(
    "AUTHENTICATION-RESULTS: MX.GOOGLE.COM; dkim=PASS header.d=Bank.Example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("dkim/1 method with a version tag still recognised", () => {
  const raw = block(
    "Authentication-Results: mx.google.com; dkim/1=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("over-large input ⇒ parse_error, never a throw", () => {
  const raw = "X-Pad: " + "a".repeat(300_000) + "\r\n\r\n";
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "parse_error" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("empty input ⇒ no_ar, never a throw", () => {
  expect(gmailVerdict("")).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain("")).toBeNull();
});

test("garbage / non-header input ⇒ never a throw", () => {
  const raw = "\x00\x01 not a header at all \n\n more junk";
  const v = gmailVerdict(raw);
  expect(v.trusted).toBe(false);
  // Any specific reason is acceptable; the contract is that it does not throw.
  expect(["no_ar", "parse_error", "fail"]).toContain(v.reason);
});

test("header block ends at the blank line — body A-R is ignored", () => {
  const raw =
    "From: Bank <alerts@bank.example>\r\n" +
    "\r\n" +
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n";
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
});
