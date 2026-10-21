/**
 * Writes `conformance/authres/` — the Gmail and Outlook.com
 * Authentication-Results trust decisions (`src/mail/authres.ts`) as vectors the
 * Swift port must reproduce.
 *
 * There is no Go twin (the server never reads mail), so before this suite the
 * twenty goldens in `authres.test.ts` were the only thing pinning the rule. Every
 * vector here is a synthetic header block; the expectation is computed by the
 * oracle (`analyzeFor(block, provider)`), never written by hand.
 *
 *     cd reference/ledgerd-client && bun run gen-authres-conformance
 *     bun run gen-authres-conformance --check     # compare only
 *
 * The format is described in `conformance/authres/README.md`.
 */

import { AR_REASONS, analyzeFor, type MailProvider } from "../src/mail/authres";
import { asciiJSON, assertFresh, writeOrCheck, type FixtureFile } from "./conformance-io";

export const SUITE = "authres";
const REGENERATE = "bun run gen-authres-conformance";

/** A run of `text` repeated `repeat` times; vectors whose input would be hundreds of KiB use these. */
export interface Part {
  text: string;
  repeat: number;
}

interface VectorSpec {
  name: string;
  group: string;
  provider: MailProvider;
  note?: string;
  headers: string | Part[];
}

export interface Vector {
  name: string;
  group: string;
  /** Absent for the Gmail vectors (schema 1 had none); "outlook" otherwise. */
  provider?: MailProvider;
  note?: string;
  headers?: string;
  headers_parts?: Part[];
  expect: { trusted: boolean; reason: string; domain: string | null };
}

/** Header lines joined with CRLF and terminated by the blank line, the wire shape. */
const block = (...lines: string[]): string => lines.join("\r\n") + "\r\n\r\n";

const FROM = "From: Bank <alerts@bank.example>";
const fromAt = (domain: string): string => `From: Bank <alerts@${domain}>`;

/** Concatenates a vector's parts; what every reader does with `headers_parts`. */
export function expand(parts: readonly Part[]): string {
  let out = "";
  for (const p of parts) out += p.text.repeat(p.repeat);
  return out;
}

