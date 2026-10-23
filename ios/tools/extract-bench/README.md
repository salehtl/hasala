# Extraction bench

Scores email readers on bank notification mail: today's templates (`templates`), and HasalaCore's `CoreExtract` readers, which always drop promo lines first: general rules (`rules`), layouts learned by comparing mails (`learned`), the two combined and gated on agreement (`combined`), and the app's order (`chain`: templates first, then the combined reader). The bench keeps no reader of its own; `Sources/ExtractBench/Readers.swift` only adapts `CoreExtract` to the bench.

`chain` follows `Disposition` in `CoreMailbox`, and the two share `CombinedReader.templateVerdict` and `ExtractReading.isUsable`: a template hit with a pending status is disregarded before the readers run, so it teaches no layout; a template hit with a pending phrase, whose currency is not an active ISO 4217 code (DHS reads as AED), whose AED amount the readers do not confirm, or whose amount, currency or direction differs from a reading that both readers agree on at 0.8 or more each, is held; with no template hit, the combined reading files only when it meets `ExtractReading.meetsFilingBar` (each reader at 0.8 or more on its own, agreeing on amount, currency and direction), and a pending reading is disregarded. The mail trust gates (authentication, trusted sender) are not simulated.

It also simulates a bank changing its emails (`reword`, `reorder`, `balance-line`, `amount-format`, `one-line`, `english`, `arabic`, `boilerplate`, and the held-out `reword-unseen` and `boilerplate-unseen`). Each change is applied to the later half of each sender's mail, and only that half is scored. The held-out phrasings in `MutationHeldOut.swift` must stay out of the reader lexicons and the promo filter in `CoreExtract`; `HeldOutTests` fails when one of them is added there.

With `--synthetic`, the matched cases of `conformance/templates` are transactions, and unmatched cases whose name ends in `pending`, `in-progress`, `other-status` or `balance-only` are scored as non-transactions.

Real mail and labels never go in this repository. Keep them in `hasala-agent-scratch/`.

```
swift build -c release
.build/release/ExtractBench run --synthetic ../../../conformance/templates --out <dir>
.build/release/ExtractBench dump --mail <maildir> --out <corpus.jsonl>
.build/release/ExtractBench run --mail <maildir> --labels <labels.json> --out <dir> [--readers chain,templates] [--no-mutate]
```

`labels.json` maps each `.eml` file name to `{"isTransaction", "amountMinor", "currency", "merchant", "direction"}`; `merchant` is null when the email names no counterparty. The run writes `report.html`, `by-sender.txt` and `misses.jsonl` to `<dir>`.

In the table, "filed" is the share of mails read at confidence 0.8 or more (they would file with no review). "conf. wrong" counts those readings that were not a transaction, or had the wrong amount, currency or direction. "conf. wrong merchant" counts the other filed readings with a wrong merchant, or a merchant on mail that names none.

`swift test` runs the bench's unit tests.
