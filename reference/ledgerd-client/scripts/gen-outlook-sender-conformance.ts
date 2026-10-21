import { analyzeOutlookSender, type OutlookSenderContext } from "../src/mail/authres";
import { asciiJSON, assertFresh, writeOrCheck, type FixtureFile } from "./conformance-io";
import { expand, type Part } from "./gen-authres-conformance";

export const SUITE = "outlook-sender";
const REGENERATE = "bun run gen-outlook-sender-conformance";

export const KNOWN_SENDERS = ["alerts@bank.example", "Notices@Bank.Example", "alerts@sub.bank.example", "alerts@weak.example", "pay@other.example"];
export const REJECT_DOMAINS = ["bank.example", "Other.Example"];

interface VectorSpec {
  name: string;
  inInbox: boolean;
  note?: string;
  headers: string | Part[];
}

export interface Vector {
  name: string;
  in_inbox: boolean;
  note?: string;
  headers?: string;
  headers_parts?: Part[];
  expect: { trusted: boolean; reason: string; domain: string | null };
}

const block = (...lines: string[]): string => lines.join("\r\n") + "\r\n\r\n";
const RECEIVED = "Received: from mail.bank.example (192.0.2.1) by AM0PR01MB0001.eurprd01.prod.outlook.com; Mon, 1 Jun 2026 00:00:00 +0000";
const SUBJECT = "Subject: Transaction alert";
const FROM = "From: Bank <alerts@bank.example>";
const MS_AR_FAIL =
  "Authentication-Results: spf=fail smtp.mailfrom=bank.example; dkim=fail header.d=bank.example; dmarc=fail action=oreject header.from=bank.example; compauth=fail reason=000";
const EOP = ["X-MS-Exchange-Organization-AuthAs: Anonymous", "X-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com"];

function specs(): VectorSpec[] {
  const v: VectorSpec[] = [];
  const add = (name: string, headers: string | Part[], note?: string, inInbox = true): void => {
    v.push(note === undefined ? { name, inInbox, headers } : { name, inInbox, note, headers });
  };
  const from = (value: string): string => block(RECEIVED, `From: ${value}`, SUBJECT);

  add("pass-display-name-and-angle-address", from("Bank <alerts@bank.example>"));
  add("pass-bare-address", from("alerts@bank.example"));
  add("pass-angle-address-only", from("<alerts@bank.example>"));
  add("pass-upper-case-address", from("Bank <ALERTS@BANK.EXAMPLE>"), "Known senders match ASCII case-insensitively, the local part included.");
  add("pass-known-sender-written-in-mixed-case", from("<notices@bank.example>"), "The list has Notices@Bank.Example.");
  add("pass-reject-domain-written-in-upper-case", from("Pay <pay@other.example>"), "The p=reject list has Other.Example.");
  add("pass-quoted-display-name-with-an-address", from('"x@evil.example" <alerts@bank.example>'), "A quoted display name is not read.");
  add("pass-quoted-display-name-with-escapes", from('"Bank \\"Alerts\\" <x@evil.example>" <alerts@bank.example>'));
  add("pass-encoded-word-display-name", from("=?UTF-8?B?QmFuaw==?= <alerts@bank.example>"));
  add("pass-comment-after-address", from("alerts@bank.example (Bank alerts)"));
  add("pass-comment-holding-an-address", from("Bank (x@evil.example) <alerts@bank.example>"), "Comments are removed first.");
  add("pass-folded-from", block(RECEIVED, "From: Bank", " <alerts@bank.example>", SUBJECT));
  add("pass-nbsp-inside-angle-brackets", from("Bank < alerts@bank.example >"), "JavaScript trim() strips U+00A0.");
  add("pass-field-name-case-and-padding", block(RECEIVED, "FROM : Bank <alerts@bank.example>", SUBJECT));
  add("pass-without-any-authentication-results", block(FROM, SUBJECT), "Microsoft's verdict is not read.");
  add(
    "pass-with-a-failing-microsoft-verdict",
    block(RECEIVED, MS_AR_FAIL, ...EOP, FROM, SUBJECT),
    "The rule does not read the A-R: Outlook.com put the message in the Inbox, and that is the input.",
  );
  add("pass-lf-line-endings", [RECEIVED, FROM, SUBJECT].join("\n") + "\n\n");
  add("pass-cr-line-endings", [RECEIVED, FROM, SUBJECT].join("\r") + "\r\r");
  add("pass-no-trailing-blank-line", [RECEIVED, FROM].join("\r\n"));

  add("not-inbox", block(RECEIVED, FROM, SUBJECT), "Junk, Archive, Deleted Items or any other folder.", false);
  add("not-inbox-is-decided-before-the-sender", from("x@evil.example"), undefined, false);
  add("not-inbox-on-empty-input", "", undefined, false);

  add("unknown-address-at-a-bank-domain", from("Bank <offers@bank.example>"));
  add("unknown-look-alike-domain", from("<alerts@bank.example.evil.example>"));
  add("unknown-look-alike-local-part", from("<alerts.@bank.example>"));
  add("unknown-unquoted-display-name-with-an-address", from("alerts@bank.example <x@evil.example>"));
  add("unknown-text-after-the-angle-address", from("<x@evil.example> alerts@bank.example"));
  add("unknown-two-angle-addresses", from("<alerts@bank.example> <x@evil.example>"));
  add("unknown-two-mailboxes", from("alerts@bank.example, x@evil.example"));
  add("unknown-group-syntax", from("Bank: alerts@bank.example;"));
  add("unknown-two-from-fields", block(RECEIVED, FROM, "From: x@evil.example", SUBJECT));
  add("unknown-two-identical-from-fields", block(RECEIVED, FROM, FROM, SUBJECT));
  add("unknown-no-from", block(RECEIVED, SUBJECT));
  add("unknown-empty-input", "");
  add("unknown-from-after-the-blank-line-is-body", block(RECEIVED, SUBJECT) + FROM + "\r\n");
  add("unknown-sender-field-is-not-from", block(RECEIVED, "Sender: alerts@bank.example", "From: x@evil.example", SUBJECT));
  add("unknown-x-original-from-is-not-from", block(RECEIVED, "X-Original-From: alerts@bank.example", "From: x@evil.example"));
  add("unknown-trailing-dot", from("alerts@bank.example."));
  add("unknown-unterminated-quote", from('"Bank <alerts@bank.example>'));
  add("unknown-unclosed-angle-bracket", from("Bank <alerts@bank.example"));
  add("unknown-space-inside-the-address", from("<alerts @bank.example>"));
  add("unknown-non-ascii-local-part", from("<alérts@bank.example>"));
  add("unknown-two-at-signs", from("<alerts@x@bank.example>"));
  add("unknown-empty-local-part", from("<@bank.example>"));
  add("unknown-address-literal", from("<alerts@[192.0.2.1]>"));

  add("no-dmarc-reject-domain", from("Bank <alerts@weak.example>"), "A known sender whose domain is not on the p=reject list.");
  add("no-dmarc-reject-subdomain", from("Bank <alerts@sub.bank.example>"), "Exact domains only: a subdomain's policy is sp=, which can be weaker.");

  const limit = 256 * 1024;
  const head = block(RECEIVED, FROM).slice(0, -2);
  const pad = (total: number): Part[] => [
    { text: head, repeat: 1 },
    { text: "X-Pad: ", repeat: 1 },
    { text: "a", repeat: total - head.length - "X-Pad: ".length - 4 },
    { text: "\r\n\r\n", repeat: 1 },
  ];
  add("bounds-exactly-256-kib", pad(limit), "262144 characters, the largest block that is parsed.");
  add("bounds-one-past-256-kib", pad(limit + 1), "262145 characters: refused before parsing.");
  add("bounds-one-past-256-kib-outside-the-inbox", pad(limit + 1), "The bounds come first.", false);
  const folds = (n: number): Part[] => [
    { text: "X-Folded: a\r\n", repeat: 1 },
    { text: "\tb\r\n", repeat: n },
    { text: FROM + "\r\n\r\n", repeat: 1 },
  ];
  add("bounds-512-continuation-lines", folds(512), "A field may have 512 continuation lines.");
  add("bounds-513-continuation-lines", folds(513), "The 513th continuation line refuses the whole block.");
  return v;
}