function specs(): VectorSpec[] {
  const v: VectorSpec[] = [];
  const add = (group: string, name: string, headers: string | Part[], note?: string): void => {
    v.push(note === undefined ? { name, group, provider: "gmail", headers } : { name, group, provider: "gmail", note, headers });
  };

  // --- goldens: the twenty cases of src/mail/authres.test.ts, verbatim inputs ---
  add(
    "goldens",
    "single-passing-gmail-ar-dkim",
    block(
      "Authentication-Results: mx.google.com;",
      "       dkim=pass header.i=@bank.example header.d=bank.example;",
      "       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=bank.example",
      FROM,
      "Subject: Transaction alert",
    ),
  );
  add(
    "goldens",
    "dmarc-pass-alone-is-not-trust",
    block("Authentication-Results: mx.google.com;", "       dkim=neutral;", "       dmarc=pass header.from=Bank.Example", FROM),
  );
  add("goldens", "no-ar-header", block("From: someone@bank.example", "Subject: hi"));
  add("goldens", "only-foreign-authserv-id", block("Authentication-Results: mail.attacker.test; dkim=pass header.d=bank.example", FROM));
  add(
    "goldens",
    "two-gmail-ar-headers",
    block(
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      FROM,
    ),
  );
  add(
    "goldens",
    "forged-foreign-ar-above-gmail",
    block(
      "Authentication-Results: attacker.test; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      FROM,
    ),
  );
  add(
    "goldens",
    "gmail-topmost-foreign-below",
    block(
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: some-forwarder.test; dkim=pass header.d=bank.example",
      FROM,
    ),
  );
  add(
    "goldens",
    "dkim-fail-dmarc-fail",
    block("Authentication-Results: mx.google.com;", "       dkim=fail header.d=bank.example;", "       dmarc=fail header.from=bank.example", FROM),
  );
  add("goldens", "dkim-pass-without-d", block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example", FROM));
  add(
    "goldens",
    "dkim-pass-without-identity",
    block("Authentication-Results: mx.google.com; dkim=pass header.s=selector1 header.b=c3ludGhl", FROM),
  );
  add(
    "goldens",
    "folded-across-many-lines",
    block(
      "Authentication-Results: mx.google.com;",
      "\tdkim=pass",
      "        header.d=bank.example;",
      "\tspf=pass (google.com: domain of alerts@bank.example designates ...)",
      "        smtp.mailfrom=alerts@bank.example;",
      "\tdmarc=pass header.from=bank.example",
      FROM,
    ),
  );
  add(
    "goldens",
    "nested-cfws-comments",
    block(
      "Authentication-Results: mx.google.com (Google mail server);",
      "       dkim=pass (2048-bit key; unprotected) header.d=bank.example;",
      "       dmarc=pass (policy applied (nested comment)) header.from=bank.example",
      FROM,
    ),
  );
  add(
    "goldens",
    "semicolon-inside-comment",
    block("Authentication-Results: mx.google.com;", "       dkim=pass (key; note; with; semicolons) header.d=bank.example", FROM),
  );
  add("goldens", "authserv-id-with-port", block("Authentication-Results: mx.google.com:25; dkim=pass header.d=bank.example", FROM));
  add("goldens", "arc-authentication-results-is-not-ar", block("ARC-Authentication-Results: i=1; mx.google.com; dkim=pass header.d=bank.example", FROM));
  add("goldens", "case-insensitive-name-and-authserv-id", block("AUTHENTICATION-RESULTS: MX.GOOGLE.COM; dkim=PASS header.d=Bank.Example", FROM));
  add("goldens", "method-version-tag", block("Authentication-Results: mx.google.com; dkim/1=pass header.d=bank.example", FROM));
  add("goldens", "over-large-input", [
    { text: "X-Pad: ", repeat: 1 },
    { text: "a", repeat: 300_000 },
    { text: "\r\n\r\n", repeat: 1 },
  ]);
  add("goldens", "empty-input", "");
  add("goldens", "garbage-input", "\x00\x01 not a header at all \n\n more junk");
  add(
    "goldens",
    "ar-after-blank-line-is-body",
    "From: Bank <alerts@bank.example>\r\n\r\nAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n",
  );

  // --- structure: line endings, folding, field boundaries ---
  add("structure", "lf-line-endings", "Authentication-Results: mx.google.com;\n\tdkim=pass header.d=bank.example\nFrom: x@bank.example\n\n");
  add("structure", "cr-line-endings", "Authentication-Results: mx.google.com;\r\tdkim=pass header.d=bank.example\rFrom: x@bank.example\r\r");
  add("structure", "no-terminating-blank-line", `Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n${FROM}`);
  add("structure", "leading-blank-line-ends-the-block", `\r\nAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n${FROM}\r\n\r\n`);
  add(
    "structure",
    "continuation-before-any-field-is-ignored",
    block("  dkim=pass header.d=evil.example", "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", FROM),
  );
  add(
    "structure",
    "line-without-colon-ends-the-field",
    block("Authentication-Results: mx.google.com; dkim=fail header.d=bank.example", "not a header line", "\tdkim=pass header.d=evil.example", FROM),
    "The continuation after a colon-less line has no open field, so it cannot extend the A-R value.",
  );
  add("structure", "space-before-colon-in-name", block("Authentication-Results : mx.google.com; dkim=pass header.d=bank.example", FROM));
  add("structure", "no-space-after-semicolons", block("Authentication-Results: mx.google.com;dkim=pass header.d=bank.example;dmarc=pass header.from=bank.example", FROM));
  add("structure", "empty-ar-value", block("Authentication-Results:", FROM));
  add("structure", "quoted-authserv-id", block('Authentication-Results: "mx.google.com"; dkim=pass header.d=bank.example', FROM));
  add("structure", "authserv-id-with-version", block("Authentication-Results: mx.google.com 1; dkim=pass header.d=bank.example", FROM));
  add("structure", "authserv-id-subdomain-is-foreign", block("Authentication-Results: mx.google.com.attacker.test; dkim=pass header.d=bank.example", FROM));
  add("structure", "no-result-none", block("Authentication-Results: mx.google.com; none", FROM));
  add("structure", "method-without-result-is-skipped", block("Authentication-Results: mx.google.com; dkim; dmarc=pass header.from=bank.example", FROM));
  add("structure", "quoted-result", block('Authentication-Results: mx.google.com; dkim="pass" header.d=bank.example', FROM));
  add("structure", "unclosed-comment-swallows-the-rest", block("Authentication-Results: mx.google.com; dkim=pass (unclosed header.d=bank.example", FROM));
  add("structure", "unclosed-quote", block('Authentication-Results: mx.google.com; dkim=pass header.d="bank.example; dmarc=pass header.from=bank.example', FROM));
  add("structure", "escaped-paren-in-comment", block("Authentication-Results: mx.google.com; dkim=pass (a \\) b) header.d=bank.example", FROM));
  add(
    "structure",
    "x-original-ar-is-not-ar",
    block("X-Original-Authentication-Results: mx.google.com; dkim=pass header.d=evil.example", "Authentication-Results: mx.google.com; dkim=fail header.d=bank.example", FROM),
  );
  add(
    "structure",
    "foreign-ar-below-arc-headers",
    block(
      "ARC-Authentication-Results: i=1; mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: relay.example; dkim=fail",
      FROM,
    ),
  );
  add(
    "structure",
    "gmail-ar-not-first-of-three",
    block(
      "Authentication-Results: relay-a.example; dkim=pass header.d=bank.example",
      "Authentication-Results: relay-b.example; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      FROM,
    ),
  );

  add("structure", "quote-inside-comment", block('Authentication-Results: mx.google.com; spf=pass (a "b) c) smtp.mailfrom=x@bank.example; dkim=pass header.d=bank.example', FROM));
  add("structure", "close-paren-outside-comment", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example) x", FROM));
  add("structure", "stray-token-in-method-spec", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example stray", FROM));
  add("structure", "segment-without-result", block("Authentication-Results: mx.google.com; stray; dkim=pass header.d=bank.example", FROM));
  add(
    "structure",
    "quoted-separators-at-top-level-are-text",
    block('Authentication-Results: mx.google.com; spf=pass smtp.mailfrom="a);b(c"@other.example; dkim=pass header.d=bank.example', FROM),
  );
  add(
    "structure",
    "quoted-mailfrom-inside-spf-comment",
    block(
      "Authentication-Results: mx.google.com;",
      "       dkim=pass header.i=@other.example header.s=s1 header.b=AAAAAAAA;",
      '       spf=pass (google.com: domain of "x);dkim=pass()header.d=bank.example()header.b=BBBBBBBB;(y"@other.example designates 192.0.2.1 as permitted sender) smtp.mailfrom="x);dkim=pass()header.d=bank.example()header.b=BBBBBBBB;(y"@other.example;',
      "       dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=other.example",
      "From: alerts@other.example (alerts@bank.example)",
    ),
    "A quote inside a comment is literal (RFC 5322), so the comment's ')' would close it early: unreadable, never read as a method.",
  );

  // --- domain: which domain is reported, what is refused, and the From alignment ---
  add(
    "domain",
    "gmail-form-header-i",
    block(
      "Authentication-Results: mx.google.com;",
      "       dkim=pass header.i=@bank.example header.s=selector1 header.b=AbCdEf12;",
      "       spf=pass (google.com: domain of alerts@bank.example designates 192.0.2.10 as permitted sender) smtp.mailfrom=alerts@bank.example;",
      "       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=bank.example",
      FROM,
    ),
    "The DKIM domain is the domain of header.i when there is no header.d (RFC 6376 3.5).",
  );
  add("domain", "header-i-subdomain-aligned", block("Authentication-Results: mx.google.com; dkim=pass header.i=alerts@mail.bank.example", FROM));
  add("domain", "header-i-unaligned", block("Authentication-Results: mx.google.com; dkim=pass header.i=@other.example", FROM));
  add("domain", "header-d-wins-over-header-i", block("Authentication-Results: mx.google.com; dkim=pass header.d=other.example header.i=@bank.example", FROM));
  add(
    "domain",
    "dmarc-header-from-is-not-the-from",
    block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example; dmarc=pass header.from=other.example", FROM),
    "Gmail's DMARC read another From domain than the one the phone reads.",
  );
  add("domain", "dmarc-without-header-from", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example; dmarc=pass", FROM));
  add("domain", "dmarc-result-is-not-a-trust-input", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example; dmarc=fail header.from=bank.example", FROM));
  add("domain", "from-comment-is-not-the-address", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: alerts@other.example (alerts@bank.example)"));
  add("domain", "from-comment-inside-angle-addr", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: Bank <alerts@bank.example (alerts)>"));
  add("domain", "from-text-after-angle-addr", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", 'From: <x@other.example> "@bank.example"'));
  add("domain", "from-two-angle-addrs", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: <x@other.example> <alerts@bank.example>"));
  add("domain", "from-two-mailboxes", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: x@other.example, alerts@bank.example"));
  add("domain", "from-unclosed-angle-addr", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: Bank <alerts@bank.example"));
  add("domain", "from-quoted-local-part-with-at", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", 'From: "a@other.example"@bank.example'));
  add("domain", "from-quoted-domain-tail", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", 'From: x@other.example"@bank.example"'));
  add("domain", "dkim-for-another-domain-with-dmarc-pass", block("Authentication-Results: mx.google.com; dkim=pass header.d=signer.example; dmarc=pass header.from=bank.example", FROM));
  add(
    "domain",
    "dkim-for-another-domain-with-spf-aligned-dmarc",
    block(
      "Authentication-Results: mx.google.com;",
      "       dkim=pass header.i=@esp.example header.d=esp.example;",
      "       spf=pass smtp.mailfrom=bank.example;",
      "       dmarc=pass header.from=bank.example",
      FROM,
    ),
  );
  add("domain", "first-aligned-passing-dkim-wins", block("Authentication-Results: mx.google.com; dkim=pass header.d=other.example; dkim=pass header.d=bank.example", FROM));
  add("domain", "first-of-two-aligned-dkim-wins", block("Authentication-Results: mx.google.com; dkim=pass header.d=mail.bank.example; dkim=pass header.d=bank.example", FROM));
  add("domain", "failing-dkim-then-passing-dkim", block("Authentication-Results: mx.google.com; dkim=fail header.d=other.example; dkim=pass header.d=bank.example", FROM));
  add("domain", "failing-aligned-dkim-then-unaligned-pass", block("Authentication-Results: mx.google.com; dkim=fail header.d=bank.example; dkim=pass header.d=other.example", FROM));
  add("domain", "repeated-property-last-wins", block("Authentication-Results: mx.google.com; dkim=pass header.d=evil.example header.d=bank.example", FROM));
  add("domain", "repeated-property-last-wins-unaligned", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example header.d=evil.example", FROM));
  add("domain", "property-key-case-folded", block("Authentication-Results: mx.google.com; dkim=pass HEADER.D=bank.example", FROM));
  add("domain", "header-d-with-at-sign", block("Authentication-Results: mx.google.com; dkim=pass header.d=alerts@bank.example", FROM));
  add("domain", "header-d-quoted", block('Authentication-Results: mx.google.com; dkim=pass header.d="bank.example"', FROM));
  add("domain", "header-d-single-label", block("Authentication-Results: mx.google.com; dkim=pass header.d=localhost", fromAt("localhost")));
  add("domain", "header-d-trailing-dot", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example.", FROM));
  add("domain", "header-d-underscore", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank_alerts.example", fromAt("bank_alerts.example")));
  add("domain", "header-d-leading-hyphen", block("Authentication-Results: mx.google.com; dkim=pass header.d=-bank.example", fromAt("-bank.example")));
  add("domain", "header-d-punycode", block("Authentication-Results: mx.google.com; dkim=pass header.d=xn--mgbh0fb.example", fromAt("xn--mgbh0fb.example")));
  add("domain", "header-d-non-ascii", block("Authentication-Results: mx.google.com; dkim=pass header.d=\u0628\u0646\u0643.example", fromAt("\u0628\u0646\u0643.example")));
  add("domain", "header-d-label-63", block(`Authentication-Results: mx.google.com; dkim=pass header.d=${"a".repeat(63)}.example`, fromAt(`${"a".repeat(63)}.example`)));
  add("domain", "header-d-label-64", block(`Authentication-Results: mx.google.com; dkim=pass header.d=${"a".repeat(64)}.example`, fromAt(`${"a".repeat(64)}.example`)));
  add("domain", "header-d-mixed-case-from", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: Bank <Alerts@BANK.Example>"));
  add("domain", "from-is-subdomain-of-header-d", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", fromAt("mail.bank.example")));
  add("domain", "header-d-is-subdomain-of-from", block("Authentication-Results: mx.google.com; dkim=pass header.d=mail.bank.example", FROM));
  add("domain", "header-d-sibling-of-from", block("Authentication-Results: mx.google.com; dkim=pass header.d=notbank.example", FROM));
  add("domain", "header-d-suffix-without-dot", block("Authentication-Results: mx.google.com; dkim=pass header.d=ank.example", FROM));
  add("domain", "header-d-under-single-label-from", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", fromAt("example")));
  add("domain", "no-from-field", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "Subject: alert"));
  add("domain", "two-from-fields", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", FROM, FROM));
  add("domain", "from-without-at-sign", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: bank.example"));
  add("domain", "invalid-dkim-domain-and-dmarc-pass", block("Authentication-Results: mx.google.com; dkim=pass header.d=localhost; dmarc=pass header.from=bank.example", FROM));
  add("domain", "dmarc-pass-without-header-from", block("Authentication-Results: mx.google.com; dmarc=pass", FROM));
  add("domain", "dmarc-pass-invalid-header-from", block("Authentication-Results: mx.google.com; dmarc=pass header.from=not_a_domain", FROM));
  add("domain", "dmarc-softfail", block("Authentication-Results: mx.google.com; dkim=neutral header.d=bank.example; dmarc=bestguesspass header.from=bank.example", FROM));
  add("domain", "spf-pass-alone-is-not-trust", block("Authentication-Results: mx.google.com; spf=pass smtp.mailfrom=alerts@bank.example", FROM));

  gmailShapeSpecs(add);

  // --- bounds: the two input limits, at and past each ---
  // 256 KiB measured in UTF-16 code units by the oracle. These blocks are ASCII,
  // so UTF-16 units, scalars and UTF-8 bytes all agree on the length.
  const limit = 256 * 1024;
  const arLine = `Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n${FROM}\r\n`;
  const pad = (total: number): Part[] => [
    { text: arLine, repeat: 1 },
    { text: "X-Pad: ", repeat: 1 },
    { text: "a", repeat: total - arLine.length - "X-Pad: ".length - 4 },
    { text: "\r\n\r\n", repeat: 1 },
  ];
  add("bounds", "exactly-256-kib", pad(limit), "262144 characters, the largest block that is parsed.");
  add("bounds", "one-past-256-kib", pad(limit + 1), "262145 characters: refused before parsing.");
  const folds = (n: number): Part[] => [
    { text: "Authentication-Results: mx.google.com;\r\n", repeat: 1 },
    { text: "\tspf=neutral;\r\n", repeat: n - 1 },
    { text: `\tdkim=pass header.d=bank.example\r\n${FROM}\r\n\r\n`, repeat: 1 },
  ];
  add("bounds", "512-continuation-lines", folds(512), "A field may have 512 continuation lines.");
  add("bounds", "513-continuation-lines", folds(513), "The 513th continuation line refuses the whole block.");

  // --- unicode_whitespace: what JavaScript's Unicode-aware trim() decides ---
  // The oracle trims field names, values and tokens with String.prototype.trim /
  // trimStart, which strip every Unicode White_Space code point and U+FEFF. A
  // port that trims ASCII only decides these differently; see the README.
  add("unicode_whitespace", "bom-before-field-name", block("Subject: alert", "\ufeffAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example", FROM));
  add("unicode_whitespace", "nbsp-before-field-name", block("\u00a0Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", FROM));
  add(
    "unicode_whitespace",
    "nbsp-named-second-gmail-ar",
    block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "\u00a0Authentication-Results: mx.google.com; dkim=pass header.d=evil.example", FROM),
  );
  add("unicode_whitespace", "nbsp-before-authserv-id", block("Authentication-Results:\u00a0mx.google.com; dkim=pass header.d=bank.example", FROM));
  add("unicode_whitespace", "nbsp-around-result", block("Authentication-Results: mx.google.com; dkim=\u00a0pass\u00a0 header.d=bank.example", FROM));
  add("unicode_whitespace", "nbsp-around-domain", block("Authentication-Results: mx.google.com; dkim=pass header.d=\u00a0bank.example\u2003", FROM));
  add("unicode_whitespace", "nbsp-continuation-line", block("Authentication-Results: mx.google.com;", "\u00a0dkim=pass header.d=bank.example", FROM));
  add("unicode_whitespace", "line-separator-is-not-a-line-break", block("Authentication-Results: mx.google.com;\u2028dkim=pass header.d=bank.example", FROM));

  outlookSpecs(v);
  return v;
}

type Add = (group: string, name: string, headers: string | Part[], note?: string) => void;

const GMAIL_SIG = "header.s=selector1 header.b=c3ludGhl";
const gmailDKIM = (domain: string): string => `dkim=pass header.i=@${domain} ${GMAIL_SIG}`;
const gmailSPF = (mailfrom: string, ip: string): string =>
  `spf=pass (google.com: domain of ${mailfrom} designates ${ip} as permitted sender) smtp.mailfrom=${mailfrom}`;
const GMAIL_DMARC = "dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=bank.example";
const gmailAR = (...methods: string[]): string =>
  ["Authentication-Results: mx.google.com;", ...methods.map((m, i) => `       ${m}${i < methods.length - 1 ? ";" : ""}`)].join("\r\n");
const BANK_DKIM_SIGNATURE = [
  "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=bank.example; s=selector1;",
  "        h=from:to:subject:message-id; bh=c3ludGhldGlj; b=c3ludGhldGljc2lnbmF0dXJl",
].join("\r\n");

function gmailShapeSpecs(add: Add): void {
  const g = (name: string, headers: string, note?: string): void => add("gmail_shape", name, headers, note);
  const direct = gmailAR(gmailDKIM("bank.example"), gmailSPF("alerts@bank.example", "192.0.2.1"), GMAIL_DMARC);
  g(
    "gmail-direct-alert",
    block(
      "Delivered-To: synthetic.user@example.com",
      "Received: by 2002:a05:6000:1::1 with SMTP id synthetic1; Mon, 1 Jun 2026 08:00:01 -0700 (PDT)",
      "X-Received: by 2002:a05:6000:1::2 with SMTP id synthetic2; Mon, 1 Jun 2026 08:00:01 -0700 (PDT)",
      "ARC-Seal: i=1; a=rsa-sha256; t=1780326001; cv=none; d=google.com; s=arc-synthetic; b=c3ludGhldGljc2VhbA==",
      "ARC-Message-Signature: i=1; a=rsa-sha256; c=relaxed/relaxed; d=google.com; s=arc-synthetic;",
      "        h=subject:to:from:message-id:dkim-signature; bh=c3ludGhldGlj; b=c3ludGhldGljbXNn",
      "ARC-" + direct.replace("mx.google.com;", "i=1; mx.google.com;"),
      "Return-Path: <alerts@bank.example>",
      "Received: from mail.bank.example (mail.bank.example. [192.0.2.1])",
      "        by mx.google.com with ESMTPS id synthetic3",
      "        for <synthetic.user@example.com>",
      "        (version=TLS1_3 cipher=TLS_AES_256_GCM_SHA384 bits=256/256);",
      "        Mon, 01 Jun 2026 08:00:01 -0700 (PDT)",
      "Received-SPF: pass (google.com: domain of alerts@bank.example designates 192.0.2.1 as permitted sender) client-ip=192.0.2.1;",
      direct,
      BANK_DKIM_SIGNATURE,
      FROM,
      "To: synthetic.user@example.com",
      SUBJECT,
      "Message-ID: <synthetic.1@bank.example>",
    ),
    "The block Gmail delivers for a direct bank alert: DKIM is reported as header.i=@<domain> with header.s and header.b, never header.d.",
  );
  const forwardedAR = (dkim: string, arc: string, dmarc: string): string =>
    gmailAR(dkim, arc, gmailSPF("user@forwarder.example", "192.0.2.7"), dmarc);
  const forwarded = (ar: string): string =>
    block(
      "Delivered-To: synthetic.user@example.com",
      "ARC-Seal: i=2; a=rsa-sha256; t=1780326002; cv=pass; d=google.com; s=arc-synthetic; b=c3ludGhldGljc2VhbDI=",
      "ARC-" + ar.replace("mx.google.com;", "i=2; mx.google.com;"),
      "Return-Path: <user@forwarder.example>",
      "Received: from mx.forwarder.example (mx.forwarder.example. [192.0.2.7]) by mx.google.com with ESMTPS id synthetic4; Mon, 01 Jun 2026 08:00:02 -0700 (PDT)",
      "Received-SPF: pass (google.com: domain of user@forwarder.example designates 192.0.2.7 as permitted sender) client-ip=192.0.2.7;",
      ar,
      "ARC-Seal: i=1; a=rsa-sha256; cv=none; d=forwarder.example; s=arc-1; b=c3ludGhldGljZndk",
      "ARC-Authentication-Results: i=1; mx.forwarder.example; dkim=pass header.d=bank.example header.i=@bank.example header.b=c3ludGhl; dmarc=pass header.from=bank.example",
      "Received: from mail.bank.example (mail.bank.example [192.0.2.1]) by mx.forwarder.example with ESMTPS; Mon, 01 Jun 2026 08:00:01 -0700",
      "Authentication-Results: mx.forwarder.example; dkim=pass header.d=bank.example header.i=@bank.example header.b=c3ludGhl; spf=pass smtp.mailfrom=alerts@bank.example; dmarc=pass header.from=bank.example",
      BANK_DKIM_SIGNATURE,
      FROM,
      "To: user@forwarder.example",
      SUBJECT,
    );
  g(
    "gmail-forwarded-alert",
    forwarded(
      forwardedAR(
        gmailDKIM("bank.example"),
        "arc=pass (i=1 spf=pass spfdomain=bank.example dkim=pass dkdomain=bank.example dmarc=pass fromdomain=bank.example)",
        "dmarc=pass (p=REJECT sp=NONE dis=NONE) header.from=bank.example",
      ),
    ),
    "Another mailbox forwarded a genuine alert into Gmail; the bank's DKIM survived, and the forwarder's own A-Rs are below Gmail's.",
  );
  g(
    "gmail-forwarded-dkim-broken",
    forwarded(
      forwardedAR(
        "dkim=neutral (body hash did not verify) header.i=@bank.example " + GMAIL_SIG,
        "arc=pass (i=1 spf=pass spfdomain=bank.example dkim=pass dkdomain=bank.example dmarc=pass fromdomain=bank.example)",
        "dmarc=fail (p=REJECT sp=NONE dis=NONE) header.from=bank.example",
      ),
    ),
    "The forwarder changed the body: the forwarder's pass below and ARC are not read, so the message goes to review.",
  );
  g("gmail-header-i-only", block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example", FROM));
  g("gmail-header-i-with-local-part", block("Authentication-Results: mx.google.com; dkim=pass header.i=alerts@bank.example", FROM));
  g("gmail-header-i-upper-case", block("Authentication-Results: mx.google.com; dkim=pass HEADER.I=@Bank.Example", FROM));
  g("gmail-header-i-subdomain-of-from", block("Authentication-Results: mx.google.com; dkim=pass header.i=@mail.bank.example", FROM));
  g("gmail-from-subdomain-of-header-i", block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example", fromAt("mail.bank.example")));
  g(
    "gmail-esp-then-bank-signature",
    block(
      gmailAR(
        "dkim=pass header.i=@esp.example header.s=s1 header.b=ZXNwc2ln",
        "dkim=pass header.i=@bank.example header.s=s2 header.b=YmFua3Np",
        gmailSPF("bounce@esp.example", "192.0.2.9"),
        GMAIL_DMARC,
      ),
      FROM,
    ),
  );
  g(
    "gmail-esp-signature-with-spf-aligned-dmarc",
    block(gmailAR("dkim=pass header.i=@esp.example header.s=s1 header.b=ZXNwc2ln", gmailSPF("bounce@bank.example", "192.0.2.9"), GMAIL_DMARC), FROM),
    "DMARC passes on SPF alone; the only DKIM pass is the ESP's.",
  );
  g(
    "gmail-dkim-fail-with-spf-aligned-dmarc",
    block(gmailAR("dkim=fail header.i=@bank.example " + GMAIL_SIG, gmailSPF("alerts@bank.example", "192.0.2.1"), GMAIL_DMARC), FROM),
  );
  g("gmail-header-i-sibling-of-from", block("Authentication-Results: mx.google.com; dkim=pass header.i=@notbank.example", FROM));
  g("gmail-header-i-suffix-without-dot", block("Authentication-Results: mx.google.com; dkim=pass header.i=@ank.example", FROM));
  g("gmail-header-i-look-alike", block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example.evil.example", FROM));
  g("gmail-from-look-alike", block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example", fromAt("bank.example.evil.example")));
  g(
    "gmail-header-i-quoted-local-part",
    block('Authentication-Results: mx.google.com; dkim=pass header.i="alerts@bank.example"@evil.example', FROM),
    "The domain of an AUID is what follows its last '@'.",
  );
  g("gmail-header-i-empty-domain", block("Authentication-Results: mx.google.com; dkim=pass header.i=@", FROM));
  g(
    "gmail-header-d-decides-over-header-i",
    block("Authentication-Results: mx.google.com; dkim=pass header.d=evil.example header.i=@bank.example", FROM),
    "header.i is read only when the method has no header.d.",
  );
  g("gmail-invalid-header-d-no-fallback", block("Authentication-Results: mx.google.com; dkim=pass header.d=localhost header.i=@bank.example", FROM));
  g("gmail-header-i-repeated-last-wins", block("Authentication-Results: mx.google.com; dkim=pass header.i=@evil.example header.i=@bank.example", FROM));
  g(
    "gmail-header-i-repeated-last-wins-unaligned",
    block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example header.i=@evil.example", FROM),
  );
  g("gmail-header-i-no-from", block(direct, SUBJECT));
  g("gmail-header-i-two-from-fields", block(direct, FROM, FROM));
  g("gmail-shape-copy-above", block(direct, direct, FROM), "A sender-written copy of Gmail's A-R is a second mx.google.com A-R.");
  g("gmail-shape-foreign-above", block("Authentication-Results: relay.example; dkim=pass header.i=@bank.example", direct, FROM));
}

// --- Outlook.com: outlookVerdict (WP1 decision §3) ---

/** EOP's inbound A-R, Microsoft form (no authserv-id), as Microsoft documents it. */
const MS_AR = [
  "Authentication-Results: spf=pass (sender IP is 192.0.2.1)",
  " smtp.mailfrom=bank.example; dkim=pass (signature was verified)",
  " header.d=bank.example;dmarc=pass action=none",
  " header.from=bank.example;compauth=pass reason=100",
].join("\r\n");
const msAR = (spf: string, dkim: string, dmarc: string, compauth: string): string =>
  `Authentication-Results: ${[spf, dkim, dmarc, compauth].filter((x) => x !== "").join("; ")}`;
const AUTH_AS = "X-MS-Exchange-Organization-AuthAs: Anonymous";
const AUTH_SOURCE = "X-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com";
const RECEIVED = "Received: from mail.bank.example (192.0.2.1) by AM0PR01MB0001.eurprd01.prod.outlook.com; Mon, 1 Jun 2026 00:00:00 +0000";
const SUBJECT = "Subject: Transaction alert";

function outlookSpecs(v: VectorSpec[]): void {
  const add = (name: string, headers: string | Part[], note?: string): void => {
    const group = "outlook";
    v.push(note === undefined ? { name, group, provider: "outlook", headers } : { name, group, provider: "outlook", note, headers });
  };
  const ok = (ar: string): string => block(RECEIVED, ar, AUTH_AS, AUTH_SOURCE, FROM, SUBJECT);
  const spf = "spf=pass smtp.mailfrom=bank.example";
  const dkim = "dkim=pass header.d=bank.example";
  const dmarc = "dmarc=pass action=none header.from=bank.example";
  const comp = "compauth=pass reason=100";

  // pass, and what falls short of it
  add("outlook-pass", ok(MS_AR), "EOP's A-R topmost, EOP fields present, compauth=pass and dmarc=pass for the From domain.");
  add("outlook-pass-dkim-fail-spf-fail", ok(msAR("spf=fail smtp.mailfrom=bank.example", "dkim=fail header.d=bank.example", dmarc, comp)), "SPF and DKIM are not trust inputs.");
  add("outlook-dmarc-fail", ok(msAR(spf, dkim, "dmarc=fail action=oreject header.from=bank.example", "compauth=fail reason=000")));
  add("outlook-dmarc-bestguesspass", ok(msAR(spf, dkim, "dmarc=bestguesspass action=none header.from=bank.example", comp)), "bestguesspass is not a pass.");
  add("outlook-compauth-fail", ok(msAR(spf, dkim, dmarc, "compauth=fail reason=001")));
  add("outlook-compauth-softpass", ok(msAR(spf, dkim, dmarc, "compauth=softpass reason=201")), "softpass is not a pass.");
  add("outlook-compauth-missing", ok(msAR(spf, dkim, dmarc, "")));
  add("outlook-dmarc-twice", ok(msAR(spf, dkim, dmarc, comp) + "; dmarc=pass header.from=bank.example"), "Each required method exactly once.");
  add("outlook-dmarc-pass-without-header-from", ok(msAR(spf, dkim, "dmarc=pass action=none", comp)));
  add("outlook-spf-pass-only", ok(msAR(spf, "", "", "")), "spf=pass is a method in Microsoft form, never an authserv-id, and never trust.");

  // position: forged A-Rs
  const forged = msAR(spf, dkim, dmarc, comp);
  const realFail = msAR("spf=fail smtp.mailfrom=evil.example", "dkim=none", "dmarc=fail action=none header.from=bank.example", "compauth=fail reason=000");
  add("outlook-forged-ms-ar-above", block(RECEIVED, forged, realFail, AUTH_AS, AUTH_SOURCE, FROM), "A sender-written Microsoft-form A-R above EOP's.");
  add("outlook-forged-ms-ar-below", block(RECEIVED, realFail, AUTH_AS, AUTH_SOURCE, FROM, forged), "A sender-written Microsoft-form A-R below EOP's.");
  add("outlook-authserv-id-ar-above", block(RECEIVED, "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", MS_AR, AUTH_AS, AUTH_SOURCE, FROM));
  add("outlook-authserv-id-ar-below", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "Authentication-Results: relay.evil.example; dkim=fail", FROM), "An authserv-id A-R below EOP's is not read.");

  // no A-R this rule reads
  add("outlook-no-ar", block(RECEIVED, AUTH_AS, AUTH_SOURCE, FROM, SUBJECT));
  add("outlook-only-authserv-id-ar", block(RECEIVED, "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example; dmarc=pass header.from=bank.example", AUTH_AS, AUTH_SOURCE, FROM), "A Gmail-trusted block is not an Outlook one.");
  add("outlook-arc-ar-only", block(RECEIVED, "ARC-" + MS_AR, AUTH_AS, AUTH_SOURCE, FROM), "ARC-Authentication-Results is not an A-R.");
  add("outlook-empty-first-segment", block(RECEIVED, "Authentication-Results: ; dmarc=pass header.from=bank.example; compauth=pass", AUTH_AS, AUTH_SOURCE, FROM), "An empty first segment is an (empty) authserv-id, not Microsoft form.");
  add("outlook-comment-before-first-method", block(RECEIVED, "Authentication-Results: (EOP) spf=pass smtp.mailfrom=bank.example; dmarc=pass header.from=bank.example; compauth=pass reason=100", AUTH_AS, AUTH_SOURCE, FROM), "Comments are stripped before the form is decided.");

  // EOP proof
  add("outlook-authas-missing", block(RECEIVED, MS_AR, AUTH_SOURCE, FROM), "The missing EOP corroborating header.");
  add("outlook-authsource-missing", block(RECEIVED, MS_AR, AUTH_AS, FROM));
  add("outlook-authas-internal", block(RECEIVED, MS_AR, "X-MS-Exchange-Organization-AuthAs: Internal", AUTH_SOURCE, FROM));
  add("outlook-authas-twice", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "X-MS-Exchange-Organization-AuthAs: Anonymous", FROM));
  add("outlook-authsource-twice", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, AUTH_SOURCE, FROM));
  add("outlook-authsource-foreign", block(RECEIVED, MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: relay.evil.example", FROM));
  add("outlook-authsource-suffix-lookalike", block(RECEIVED, MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: prod.outlook.com.evil.example", FROM));
  add("outlook-authsource-bare-suffix", block(RECEIVED, MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: .prod.outlook.com", FROM), "The suffix alone is not an LDH name.");
  add("outlook-authsource-with-port", block(RECEIVED, MS_AR, AUTH_AS, "X-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com:25", FROM));
  add("outlook-x-original-authas-is-not-authas", block(RECEIVED, MS_AR, "X-Original-X-MS-Exchange-Organization-AuthAs: Anonymous", AUTH_SOURCE, FROM), "Field names match exactly.");
  add("outlook-eop-fields-case-folded", block(RECEIVED, MS_AR, "x-ms-exchange-organization-authas:   ANONYMOUS  ", "X-MS-EXCHANGE-ORGANIZATION-AUTHSOURCE: am0pr01mb0001.EURPRD01.PROD.OUTLOOK.COM", FROM));
  add("outlook-eop-value-nbsp-trimmed", block(RECEIVED, MS_AR, "X-MS-Exchange-Organization-AuthAs:\u00a0Anonymous\u00a0", AUTH_SOURCE, FROM), "JavaScript trim() strips U+00A0.");

  // From binding
  add("outlook-from-domain-mismatch", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "From: Bank <alerts@evil.example>"), "compauth evaluated a domain that is not this From's.");
  add("outlook-from-subdomain-mismatch", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "From: Bank <alerts@mail.bank.example>"), "Exact domain match: no organisational-domain relaxation.");
  add("outlook-two-from-fields", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, FROM, "From: x@evil.example"));
  add("outlook-no-from", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, SUBJECT));
  add("outlook-from-bare-upper-case-trailing-dot", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "From: ALERTS@BANK.EXAMPLE."));
  add("outlook-from-comment-is-not-the-address", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, "From: alerts@evil.example (alerts@bank.example)"), "The domain is the addr-spec's, comments removed.");
  add("outlook-from-display-name-at-sign", block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, 'From: "alerts@bank.example" <x@evil.example>'), "The domain is after the LAST '@'.");
  add("outlook-header-from-address", block(RECEIVED, msAR(spf, dkim, "dmarc=pass action=none header.from=alerts@Bank.Example", comp), AUTH_AS, AUTH_SOURCE, FROM), "header.from is reduced to a lower-case domain.");

  // forwarded
  add(
    "outlook-forwarded",
    block(
      "Received: from relay.forwarder.example (198.51.100.7) by AM0PR01MB0001.eurprd01.prod.outlook.com",
      msAR("spf=fail (sender IP is 198.51.100.7) smtp.mailfrom=bank.example", "dkim=pass (signature was verified) header.d=bank.example", dmarc, "compauth=pass reason=100"),
      AUTH_AS,
      AUTH_SOURCE,
      "ARC-Authentication-Results: i=1; mx.forwarder.example; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.forwarder.example; dkim=pass header.d=bank.example",
      "Received: from mail.bank.example (192.0.2.1) by mx.forwarder.example",
      FROM,
      SUBJECT,
    ),
    "A genuine alert forwarded from another mailbox: DKIM survived, so DMARC passes at EOP.",
  );
  add(
    "outlook-forwarded-dkim-broken",
    block(
      "Received: from relay.forwarder.example (198.51.100.7) by AM0PR01MB0001.eurprd01.prod.outlook.com",
      msAR("spf=fail smtp.mailfrom=bank.example", "dkim=fail (body hash did not verify) header.d=bank.example", "dmarc=fail action=none header.from=bank.example", "compauth=fail reason=000"),
      AUTH_AS,
      AUTH_SOURCE,
      "Authentication-Results: mx.forwarder.example; dkim=pass header.d=bank.example",
      FROM,
    ),
    "The forwarder's pass below is not read; EOP's fail decides, so the message goes to review.",
  );

  // structure and bounds
  add("outlook-lf-line-endings", [RECEIVED, MS_AR.replaceAll("\r\n", "\n"), AUTH_AS, AUTH_SOURCE, FROM].join("\n") + "\n\n");
  add("outlook-ar-after-blank-line-is-body", block(RECEIVED, AUTH_AS, AUTH_SOURCE, FROM) + MS_AR + "\r\n");
  add("outlook-empty-input", "");
  const limit = 256 * 1024;
  const head = block(RECEIVED, MS_AR, AUTH_AS, AUTH_SOURCE, FROM).slice(0, -2);
  const pad = (total: number): Part[] => [
    { text: head, repeat: 1 },
    { text: "X-Pad: ", repeat: 1 },
    { text: "a", repeat: total - head.length - "X-Pad: ".length - 4 },
    { text: "\r\n\r\n", repeat: 1 },
  ];
  add("outlook-exactly-256-kib", pad(limit), "262144 characters, the largest block that is parsed.");
  add("outlook-one-past-256-kib", pad(limit + 1), "262145 characters: refused before parsing.");
  const folds = (n: number): Part[] => [
    { text: "Authentication-Results: spf=pass smtp.mailfrom=bank.example;\r\n", repeat: 1 },
    { text: "\tdkim=none;\r\n", repeat: n - 2 },
    { text: "\tdmarc=pass header.from=bank.example;\r\n\tcompauth=pass reason=100\r\n", repeat: 1 },
    { text: [AUTH_AS, AUTH_SOURCE, FROM].join("\r\n") + "\r\n\r\n", repeat: 1 },
  ];
  add("outlook-512-continuation-lines", folds(512), "A field may have 512 continuation lines.");
  add("outlook-513-continuation-lines", folds(513), "The 513th continuation line refuses the whole block.");
}

export function buildVectors(): Vector[] {
  return specs().map((s) => {
    const raw = typeof s.headers === "string" ? s.headers : expand(s.headers);
    const { verdict, domain } = analyzeFor(raw, s.provider);
    return {
      name: s.name,
      group: s.group,
      // The Gmail vectors predate the field and keep their schema-1 bytes.
      ...(s.provider === "gmail" ? {} : { provider: s.provider }),
      ...(s.note === undefined ? {} : { note: s.note }),
      ...(typeof s.headers === "string" ? { headers: s.headers } : { headers_parts: s.headers }),
      expect: { trusted: verdict.trusted, reason: verdict.reason, domain },
    };
  });
}

const NOTE =
  "Written by reference/ledgerd-client/scripts/gen-authres-conformance.ts from the TypeScript oracle (src/mail/authres.ts); do not hand-edit. " +
  "Each vector is one header block: `headers`, or `headers_parts` (concatenate each part's `text` repeated `repeat` times). " +
  "`provider` is \"outlook\" for an Outlook.com vector and absent for a Gmail one. " +
  "`expect` is that provider's verdict {trusted, reason} and verified domain (gmailVerdict / outlookVerdict, verifiedDomain). All inputs are synthetic. See README.md.";

export function build(): FixtureFile[] {
  const vectors = buildVectors();
  const names = new Set<string>();
  for (const x of vectors) {
    if (names.has(x.name)) throw new Error(`duplicate vector name ${x.name}`);
    names.add(x.name);
  }
  return [
    {
      file: "vectors.json",
      text: asciiJSON({
        note: NOTE,
        schema_version: 2,
        authserv_id: "mx.google.com",
        outlook: {
          auth_as_field: "X-MS-Exchange-Organization-AuthAs",
          auth_as_values: ["anonymous"],
          auth_source_field: "X-MS-Exchange-Organization-AuthSource",
          auth_source_suffix: ".prod.outlook.com",
          required: { compauth: "pass", dmarc: "pass" },
        },
        limits: { max_raw_utf16_units: 256 * 1024, max_continuation_lines: 512 },
        providers: ["gmail", "outlook"],
        reasons: AR_REASONS,
        vectors,
      }),
    },
  ];
}

export async function assertAuthresFresh(): Promise<void> {
  await assertFresh(SUITE, build(), REGENERATE);
}

if (import.meta.main) {
  await writeOrCheck(SUITE, build(), REGENERATE);
}
