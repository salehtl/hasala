# conformance/replay

Whole op logs and the state the v3 fold produces from them. The ledgerd
TypeScript client (`src/replay`, removed after commit 9b4aae2) wrote the cases;
the Swift fold (CoreReplay) must reproduce every case. All inputs are synthetic.

Golden file: the Swift test owns the expected output and rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`). To add or change a
case, edit its input by hand, run update mode, and review the diff.

## Files

- `manifest.json`: every case in order, with its file, group and a one-line note.
- `<group>-<name>.json`: one case each.

Groups:

| group | what it covers |
| --- | --- |
| `canary` | the snapshot fingerprint canary (`replay/snapshot.ts` `CANARY`): every v3 op type in one log |
| `fx` | the logs of `conformance/fx`, with their full state rather than the FX subset |
| `fold` | causality, forks, supersede and dedup, duplicate notices and dispositions, unparsed rows, splits, edits, provenance, checkpoints, money and timestamp shapes |
| `config` | the schema-v3 configuration ops: `bank_declared`, `budget_split_set`, `category_defined` |
| `blobs` | the decode boundary: bodies that are set aside, wire-invalid ops, the schema-version floors, decode-time canonicalisation |
| `hard_stops` | the two conditions that stop a fold: an unknown newer schema version, and a seq that does not move forward |

## Case format

```json
{
  "name": "fork-later-authored-wins",
  "group": "fold",
  "note": "…",
  "schema_version": 1,
  "log": [ … ],
  "expect": { … }
}
```

Every integer that can exceed 2^53 is a decimal string (`seq`,
`writer_counter`, money, counters). Strings are written with every non-ASCII
code point escaped as `\uXXXX`; any JSON parser reads them back unchanged.

### `log`

Blobs in the order they reach the fold. Each item is one of:

- `{"seq", "writer_id", "ops": [op, …]}`: one blob whose plaintext body is
  `{"v": <the largest op "v">, "kind": "ops", "ops": [...]}`. The ops are
  exactly what the wire encoder writes (canonical `authored_at`,
  `parent_version` always present, every op valid), so a reader may either
  encode the body and decode it, or fold the ops directly. The generator checks
  that both give the same state. The stream is `hot`.
- `{"seq", "writer_id", "stream", "writer_counter", "body"}` or the same with
  `"body_base64"`: one blob given as its exact plaintext body bytes (`body` is
  the UTF-8 text; `body_base64` is used when the bytes are not valid UTF-8).
  These exercise the decoder: a body that will not decode is set aside into
  `unreadable` with this position.

An `ops` item's blob position is its `seq`, its `writer_id` and the stream
`hot`. Its `writer_counter` is not witnessed by the state, so any value works:
only an `unreadable` entry records a blob's counter, and an `ops` item always
decodes. (The generator happens to number each writer's blobs 1, 2, … and the
TypeScript reader uses 0.) A raw item's `writer_counter` is given because a
set-aside blob's `unreadable` entry does record it.

Fold each item at its `seq` the way sync does: decode the body (an unknown
newer schema version anywhere in it stops the fold, any other decode failure
sets the blob aside and still advances the cursor), then apply its ops in
order. A blob's seq must be greater than the folded cursor, or the fold stops.

### `expect`

- `error`: `null`, or `{"kind": "newer_version" | "replay_order", "at_entry": i}`
  when log item `i` must stop the fold. Nothing else is claimed for a stopped
  fold: the partially folded state is not part of the contract.
- `state`: the oracle's `serializeState` (canonical JSON: map entries as
  `[key, value]` pairs sorted by the UTF-8 bytes of the key, object keys sorted
  the same way, sets as sorted arrays, every bigint as a decimal string,
  `appliedAtCursor` omitted) **with every `anomalies[].detail` and every
  `unreadable[].reason` replaced by `""`**.
- `state_sha256`: SHA-256 of that blanked state as compact JSON (no
  whitespace, `JSON.stringify` escaping). Byte-for-byte equality with this hash
  is the pass condition; `state` is there to diff against when it fails.
- `order`: the first-declaration order of `banks` and `categories` (map
  insertion order, which `serializeState` sorts away but the projection's `ord`
  column keeps).
- `diagnostics`: the oracle's own anomaly `detail` and unreadable `reason`
  text, and `full_state_sha256` over the unblanked `serializeState`. For
  reference only; not compared.

## What is compared, and why

- **Diagnostic text is not compared.** Anomaly details and unreadable reasons
  are built from JavaScript error messages and value renderings; under decision
  A-21 (critic inventory) the Swift text is its own (Swift-canonical), and only
  the anomaly `kind`, its `at_seq`, its order, and every money and materialized
  field must match. Blanking the two text fields keeps everything else in the
  byte comparison.
- **Every integer fits Int64.** The oracle computes money in unbounded BigInt;
  the Swift fold keeps money as `Int64` (A-21). The generator refuses any case
  whose state holds an integer outside the signed 64-bit range, so no case asks
  the two to agree where they deliberately do not. `money-shapes` pins the
  largest accepted amount, `9223372036854775807`.
- **`invalid_op` and `unhandled_op` do not occur.** Both are unreachable from a
  decoded blob (the decoder refuses an invalid op first, and every op type has a
  handler); the other 19 anomaly kinds of the v3 fold each occur at least once.
- The state includes the fold's indexes (`byFingerprint`, `liveByIngestID`,
  `heads`, `pendingByCurrency`, `cursors`) because `serializeState` witnesses
  them; a fold that reaches the same transactions through different indexes
  is a divergence.

## Consumers

- Swift: `ReplayConformanceTests` (HasalaCoreConformanceTests, spec 04
  §19.7). v4 fold additions must leave every case here byte-identical (spec
  03c acceptance test 2), with diagnostic text blanked as above.

The `hard_stops` cases that need "a newer schema version" stamp it `99`, not
the oracle's `SCHEMA_VERSION + 1` (4): spec 03c makes 4 the current version, so
a v4 fold would read a `"v":4` blob instead of stopping. The oracle's check is
`v > SCHEMA_VERSION`, so its expectations are the same either way, and 99 stays
newer than any fold this suite is meant for.
