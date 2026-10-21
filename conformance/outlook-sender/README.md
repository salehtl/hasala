# conformance/outlook-sender

The Outlook lane's trust rule (`docs/decisions/outlook-mailbox.md` §3a): given
a message's header block, whether Graph put it in the Inbox, the known bank
sender addresses and the domains that publish DMARC `p=reject`, is the message
taken as the bank's, why not, and which domain. The ledgerd TypeScript client
(`src/mail/authres.ts`: `analyzeOutlookSender`; removed after commit 9b4aae2)
wrote the vectors; the Swift port (CoreMail `AuthResults.analyzeOutlookSender`)
must reproduce every vector
(`ios/HasalaCore/Tests/HasalaCoreConformanceTests/OutlookSenderConformanceTests.swift`).
There is no Go executor: the server never reads mail. All header blocks,
addresses and domains are synthetic. The app's real lists are
`OutlookSenders.known` and `OutlookSenders.dmarcReject`.

Golden file: the Swift test owns the expected output and rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`). To add or change a
case, edit its input by hand, run update mode, and review the diff.

## The rule

The reading (bounds, line endings, unfolding, the blank line that ends the
block, comments, quoting, JavaScript `trim`) is the `conformance/authres`
rules'. The first step that applies decides:

1. over 256 KiB (UTF-16 code units), or a field with more than 512
   continuation lines: `parse_error`;
2. `in_inbox` is false: `not_inbox`;
3. not exactly one `From` field (name trimmed, case-insensitive), or its value
   does not hold exactly one address, or that address is not one of
   `known_senders` (ASCII case-insensitive, the local part included):
   `unknown_sender`;
4. the address's domain is not exactly one of `reject_domains` (ASCII
   case-insensitive; a subdomain does not count, because its policy is `sp=`):
   `no_dmarc_reject`;
5. trusted (`pass`); the domain is the address's domain, lower case.

The one address of a `From` value: remove comments, then remove quoted strings
(an unterminated one: no address). The rest must have no `,` or `;`. With a
`<`, it must have exactly one `<` and one `>` after it, no `@` before the `<`
and only whitespace after the `>`; the address is what is between them,
trimmed. Without a `<`, it must have no `>`, and the address is the whole value,
trimmed. The address must be printable ASCII (U+0021 to U+007E) with exactly
one `@`, a non-empty local part, and a lower-case LDH domain with at least two
labels after ASCII lower-casing.

Microsoft's `Authentication-Results` and the EOP fields are not read.

## `vectors.json`

```json
{
  "note": "…",
  "schema_version": 1,
  "known_senders": ["…"],
  "reject_domains": ["…"],
  "limits": { "max_raw_utf16_units": 262144, "max_continuation_lines": 512 },
  "reasons": ["pass", "parse_error", "not_inbox", "unknown_sender", "no_dmarc_reject"],
  "vectors": [
    {
      "name": "…",
      "in_inbox": true,
      "note": "optional",
      "headers": "the header block",
      "expect": { "trusted": true, "reason": "pass", "domain": "bank.example" }
    }
  ]
}
```

- `headers` is the raw header block. A vector whose block is hundreds of KiB
  has `headers_parts` instead: concatenate each part's `text` repeated
  `repeat` times.
- Every vector uses the document's `known_senders` and `reject_domains`.
- `reasons` are the reasons this rule can give. Each is also in
  `conformance/authres`'s `reasons`, the closed set of a v4 transaction's
  `gates.ar`.
- `expect.domain` is a string exactly when `trusted`.
- Non-ASCII code points are written as `\uXXXX` escapes.
