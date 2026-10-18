# conformance/authres

The mailbox provider's `Authentication-Results` trust decision, for Gmail and
for Outlook.com: given a message's header block, is it trusted, why not, and
which domain was verified. The TypeScript reference client
(`reference/ledgerd-client/src/mail/authres.ts`: `gmailVerdict`,
`outlookVerdict`, `verifiedDomain`, `analyzeFor`) is the oracle; the Swift port
(CoreMail `AuthResults`, `analyze(_:provider:)`) must reproduce every vector
(`ios/HasalaCore/Tests/CoreMailTests/AuthResultsConformanceTests.swift`). There is no Go executor: the server
never reads mail. All header blocks are synthetic.

Regenerate (never hand-edit):

```sh
cd reference/ledgerd-client && bun run gen-authres-conformance
bun run gen-authres-conformance --check   # compare only, exit 1 if stale
```

Generation is deterministic; `src/mail/authres-conformance.test.ts` fails when
the committed file differs from what the generator writes, and runs in
`scripts/check.sh`.

## The Gmail rule

Trusted only when exactly one `Authentication-Results` field has authserv-id
`mx.google.com`, it is the topmost `Authentication-Results` field, and it
reports `dkim=pass` with a valid `header.d` domain or `dmarc=pass`. The verified
domain is the first passing DKIM `header.d`, else the passing DMARC
`header.from`; a domain must be a lower-case LDH name with at least two labels
after stripping everything through the last `@`. Anything else is untrusted
with one of the reasons below, and the decision never throws.

## The Outlook.com rule

Source: the WP1 decision `docs/decisions/outlook-mailbox.md` §3. Outlook.com's
own A-R has no authserv-id: its first `;`-segment is already a method spec
(`spf=pass …`). Such an A-R is **Microsoft form**: the first token of the first
segment (after comments are stripped) contains `=`, which an RFC 8601
authserv-id cannot. The Gmail rule never reads `spf=pass` as an authserv-id; it
sees a foreign A-R. The reading (bounds, unfolding, comments, quoting, trim and
lower-case) is the Gmail rule's. The first step that applies decides:

1. over the bounds, or unreadable: `parse_error` (empty input: `no_ar`);
2. no Microsoft-form A-R: `no_ar`;
3. more than one Microsoft-form A-R: `multiple_ar`;
4. the topmost A-R (of any form) is not the Microsoft-form one: `not_topmost`;
5. not exactly one `X-MS-Exchange-Organization-AuthAs` whose trimmed,
   lower-cased value is `anonymous`, and exactly one
   `X-MS-Exchange-Organization-AuthSource` whose trimmed, lower-cased value is
   an LDH name ending in `.prod.outlook.com`: `no_eop`;
6. on the Microsoft-form A-R, not exactly one `compauth` method with result
   exactly `pass` and exactly one `dmarc` method with result exactly `pass`
   (`bestguesspass`, `softpass` are not), or the DMARC `header.from` is not a
   valid domain: `fail`;
7. not exactly one `From` field, or its domain (after the last `@`, cut at
   `>`, whitespace, `"` or `)`, ASCII lower-cased, trailing dots dropped) is not
   the DMARC `header.from`: `fail`;
8. trusted (`pass`); the verified domain is the DMARC `header.from`.

SPF and DKIM are parsed but are not trust inputs; ARC is ignored. The rule's
constants are in the document's `outlook` object.

The rule is fail-closed, but two of its premises (EOP stamps exactly one
Microsoft-form A-R, topmost; Graph's `$value` keeps header order) are
UNVERIFIED until the owner's real-mail checks (C1–C7 of the decision). Until
they pass, the Outlook lane sends every message to review whatever this verdict
says. When the samples tighten or loosen the rule, change the oracle, then
regenerate; every vector's expectation follows.

## `vectors.json`

```json
{
  "note": "…",
  "schema_version": 2,
  "authserv_id": "mx.google.com",
  "outlook": {
    "auth_as_field": "X-MS-Exchange-Organization-AuthAs",
    "auth_as_values": ["anonymous"],
    "auth_source_field": "X-MS-Exchange-Organization-AuthSource",
    "auth_source_suffix": ".prod.outlook.com",
    "required": { "compauth": "pass", "dmarc": "pass" }
  },
  "limits": { "max_raw_utf16_units": 262144, "max_continuation_lines": 512 },
  "providers": ["gmail", "outlook"],
  "reasons": ["pass", "no_ar", "multiple_ar", "not_topmost", "fail", "parse_error", "no_eop"],
  "vectors": [
    {
      "name": "…",
      "group": "goldens | structure | domain | bounds | unicode_whitespace | outlook",
      "provider": "outlook (absent: gmail)",
      "note": "optional",
      "headers": "the header block",
      "expect": { "trusted": true, "reason": "pass", "domain": "bank.example" }
    }
  ]
}
```

- `headers` is the raw header block as a string (CRLF, LF or CR line endings,
  as given). A vector whose block is hundreds of KiB has `headers_parts`
  instead: concatenate each part's `text` repeated `repeat` times.
- `provider` is `"outlook"` on an Outlook.com vector and absent on a Gmail one
  (the Gmail vectors keep their schema-1 bytes). Run each vector through its
  provider's rule. Schema 2 added `provider`, `providers`, `outlook` and the
  reason `no_eop`; a schema-1 reader would run the Outlook vectors through the
  Gmail rule, so it must refuse schema 2.
- `reasons` is also the closed set of a v4 transaction's `gates.ar` (spec 03c
  §3.1). A fold that refuses one of them refuses a mailbox alert the lane
  authored. The Swift test `OutlookNoEOPTests.everyAuthResultsReasonFolds`
  reads this list and checks it.
- `expect.domain` is `verifiedDomain(block, provider)`: a string exactly when
  `trusted`.
- Non-ASCII code points are written as `\uXXXX` escapes.

## Groups

The first five groups are Gmail's; `outlook` holds every Outlook.com vector.

- `goldens`: the twenty hand-written cases of `src/mail/authres.test.ts`.
- `structure`: line endings, folding, field boundaries, quoting and comments.
- `domain`: which domain is reported, and which are refused.
- `bounds`: the 256 KiB input limit and the 512-continuation-line limit, at and
  one past each. The blocks are ASCII, so UTF-16 units, scalars and UTF-8
  bytes give the same length.
- `unicode_whitespace`: what the oracle decides when a field name, value or
  token is padded with non-ASCII whitespace (U+00A0, U+2003) or a BOM
  (U+FEFF). The oracle trims with JavaScript's Unicode-aware `trim()` /
  `trimStart()`; a port that trims ASCII only (as the client-core inventory
  suggests) decides some of these differently. Either match these vectors or
  record the divergence as a decision; do not inherit it silently.
- `outlook`: the Outlook.com rule. Pass (also with SPF and DKIM failing, and
  forwarded from another mailbox), each result short of an exact pass, a
  forged Microsoft-form A-R above and below EOP's (`multiple_ar`), an
  authserv-id A-R above (`not_topmost`) and below (ignored), no A-R, ARC only,
  each way the EOP fields can be missing, repeated or wrong (`no_eop`), the
  `From` binding, line endings, and both bounds at and one past each.

The oracle measures the input limit in UTF-16 code units; a port may measure
UTF-8 bytes, which is equal or stricter (fail-closed) and only matters for
non-ASCII blocks near the limit, which no vector here uses.
