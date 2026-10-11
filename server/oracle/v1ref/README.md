# oracle/v1ref — FROZEN v1 reference packages

These five packages are **copies of ledger 1.0's code, frozen at the repo split**
(tag `ledger-v2-final`) — specifically at that tag **as rewritten on 2026-08-12**,
when `salehtl/ledger` purged real transaction data from its whole history and
force-pushed. They are not part of the product. They are the reference
implementations two gates measure this repo against.

Only their **import lines** changed on the way in (`ledger/internal/X` →
`ledgerd/internal/v1ref/X`), plus one sanctioned path fix: the vendored copy
sits one directory deeper, so `importer/conformance_test.go` reads
`../../../conformance/import/vectors.json`. Everything else is byte-for-byte
what the tag holds. `parse/dib.go` changed by **zero** bytes.

## The 2026-08-12 re-freeze

The first vendoring (2026-08-11) took the tag as it stood **before** that purge,
so it carried the operator's real specimens: a full legal name, a third party's
name, a real IBAN and CIF, a real PAN and account numbers, real balances and the
operator's own mail addresses. Re-freezing from the rewritten tag replaced every
one of them with the purge's synthetic stand-ins.

**Behaviour is identical.** The purge was a literal text substitution over
history, so the change is confined to test fixtures and the specimen strings the
tests assert on — plus two doc-comment lines in `parse/enbd_alert.go` that quoted
a real alert. **No product logic differs by a single byte**, and `parse/dib.go`
is unchanged by the purge as well: `sha256` before and after are the same, and
`internal/tmpl/seed`'s anchor gate still passes. That purge deliberately left
amounts and dates alone; the 2026-10-11 publication re-freeze below replaced
them too.

Nothing about the freeze rules below is relaxed by this. The re-freeze was a
contract change, declared as one, with the manifest re-recorded in the same
commit and the corpus and import gates re-run.

## The 2026-10-11 Hasala move

When ledgerd became Hasala, the Go module moved into `server/` and was renamed
from `ledgerd` to `github.com/salehtl/hasala/server`. Two mechanical edits
reached this directory, and nothing else did:

- Import lines: `ledgerd/internal/v1ref/X` →
  `github.com/salehtl/hasala/server/internal/v1ref/X`.
- `importer/conformance_test.go` gained one more `..`, because `conformance/`
  now sits at the repo root, one level above the module:
  `../../../../conformance/import/vectors.json`.

No logic, assertion or fixture changed, and `parse/dib.go` is still
byte-identical. It is a contract change all the same, so the manifest was
re-recorded in the same commit and the import gate re-run. The corpus gate needs
the operator's corpus snapshot (`LEDGER_CORPUS_DB`) and skips without one; it was
not re-run as part of the move.

## The 2026-10-11 oracle-module move

The hasalad surgery (spec 02 §2.2, §4.3) moved this directory, with
`internal/corpus`, out of the server's module into the oracle module
`github.com/salehtl/hasala/server/oracle` (`server/oracle/v1ref`), so that the
served binary's module carries neither `modernc.org/sqlite` nor
`github.com/xuri/excelize/v2`, and `go list -deps ./cmd/hasalad` cannot reach
this code even by mistake. One mechanical edit reached this directory, and
nothing else did:

- Import lines: `github.com/salehtl/hasala/server/internal/v1ref/X` →
  `github.com/salehtl/hasala/server/oracle/v1ref/X`.

`importer/conformance_test.go`'s path to `conformance/import/vectors.json` is
unchanged: the directory sits at the same depth (`server/oracle/v1ref` instead
of `server/internal/v1ref`). No logic, assertion or fixture changed, and
`parse/dib.go` is byte-identical. It is a contract change all the same, so the
manifest was re-recorded in the same commit and the import gate re-run (it
passes). The corpus-reading gates moved with this directory to
`server/oracle/gates`; they need the operator's corpus snapshot
(`HASALA_CORPUS_DB`, formerly `LEDGER_CORPUS_DB`) and skip without one, so they
were not re-run as part of the move. The manifest switch is now
`HASALA_WRITE_V1REF_MANIFEST`.

## The 2026-10-11 publication re-freeze

Before this repository was published, every remaining value copied from the
operator's real mail was replaced with a synthetic one of the same shape. This
is a contract change, declared here, with the manifest re-recorded in the same
commit:

