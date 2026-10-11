# conformance/authres

The Gmail `Authentication-Results` trust decision: given a message's header
block, is it trusted, why not, and which domain was verified. The TypeScript
reference client (`reference/ledgerd-client/src/mail/authres.ts`:
`gmailVerdict`, `verifiedDomain`) is the oracle; the Swift port (CoreMail
`AuthResults`) must reproduce every vector. There is no Go executor: the server
never reads mail. All header blocks are synthetic.

Regenerate (never hand-edit):

```sh
cd reference/ledgerd-client && bun run gen-authres-conformance
bun run gen-authres-conformance --check   # compare only, exit 1 if stale
```

Generation is deterministic; `src/mail/authres-conformance.test.ts` fails when
the committed file differs from what the generator writes, and runs in
`scripts/check.sh`.

## The rule

Trusted only when exactly one `Authentication-Results` field has authserv-id
`mx.google.com`, it is the topmost `Authentication-Results` field, and it
reports `dkim=pass` with a valid `header.d` domain or `dmarc=pass`. The verified
domain is the first passing DKIM `header.d`, else the passing DMARC
`header.from`; a domain must be a lower-case LDH name with at least two labels
after stripping everything through the last `@`. Anything else is untrusted
with one of the reasons below, and the decision never throws.

## `vectors.json`

```json
{
  "note": "…",
  "schema_version": 1,
  "authserv_id": "mx.google.com",
  "limits": { "max_raw_utf16_units": 262144, "max_continuation_lines": 512 },
  "reasons": ["pass", "no_ar", "multiple_ar", "not_topmost", "fail", "parse_error"],
  "vectors": [
    {
      "name": "…",
      "group": "goldens | structure | domain | bounds | unicode_whitespace",
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
- `expect.domain` is `verifiedDomain(block)`: a string exactly when `trusted`.
- Non-ASCII code points are written as `\uXXXX` escapes.

## Groups

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

The oracle measures the input limit in UTF-16 code units; a port may measure
UTF-8 bytes, which is equal or stricter (fail-closed) and only matters for
non-ASCII blocks near the limit, which no vector here uses.
