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

The expected output is also a golden file: the Swift test rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`).

Generation is deterministic; `src/mail/authres-conformance.test.ts` fails when
the committed file differs from what the generator writes, and runs in
`scripts/check.sh`.

## The Gmail rule

Trusted only when exactly one `Authentication-Results` field has authserv-id
`mx.google.com`, it is the topmost `Authentication-Results` field, and it
reports `dkim=pass` with a valid DKIM domain aligned with the domain of the
one `From` field: equal to it, a parent of it, or (when the From domain has
at least two labels) a subdomain of it. The DKIM domain is `header.d` when the
method spec has one, else the domain of `header.i` (RFC 6376 §3.5; Gmail
writes only `header.i`). Every `dmarc` method spec in that field must carry a
`header.from` equal to the From domain, whatever its result; `dmarc=pass` and
`spf=pass` never trust on their own, because DMARC can pass on SPF alone. The
verified domain is the DKIM domain of the first aligned passing `dkim`; a
domain must be a lower-case LDH name with at least two labels after stripping
everything through the last `@`.

The From domain is read from the one mailbox's addr-spec with comments
removed: inside the one angle-addr when there is one, after the last `@`
outside a quoted string, spaces and tabs trimmed, ASCII lower-cased, trailing
dots dropped. It is empty (so nothing aligns) when the value has an
unreadable comment or quote, more than one `<` or `>`, a top-level `,`, no
`@`, or a domain with anything but letters, digits, `.` and `-`.

Every `Authentication-Results` field must be readable, or the block is
`parse_error`: no `"` inside a comment, no `)` outside one, no comment or
quoted string left open, and every `;`-segment after the authserv-id (every
segment, in Microsoft form) is `none` or a `method=result` followed only by
`ptype.property=value` tokens.

Anything else is untrusted with one of the reasons below, and the decision
never throws.

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
7. not exactly one `From` field, or its domain (read as in the Gmail rule) is
   not the DMARC `header.from`: `fail`;
8. trusted (`pass`); the verified domain is the DMARC `header.from`.

SPF and DKIM are parsed but are not trust inputs; ARC is ignored. The rule's
constants are in the document's `outlook` object.

The rule is fail-closed, but two of its premises (EOP stamps exactly one
Microsoft-form A-R, topmost; Graph's `$value` keeps header order) are
UNVERIFIED until the owner's real-mail checks (C1–C7 of the decision). The
Outlook lane does not use this verdict: it uses the sender rule of the
decision's §3a (`conformance/outlook-sender`). This rule stays as the reading
of the owner's trust checks. When the samples tighten or loosen it, change the
oracle, then regenerate; every vector's expectation follows.

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
  "reasons": ["pass", "no_ar", "multiple_ar", "not_topmost", "fail", "parse_error", "no_eop",
              "not_inbox", "unknown_sender", "no_dmarc_reject"],
  "vectors": [
    {
      "name": "…",
      "group": "goldens | structure | domain | gmail_shape | bounds | unicode_whitespace | outlook",
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
  reads this list and checks it. `not_inbox`, `unknown_sender` and
  `no_dmarc_reject` come from the Outlook sender rule
  (`conformance/outlook-sender`); no vector here gives them.
- `expect.domain` is `verifiedDomain(block, provider)`: a string exactly when
  `trusted`.
- Non-ASCII code points are written as `\uXXXX` escapes.

## Groups

The first six groups are Gmail's; `outlook` holds every Outlook.com vector.

- `goldens`: the twenty hand-written cases of `src/mail/authres.test.ts`.
- `structure`: line endings, folding, field boundaries, quoting and comments.
- `domain`: which domain is reported, and which are refused.
- `gmail_shape`: the blocks Gmail itself writes (DKIM as `header.i=@<domain>`
  with `header.s` and `header.b`, no `header.d`): a direct alert, an alert
  another mailbox forwarded into Gmail (with ARC and the forwarder's own A-Rs
  below), and the near misses that must stay untrusted: an ESP's signature with
  SPF-aligned DMARC, a failed or broken signature, sibling, suffix and look-alike
  domains, an AUID whose last `@` names another domain, a `header.d` that
  decides over `header.i`, no or two `From` fields, and a copied or foreign A-R
  above Gmail's.
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