const CONTEXT = (inInbox: boolean): OutlookSenderContext => ({ inInbox, knownSenders: KNOWN_SENDERS, rejectDomains: REJECT_DOMAINS });

export function buildVectors(): Vector[] {
  return specs().map((s) => {
    const raw = typeof s.headers === "string" ? s.headers : expand(s.headers);
    const { verdict, domain } = analyzeOutlookSender(raw, CONTEXT(s.inInbox));
    return {
      name: s.name,
      in_inbox: s.inInbox,
      ...(s.note === undefined ? {} : { note: s.note }),
      ...(typeof s.headers === "string" ? { headers: s.headers } : { headers_parts: s.headers }),
      expect: { trusted: verdict.trusted, reason: verdict.reason, domain },
    };
  });
}

const NOTE =
  "Written by reference/ledgerd-client/scripts/gen-outlook-sender-conformance.ts from the TypeScript oracle (analyzeOutlookSender in src/mail/authres.ts); do not hand-edit. " +
  "Each vector is one header block (`headers`, or `headers_parts`: concatenate each part's `text` repeated `repeat` times) and whether Graph put the message in the Inbox (`in_inbox`). " +
  "Every vector uses the document's `known_senders` and `reject_domains`. All inputs are synthetic. See README.md.";

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
        known_senders: KNOWN_SENDERS,
        reject_domains: REJECT_DOMAINS,
        limits: { max_raw_utf16_units: 256 * 1024, max_continuation_lines: 512 },
        reasons: ["pass", "parse_error", "not_inbox", "unknown_sender", "no_dmarc_reject"],
        vectors,
      }),
    },
  ];
}

export async function assertOutlookSenderFresh(): Promise<void> {
  await assertFresh(SUITE, build(), REGENERATE);
}

if (import.meta.main) {
  await writeOrCheck(SUITE, build(), REGENERATE);
}