- Real amounts, dates and times of real transactions in the parser tests and
  two doc comments (`parse/enbd.go`, `parse/enbd_alert.go`): the ENBD transfer,
  the ENBD alerts, the DIB card purchase and its forward headers, and the DIB
  account, transfer and card messages of August 2025. Each now carries a made-up
  amount and date with the same layout (the same digit grouping, the same date
  format, the same AM/PM and seconds shape), and every assertion that read one
  of them was moved to the new value.
- The DIB transaction descriptions copied from real messages, replaced with
  `EXAMPLE …` descriptions that keep the property each test depends on (a
  `TRANSFER` substring, a `DEBIT`/`CREDIT` suffix, or neither).
- The partly-redacted ENBD and DIB account masks, which still showed real
  branch and account digits, replaced with wholly synthetic ones
  (`012XXX34XXX56`, `009-123-XXXX456-09`, `009-321-XXXX654-09`); the last4 the
  DIB test expects follows its mask.
- One synthetic salutation surname.
- A follow-up in the same re-freeze: the CSV-import and store tests
  (`importer/importer_test.go`, `importer/reader_test.go`,
  `store/import_test.go`) and one wrong-format probe in `parse/fields_test.go`
  still used 19 and 20 August 2025, the dates of real DIB messages, as sample
  dates. They now use 11 and 12 March 2025, the stand-ins the parser tests
  already use; no amount in them was real.

No product logic changed. `parse/dib.go` is byte-identical (its `sha256` in
`frozen.sha256` is unchanged), so the seed gate's anchors are unaffected; the
only non-test files touched are doc comments. The import gate
(`importer/conformance_test.go` against `conformance/import/vectors.json`, and
its TypeScript twin) was re-run and passes. The corpus gate needs the
operator's corpus snapshot (`LEDGER_CORPUS_DB`) and skips without one; it was not
re-run here and should be the next time a snapshot is to hand.

No real transaction amount, date, account digit or name remains in this
directory.

## Why each package is here

| Package | Why |
|---|---|
| `parse` | The reference parser for the **corpus-equivalence gate**. `oracle/gates/norm/corpus_test.go`, `oracle/gates/norm/corpus_probe_test.go` and `oracle/gates/tmpl/seed/corpus_gate_test.go` (originally under `internal/norm` and `internal/tmpl/seed`) run v2's parsing over the operator's 7,002-message corpus and compare it against this parser's output. |
| `importer` | The Go executor of the **import-conformance contract**, `conformance/import/vectors.json`, paired with `client/src/importer` on the TypeScript side. |
| `store` | `parse` and `importer` both need its row types. The gates use little more than `store.TransactionRow`, but the package came over whole: pruning it would risk the freeze and save no dependency (v2 already needs `modernc.org/sqlite` for `internal/corpus`). |
| `categorize` | `parse.Processor` and `importer` import it. |
| `anthropic` | `parse` and `categorize` import it. |

## Rules

- **Product code must never import these.** They live in a separate module
  that the server module never requires, and `cmd/hasalad/fence_test.go`
  (spec 02 §4.4 fence 1) fails if `go list -deps ./cmd/hasalad` names anything
  under `server/oracle`. The gates that use them live beside them, in
  `server/oracle/gates`.
- **Do not extend and do not fix.** A "bug" in here is the reference behaviour.
  Correcting it silently moves the thing the gates measure against, which is the
  one outcome vendoring exists to prevent.
- **The freeze is enforced, not promised.** `frozen.sha256` is a manifest over
  every file in this directory, and `frozen_test.go` recomputes it on every
  `go test ./...`. An edit fails that test by design. If a change here is
  genuinely intended, it is a contract change: say so out loud, re-record the
  manifest in the same commit, and re-run the corpus and import gates.
- **`parse/dib.go` is byte-frozen** on top of all that.
  `oracle/gates/tmpl/seed/corpus_gate_test.go` reads it as **raw source** and derives
  its Arabic anchors from the literal shape of the file. Reformatting it breaks
  the gate.

## The contract fork

Before the split, `conformance/import/vectors.json` was checked against v1's
**living** importer and against `client/src/importer` in one repo, so the two
languages could not drift apart without a gate noticing.

That is over. **Nothing anywhere now checks v1's living importer against
`client/src/importer`.** This repo tests the TypeScript importer against the
frozen Go copy in `v1ref/importer`; the v1 repo (`github.com/salehtl/ledger`)
tests its living importer against its own frozen copy of the vectors. The two
executors are separate products from 2026-08-11 onward and are free to diverge.
For this repo the frozen copy **is** the contract's reference — which is exactly
what a conformance reference should be, but it means a fix landed in v1's
importer does not reach the client here, and nobody is told.
