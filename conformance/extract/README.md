# conformance/extract

The template-free bank mail readers (HasalaCore `CoreExtract`). The app uses
them only for a mail that no template reads. Two deterministic readers read
each mail, and they run on the device:

- the rule reader: general English and Arabic rules for amounts, currencies,
  direction and the counterparty;
- the learned reader: it learns each sender's layouts by aligning the
  sender's mails, and reads the slots of a layout it has seen at least twice.

`CombinedReader.read(input, memory)` removes promotional lines that have
numbers, runs the two readers and applies the agreement rule. The Swift test
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/ExtractConformanceTests.swift`
must reproduce every reading. There is no Go executor: the server never
reads mail. All senders, subjects, texts, amounts and names are synthetic.

Golden file: the Swift test owns the expected output and rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`). To add or change a
case, edit its input by hand, run update mode, and review the diff.

## The rules

1. Agreement. When the two readers read the same amount and currency, the
   reading takes the more confident reader's fields (the learned
   counterparty first), and its confidence is the higher one plus 5, at most
   95. When they read different amounts or currencies, the confidence is at
   most 50. When only one reader reads a transaction, the confidence is at
   most 60. `meets_agreement_bar` is true only for an agreed transaction at
   `agreement_bar_percent` (80) or more.
2. Pending. A notice whose status (a `Status` or `الحالة` label, its value on
   the same line after a colon or on the next line) says the transfer or
   payment is pending, in process, in progress, processing, initiated, or
   `قيد التنفيذ`, `قيد المعالجة`, `جاري التنفيذ` and the like, has outcome
   `pending`. With no status line, a notice that says it has been initiated
   or is being processed and has no completed wording is `pending`. A status
   that says it is done (for example "Credited to beneficiary") wins over
   "initiated" in the text. Card purchases and refunds are never `pending`.
3. Two currencies. When a mail states an amount in AED that is debited,
   labelled or converted, and the readers chose a foreign amount, the AED
   amount is the reading's amount. Balances, limits, fees and rates do not
   count.
4. Kind. `card_purchase`, `card_refund`, `transfer_notice`,
   `account_debit_alert`, `account_credit_alert` or `other`, from the subject
   and the first three lines, then the whole text, then the direction. A
   deposit to a card is `account_credit_alert`.
5. Outcome. `transaction`; `pending`; `not_transaction` when a reader found a
   negative word near the amount (one-time password, declined, failed,
   activation, a future debit); `unknown` otherwise.
6. Hundredths. `amount_minor` is in hundredths of the major unit (schema
   v4). The readers parse a three- or zero-decimal currency with its own
   decimals, but such a reading has `amount_minor` null, so it goes to
   Review, as the templates refuse it.

## The learned memory

`LearnedLayouts` is a Codable value that the caller loads and saves. Reading
is a pure function of the memory and the mail. Its bounds are in its names:
`senderLimit` (64 senders, the least recently read is dropped),
`layoutLimitPerSender` (40, the least recently used is dropped),
`exampleLimitPerLayout` (16, the oldest is dropped) and `tokenLimitPerMail`
(400 tokens of a mail are read). A layout keeps its anchors (the words and
punctuation that all its mails share) and slot types once. Each example keeps
only what fills the slots and the gaps, with references to the anchors.

## `vectors.json`

```json
{
  "note": "…",
  "schema_version": 1,
  "agreement_bar_percent": 80,
  "limits": { "senders": 64, "layouts_per_sender": 40, "examples_per_layout": 16, "tokens_per_mail": 400 },
  "outcomes": ["transaction", "pending", "not_transaction", "unknown"],
  "kinds": ["card_purchase", "…"],
  "streams": [
    {
      "name": "…",
      "note": "…",
      "mails": [
        { "sender": "bank-a.example", "subject": "…", "text": "…", "received_at_ms": 1900000060000, "list_unsubscribe": false }
      ],
      "expect": [
        {
          "outcome": "transaction",
          "kind": "card_purchase",
          "amount_minor": 1250,
          "currency": "AED",
          "direction": "debit",
          "merchant": "SAMPLE BAKERY",
          "last4": "4821",
          "confidence_percent": 95,
          "agreed": true,
          "meets_agreement_bar": true
        }
      ]
    }
  ]
}
```

- Each stream starts with an empty memory and reads its mails in order.
  `expect` has one reading per mail.
- `text` is the normalized text (CoreNorm's output).
- Fields that a reading does not have are `null`.
- Non-ASCII code points are written as `\uXXXX` escapes.
