# conformance/merchant-group

The merchant group key (CoreCategorize `MerchantGroup.key(raw:)`): the
projection's `txn.merchant_group`, which puts the spellings of one merchant
on one Review card. The key is a function of the raw merchant string and the
bundled merchant dictionary only. User rules, the category table and the
transaction's direction are not inputs (cards group by key and direction).
There is no Go executor: the server never reads merchant names.

Golden file: the Swift test
(`ios/HasalaCore/Tests/HasalaCoreConformanceTests/MerchantGroupConformanceTests.swift`)
owns each case's `expect` and the `dictionary` header, and rewrites them with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`). A dictionary rebuild
changes the header, so its effect on the keys shows in the same diff. To add a
case, add its `name` and `raw` by hand, run update mode, and review the diff.
All merchant strings are synthetic.

## The key

`subject` is `Canon.subject(raw)` (canonical, lower case, at most 512
scalars). An empty subject has the key `""`.

1. Dictionary: the first dictionary entry that hits the subject, in the
   matcher's order (`Matcher.prepare` with no rules and no category table).
   The key is `d:` and the entry's display name, canonicalized. An entry with
   no display name gives `e:<match>:<pattern>`.
2. Otherwise the cleaned name: `n:` and the cleaned subject.

The key is at most 256 scalars.

### The cleaned name

Bytes of the subject, split on U+0020:

1. A star (`*`). The text before it is the prefix, the text after it the rest
   (both trimmed of spaces).
   - An empty prefix: keep the rest.
   - A prefix whose first token is a payment facilitator (`paypal`, `pp`,
     `google`, `sq`, `sp`, `tst`, `sumup`, `iz`, `izettle`, `zettle`, `amzn`,
     `apple.com/bill`, `paddle.net`, `fs`, `2co.com`, `dd`): keep the rest,
     which names the merchant. When the cleaned rest is empty or each of its
     tokens holds a digit (an order reference), keep the prefix.
   - Any other prefix: keep the prefix and drop the star and the rest.
   - Repeat while a star is left.
2. Each token loses its leading and trailing ASCII characters that are not a
   letter or a digit, a leading `www.` and a trailing `.com`. Empty tokens are
   dropped.
3. A legal suffix after the first token is dropped: `llc`, `l.l.c`, `inc`,
   `ltd`, `limited`, `trdg`, `fze`, `fzco`, `fz`, `fz-llc`, `fzllc`, `est`,
   `corp`, `plc`, `gmbh`.
4. While more than one token is left, the last token is dropped when it holds
   an ASCII digit (a reference, a store number or a phone number) or is a
   country code (`ae`, `are`, `uae`, `us`, `usa`, `gb`, `gbr`, `uk`, `ie`,
   `irl`, `nl`, `nld`, `sg`, `sgp`, `lu`, `lux`, `au`, `aus`, `ca`, `deu`,
   `fra`, `ind`, `sa`, `sau`, `ksa`, `qa`, `qat`, `om`, `omn`, `bh`, `bhr`,
   `kw`, `kwt`, `eg`, `egy`, `hk`, `hkg`, `ch`, `che`).
5. The tokens, joined with one space. When nothing is left, the subject
   without its stars is cleaned again; when that is empty too, the subject
   itself.

No fuzzy matching: two spellings share a key only when these steps make them
equal byte for byte. City names are kept, so branches in two cities stay two
cards.

## `vectors.json`

```json
{
  "note": "…",
  "schema_version": 1,
  "dictionary": { "bundle": "2026.10.21-1", "sha256": "…", "entries": 168 },
  "cases": [{ "name": "…", "raw": "…", "expect": { "key": "n:tailscale" } }],
  "pairs": [{ "name": "…", "a": "…", "b": "…", "same": false }]
}
```

- `dictionary` is `DictionaryManifest`: the bundle, the SHA-256 of
  `merchant-dictionary.json` and its entry count.
- `pairs` are the near misses, written and asserted by hand. Update mode never
  rewrites them: a change that makes `AL NOOR TRADING LLC` and
  `AL NOOR PHARMACY` share a key, or `PAYPAL *NETFLIX` and `PAYPAL *SPOTIFY`,
  fails the test.
- Non-ASCII code points are written as `\uXXXX` escapes.
