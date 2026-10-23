# conformance/merchant-group

The merchant group key (CoreCategorize `MerchantGroup(dictionary:).key(raw:)`;
build one `MerchantGroup` and reuse it, because `init` prepares the whole
dictionary): the
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
scalars). An empty subject, or one with no letter and no digit (`[\p{L}\p{N}]`,
for example `-`, `*`, `.` or `**`), has the key `""`, which means "no group": the
projection writes `merchant_group` as NULL for it, and `LedgerReader.group("")`
and `sweepRows(group: "")` return nothing. A row with no merchant (an
unparsed row, or a parsed alert with no merchant name) never shares a card, a
group sort or a reach-back with another row.

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
     `apple.com/bill`, `paddle.net`, `fs`, `2co.com`, `dd`, `dlo`, `dlocal`,
     `payu`). To judge the rest, its stars become spaces and it is cleaned
     (steps 2 and 3). The cleaned prefix decides what is kept:
     - A bare facilitator (the cleaned prefix is one token): keep the rest,
       which names the merchant (`PAYPAL *FIGMA` is `figma`). When the
       cleaned rest is empty, keep the prefix (`PAYPAL *` is `paypal`). A
       bare facilitator never becomes the key of a rest that names
       something: `PAYPAL *1PASSWORD` is `1password` and `PAYPAL *500PX` is
       `500px`.
     - A facilitator and a name (the cleaned prefix has a token after the
       facilitator): when the cleaned rest is empty or each of its tokens
       holds a digit (an order reference), keep the prefix
       (`AMZN Mktp US*2K1AB3CD4` is `amzn mktp`). Otherwise keep both: the
       prefix, a space and the rest with its stars as spaces
       (`TST CAFE ONE*ONLINE` is `tst cafe one online`, apart from
       `TST CAFE TWO*ONLINE`).
     This gives more cards, never one card for two merchants.
   - Any other prefix: keep the prefix and drop the star and the rest.
   - Repeat while a star is left.
2. Each token loses its leading and trailing ASCII characters that are not a
   letter or a digit, a leading `www.` and a trailing `.com`. Empty tokens are
   dropped.
3. While more than one token is left, the last token is dropped when it holds
   an ASCII digit (a reference, a store number or a phone number), is a
   legal suffix (`llc`, `l.l.c`, `inc`, `ltd`, `limited`, `trdg`, `fze`,
   `fzco`, `fz`, `fz-llc`, `fzllc`, `est`, `corp`, `plc`, `gmbh`) or is a
   country code (`ae`, `are`, `uae`, `us`, `usa`, `gb`, `gbr`, `uk`, `ie`,
   `irl`, `nl`, `nld`, `sg`, `sgp`, `lu`, `lux`, `au`, `aus`, `ca`, `deu`,
   `fra`, `ind`, `sa`, `sau`, `ksa`, `qa`, `qat`, `om`, `omn`, `bh`, `bhr`,
   `kw`, `kwt`, `eg`, `egy`, `hk`, `hkg`, `ch`, `che`). Only this trailing
   run is cut: a legal word inside the name stays (`ZEN INC GARDEN` is
   `zen inc garden`, apart from `ZEN GARDEN`), and the first token is
   always kept (`INC` is `inc`).
4. The tokens, joined with one space. When nothing is left, the subject with
   its stars as spaces is cleaned again; when that is empty too, the subject
   itself.
5. A subject with no letter and no digit never gets here: its key is `""`
   (no group), so a bank alert that prints `-` or `*` for a missing merchant
   shares no card.

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
  fails the test. The pairs also hold the bare facilitators
  (`PAYPAL *1PASSWORD` and `PAYPAL *500PX`, `GOOGLE*ADS…` and
  `GOOGLE*GSUITE…`, `SQ *CAFE21` and `SQ *BAR22`, `DLO*TAILSCALE` and
  `DLO*FIGMA`), the facilitators before a name (`TST CAFE ONE*ONLINE` and
  `TST CAFE TWO*ONLINE`, `SP AMAZING STORE*REF` and `SP OTHER STORE*REF`,
  `GOOGLE PLAY*WEB` and `GOOGLE CLOUD*WEB`) and a legal word inside a name
  (`ZEN INC GARDEN` and `ZEN GARDEN`).
- Non-ASCII code points are written as `\uXXXX` escapes.
