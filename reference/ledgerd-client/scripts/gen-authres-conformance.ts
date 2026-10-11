/**
 * Writes `conformance/authres/` — the Gmail Authentication-Results trust
 * decision (`src/mail/authres.ts`) as vectors the Swift port must reproduce.
 *
 * There is no Go twin (the server never reads mail), so before this suite the
 * twenty goldens in `authres.test.ts` were the only thing pinning the rule. Every
 * vector here is a synthetic header block; the expectation is computed by the
 * oracle (`gmailVerdict`, `verifiedDomain`), never written by hand.
 *
 *     cd reference/ledgerd-client && bun run gen-authres-conformance
 *     bun run gen-authres-conformance --check     # compare only
 *
 * The format is described in `conformance/authres/README.md`.
 */

import { gmailVerdict, verifiedDomain } from "../src/mail/authres";
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
  note?: string;
  headers: string | Part[];
}

export interface Vector {
  name: string;
  group: string;
  note?: string;
  headers?: string;
  headers_parts?: Part[];
  expect: { trusted: boolean; reason: string; domain: string | null };
}

/** Header lines joined with CRLF and terminated by the blank line, the wire shape. */
const block = (...lines: string[]): string => lines.join("\r\n") + "\r\n\r\n";

const FROM = "From: Bank <alerts@bank.example>";

/** Concatenates a vector's parts; what every reader does with `headers_parts`. */
export function expand(parts: readonly Part[]): string {
  let out = "";
  for (const p of parts) out += p.text.repeat(p.repeat);
  return out;
}

