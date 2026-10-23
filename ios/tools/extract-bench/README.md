# Extraction bench

Scores email readers on bank notification mail: today's templates (`templates`), general rules (`rules`), layouts learned by comparing mails (`learned`), each of those two with promo lines removed (`+promo`), and the combination (`chain`: templates first, then the two readers, confident only when they agree).

It also simulates a bank changing its emails (`reword`, `reorder`, `balance-line`, `amount-format`, `one-line`, `english`, `arabic`, `boilerplate`). Each change is applied to the later half of each sender's mail, and only that half is scored.

Real mail and labels never go in this repository. Keep them in `hasala-agent-scratch/`.

```
swift build -c release
.build/release/ExtractBench run --synthetic ../../../conformance/templates --out <dir>
.build/release/ExtractBench dump --mail <maildir> --out <corpus.jsonl>
.build/release/ExtractBench run --mail <maildir> --labels <labels.json> --out <dir> [--readers chain,templates] [--no-mutate]
```

`labels.json` maps each `.eml` file name to `{"isTransaction", "amountMinor", "currency", "merchant", "direction"}`; `merchant` is null when the email names no counterparty. The run writes `report.html`, `by-sender.txt` and `misses.jsonl` to `<dir>`.

In the table, "conf. wrong" counts readings at confidence 0.8 or more (would file with no review) that were not a transaction, or had the wrong amount, currency or merchant.
