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
 * it reports dkim=pass with a d= domain aligned with the one From domain.
 * Everything else is untrusted with a specific reason.
 */

import { expect, test } from "bun:test";

import { analyzeFor, gmailVerdict, outlookVerdict, verifiedDomain } from "./authres.ts";

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

test("dmarc=pass alone (no dkim d=) ⇒ fail", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=neutral;",
    "       dmarc=pass header.from=Bank.Example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "fail" });
  expect(verifiedDomain(raw)).toBeNull();
});

test("dkim=pass for another domain with dmarc=pass ⇒ fail", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=pass header.i=@esp.example header.d=esp.example;",
    "       spf=pass smtp.mailfrom=bank.example;",
    "       dmarc=pass header.from=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "fail" });
});

test("the first aligned dkim=pass decides", () => {
  const raw = block(
    "Authentication-Results: mx.google.com;",
    "       dkim=pass header.d=esp.example;",
    "       dkim=pass header.d=bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw)).toBe("bank.example");
});

test("dkim d= and From align on a subdomain either way", () => {
  const sub = block(
    "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    "From: Bank <alerts@mail.bank.example>",
  );
  expect(verifiedDomain(sub)).toBe("bank.example");
  const parent = block(
    "Authentication-Results: mx.google.com; dkim=pass header.d=mail.bank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(verifiedDomain(parent)).toBe("mail.bank.example");
  const sibling = block(
    "Authentication-Results: mx.google.com; dkim=pass header.d=notbank.example",
    "From: Bank <alerts@bank.example>",
  );
  expect(gmailVerdict(sibling)).toEqual({ trusted: false, reason: "fail" });
});

test("dkim=pass with no From or two From fields ⇒ fail", () => {
  const ar = "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example";
  expect(gmailVerdict(block(ar, "Subject: hi"))).toEqual({ trusted: false, reason: "fail" });
  expect(
    gmailVerdict(block(ar, "From: Bank <alerts@bank.example>", "From: Bank <alerts@bank.example>")),
  ).toEqual({ trusted: false, reason: "fail" });
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

// --- Outlook.com (outlookVerdict) ---------------------------------------------
//
// The rule (WP1 decision §3): exactly one Microsoft-form A-R (no authserv-id),
// topmost among A-Rs, EOP's AuthAs: Anonymous and AuthSource under
// .prod.outlook.com exactly once each, compauth=pass and dmarc=pass exactly once
// each, and exactly one From whose domain is the DMARC header.from.

const MS_AR =
  "Authentication-Results: spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=bank.example; dkim=pass (signature was verified) header.d=bank.example; dmarc=pass action=none header.from=bank.example;compauth=pass reason=100";
const AUTH_AS = "X-MS-Exchange-Organization-AuthAs: Anonymous";
const AUTH_SOURCE = "X-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com";
const OUTLOOK_FROM = "From: Bank <alerts@bank.example>";

test("outlook: EOP's A-R with compauth=pass and dmarc=pass ⇒ trusted", () => {
  const raw = block(MS_AR, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM);
  expect(outlookVerdict(raw)).toEqual({ trusted: true, reason: "pass" });
  expect(verifiedDomain(raw, "outlook")).toBe("bank.example");
  expect(analyzeFor(raw, "outlook")).toEqual({ verdict: { trusted: true, reason: "pass" }, domain: "bank.example" });
});

test("outlook: spf=pass is never read as an authserv-id", () => {
  // Under the Gmail rule the Microsoft-form A-R is a foreign A-R; it never
  // becomes Gmail's, and gmailVerdict is unchanged.
  const raw = block(MS_AR, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM);
  expect(gmailVerdict(raw)).toEqual({ trusted: false, reason: "no_ar" });
  expect(verifiedDomain(raw)).toBeNull();
  // spf=pass alone in Microsoft form is a method, not an id, and not trust.
  const spfOnly = block("Authentication-Results: spf=pass smtp.mailfrom=bank.example", AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM);
  expect(outlookVerdict(spfOnly)).toEqual({ trusted: false, reason: "fail" });
});

test("outlook: dmarc or compauth short of an exact pass ⇒ fail", () => {
  for (const ar of [
    MS_AR.replace("dmarc=pass", "dmarc=fail"),
    MS_AR.replace("dmarc=pass", "dmarc=bestguesspass"),
    MS_AR.replace("compauth=pass reason=100", "compauth=fail reason=001"),
    MS_AR.replace("compauth=pass", "compauth=softpass"),
    MS_AR.replace(";compauth=pass reason=100", ""),
    MS_AR + "; dmarc=pass header.from=bank.example",
  ]) {
    expect(outlookVerdict(block(ar, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM))).toEqual({ trusted: false, reason: "fail" });
  }
});

test("outlook: a forged Microsoft-form A-R above or below EOP's ⇒ multiple_ar", () => {
  const forged = "Authentication-Results: spf=pass smtp.mailfrom=bank.example; dmarc=pass header.from=bank.example; compauth=pass reason=100";
  const failing = MS_AR.replace("dmarc=pass", "dmarc=fail").replace("compauth=pass", "compauth=fail");
  expect(outlookVerdict(block(forged, failing, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("multiple_ar");
  expect(outlookVerdict(block(failing, forged, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("multiple_ar");
});

test("outlook: an authserv-id A-R above EOP's ⇒ not_topmost; below is ignored", () => {
  const google = "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example";
  expect(outlookVerdict(block(google, MS_AR, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("not_topmost");
  expect(outlookVerdict(block(MS_AR, google, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("pass");
});

test("outlook: missing, wrong or repeated EOP fields ⇒ no_eop", () => {
  expect(outlookVerdict(block(MS_AR, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_eop");
  expect(outlookVerdict(block(MS_AR, AUTH_AS, OUTLOOK_FROM)).reason).toBe("no_eop");
  expect(outlookVerdict(block(MS_AR, AUTH_AS.replace("Anonymous", "Internal"), AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_eop");
  expect(outlookVerdict(block(MS_AR, AUTH_AS, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_eop");
  expect(
    outlookVerdict(block(MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: relay.evil.example", OUTLOOK_FROM)).reason,
  ).toBe("no_eop");
  expect(
    outlookVerdict(block(MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: prod.outlook.com.evil.example", OUTLOOK_FROM)).reason,
  ).toBe("no_eop");
});

test("outlook: From must be single and match the DMARC header.from", () => {
  expect(outlookVerdict(block(MS_AR, AUTH_AS, AUTH_SOURCE, "From: Bank <alerts@evil.example>")).reason).toBe("fail");
  expect(outlookVerdict(block(MS_AR, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM, OUTLOOK_FROM)).reason).toBe("fail");
  expect(outlookVerdict(block(MS_AR, AUTH_AS, AUTH_SOURCE)).reason).toBe("fail");
  expect(outlookVerdict(block(MS_AR, AUTH_AS, AUTH_SOURCE, "From: ALERTS@BANK.EXAMPLE.")).reason).toBe("pass");
});

test("outlook: no A-R, or only authserv-id and ARC A-Rs ⇒ no_ar; bounds ⇒ parse_error", () => {
  expect(outlookVerdict(block(AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_ar");
  expect(outlookVerdict(block("Authentication-Results: mx.google.com; dmarc=pass header.from=bank.example", AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_ar");
  expect(outlookVerdict(block("ARC-" + MS_AR, AUTH_AS, AUTH_SOURCE, OUTLOOK_FROM)).reason).toBe("no_ar");
  expect(outlookVerdict("")).toEqual({ trusted: false, reason: "no_ar" });
  expect(outlookVerdict("X-Pad: " + "a".repeat(300_000) + "\r\n\r\n").reason).toBe("parse_error");
});