function specs(): VectorSpec[] {
  const v: VectorSpec[] = [];
  const add = (group: string, name: string, headers: string | Part[], note?: string): void => {
    v.push(note === undefined ? { name, group, headers } : { name, group, note, headers });
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
    "dmarc-pass-alone-domain-from-header-from",
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
  add("structure", "no-terminating-blank-line", "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example");
  add("structure", "leading-blank-line-ends-the-block", "\r\nAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n\r\n");
  add(
    "structure",
    "continuation-before-any-field-is-ignored",
    block("  dkim=pass header.d=evil.example", "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example"),
  );
  add(
    "structure",
    "line-without-colon-ends-the-field",
    block("Authentication-Results: mx.google.com; dkim=fail header.d=bank.example", "not a header line", "\tdkim=pass header.d=evil.example", FROM),
    "The continuation after a colon-less line has no open field, so it cannot extend the A-R value.",
  );
  add("structure", "space-before-colon-in-name", block("Authentication-Results : mx.google.com; dkim=pass header.d=bank.example", FROM));
  add("structure", "no-space-after-semicolons", block("Authentication-Results: mx.google.com;dkim=pass header.d=bank.example;dmarc=pass header.from=bank.example"));
  add("structure", "empty-ar-value", block("Authentication-Results:", FROM));
  add("structure", "quoted-authserv-id", block('Authentication-Results: "mx.google.com"; dkim=pass header.d=bank.example'));
  add("structure", "authserv-id-with-version", block("Authentication-Results: mx.google.com 1; dkim=pass header.d=bank.example"));
  add("structure", "authserv-id-subdomain-is-foreign", block("Authentication-Results: mx.google.com.attacker.test; dkim=pass header.d=bank.example"));
  add("structure", "no-result-none", block("Authentication-Results: mx.google.com; none", FROM));
  add("structure", "method-without-result-is-skipped", block("Authentication-Results: mx.google.com; dkim; dmarc=pass header.from=bank.example"));
  add("structure", "quoted-result", block('Authentication-Results: mx.google.com; dkim="pass" header.d=bank.example'));
  add("structure", "unclosed-comment-swallows-the-rest", block("Authentication-Results: mx.google.com; dkim=pass (unclosed header.d=bank.example"));
  add("structure", "unclosed-quote", block('Authentication-Results: mx.google.com; dkim=pass header.d="bank.example; dmarc=pass header.from=bank.example'));
  add("structure", "escaped-paren-in-comment", block("Authentication-Results: mx.google.com; dkim=pass (a \\) b) header.d=bank.example"));
  add(
    "structure",
    "x-original-ar-is-not-ar",
    block("X-Original-Authentication-Results: mx.google.com; dkim=pass header.d=evil.example", "Authentication-Results: mx.google.com; dkim=fail header.d=bank.example"),
  );
  add(
    "structure",
    "foreign-ar-below-arc-headers",
    block(
      "ARC-Authentication-Results: i=1; mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: relay.example; dkim=fail",
    ),
  );
  add(
    "structure",
    "gmail-ar-not-first-of-three",
    block(
      "Authentication-Results: relay-a.example; dkim=pass header.d=bank.example",
      "Authentication-Results: relay-b.example; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
    ),
  );

  // --- domain: which domain is reported, and what is refused ---
  add("domain", "dkim-domain-wins-over-dmarc", block("Authentication-Results: mx.google.com; dkim=pass header.d=signer.example; dmarc=pass header.from=bank.example"));
  add("domain", "first-passing-dkim-wins", block("Authentication-Results: mx.google.com; dkim=pass header.d=first.example; dkim=pass header.d=second.example"));
  add("domain", "failing-dkim-then-passing-dkim", block("Authentication-Results: mx.google.com; dkim=fail header.d=bank.example; dkim=pass header.d=other.example"));
  add("domain", "repeated-property-last-wins", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example header.d=evil.example"));
  add("domain", "property-key-case-folded", block("Authentication-Results: mx.google.com; dkim=pass HEADER.D=bank.example"));
  add("domain", "header-d-with-at-sign", block("Authentication-Results: mx.google.com; dkim=pass header.d=alerts@bank.example"));
  add("domain", "header-d-quoted", block('Authentication-Results: mx.google.com; dkim=pass header.d="bank.example"'));
  add("domain", "header-d-single-label", block("Authentication-Results: mx.google.com; dkim=pass header.d=localhost"));
  add("domain", "header-d-trailing-dot", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example."));
  add("domain", "header-d-underscore", block("Authentication-Results: mx.google.com; dkim=pass header.d=bank_alerts.example"));
  add("domain", "header-d-leading-hyphen", block("Authentication-Results: mx.google.com; dkim=pass header.d=-bank.example"));
  add("domain", "header-d-punycode", block("Authentication-Results: mx.google.com; dkim=pass header.d=xn--mgbh0fb.example"));
  add("domain", "header-d-non-ascii", block("Authentication-Results: mx.google.com; dkim=pass header.d=\u0628\u0646\u0643.example"));
  add("domain", "header-d-label-63", block(`Authentication-Results: mx.google.com; dkim=pass header.d=${"a".repeat(63)}.example`));
  add("domain", "header-d-label-64", block(`Authentication-Results: mx.google.com; dkim=pass header.d=${"a".repeat(64)}.example`));
  add(
    "domain",
    "invalid-dkim-domain-falls-back-to-dmarc",
    block("Authentication-Results: mx.google.com; dkim=pass header.d=localhost; dmarc=pass header.from=bank.example"),
  );
  add("domain", "dmarc-pass-without-header-from", block("Authentication-Results: mx.google.com; dmarc=pass"));
  add("domain", "dmarc-pass-invalid-header-from", block("Authentication-Results: mx.google.com; dmarc=pass header.from=not_a_domain"));
  add("domain", "dmarc-softfail", block("Authentication-Results: mx.google.com; dkim=neutral header.d=bank.example; dmarc=bestguesspass header.from=bank.example"));
  add("domain", "spf-pass-alone-is-not-trust", block("Authentication-Results: mx.google.com; spf=pass smtp.mailfrom=alerts@bank.example"));

  // --- bounds: the two input limits, at and past each ---
  // 256 KiB measured in UTF-16 code units by the oracle. These blocks are ASCII,
  // so UTF-16 units, scalars and UTF-8 bytes all agree on the length.
  const limit = 256 * 1024;
  const arLine = "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n";
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
    { text: "\tdkim=pass header.d=bank.example\r\n\r\n", repeat: 1 },
  ];
  add("bounds", "512-continuation-lines", folds(512), "A field may have 512 continuation lines.");
  add("bounds", "513-continuation-lines", folds(513), "The 513th continuation line refuses the whole block.");

  // --- unicode_whitespace: what JavaScript's Unicode-aware trim() decides ---
  // The oracle trims field names, values and tokens with String.prototype.trim /
  // trimStart, which strip every Unicode White_Space code point and U+FEFF. A
  // port that trims ASCII only decides these differently; see the README.
  add("unicode_whitespace", "bom-before-field-name", block("Subject: alert", "\ufeffAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example"));
  add("unicode_whitespace", "nbsp-before-field-name", block("\u00a0Authentication-Results: mx.google.com; dkim=pass header.d=bank.example"));
  add(
    "unicode_whitespace",
    "nbsp-named-second-gmail-ar",
    block("Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "\u00a0Authentication-Results: mx.google.com; dkim=pass header.d=evil.example"),
  );
  add("unicode_whitespace", "nbsp-before-authserv-id", block("Authentication-Results:\u00a0mx.google.com; dkim=pass header.d=bank.example"));
  add("unicode_whitespace", "nbsp-around-result", block("Authentication-Results: mx.google.com; dkim=\u00a0pass\u00a0 header.d=bank.example"));
  add("unicode_whitespace", "nbsp-around-domain", block("Authentication-Results: mx.google.com; dkim=pass header.d=\u00a0bank.example\u2003"));
  add("unicode_whitespace", "nbsp-continuation-line", block("Authentication-Results: mx.google.com;", "\u00a0dkim=pass header.d=bank.example"));
  add("unicode_whitespace", "line-separator-is-not-a-line-break", block("Authentication-Results: mx.google.com;\u2028dkim=pass header.d=bank.example"));
  return v;
}

export function buildVectors(): Vector[] {
  return specs().map((s) => {
    const raw = typeof s.headers === "string" ? s.headers : expand(s.headers);
    const verdict = gmailVerdict(raw);
    return {
      name: s.name,
      group: s.group,
      ...(s.note === undefined ? {} : { note: s.note }),
      ...(typeof s.headers === "string" ? { headers: s.headers } : { headers_parts: s.headers }),
      expect: { trusted: verdict.trusted, reason: verdict.reason, domain: verifiedDomain(raw) },
    };
  });
}

const NOTE =
  "Written by reference/ledgerd-client/scripts/gen-authres-conformance.ts from the TypeScript oracle (src/mail/authres.ts); do not hand-edit. " +
  "Each vector is one Gmail header block: `headers`, or `headers_parts` (concatenate each part's `text` repeated `repeat` times). " +
  "`expect` is gmailVerdict(block) {trusted, reason} and verifiedDomain(block). All inputs are synthetic. See README.md.";

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
        schema_version: 1,
        authserv_id: "mx.google.com",
        limits: { max_raw_utf16_units: 256 * 1024, max_continuation_lines: 512 },
        reasons: ["pass", "no_ar", "multiple_ar", "not_topmost", "fail", "parse_error"],
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
