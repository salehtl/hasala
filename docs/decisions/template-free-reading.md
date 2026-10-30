# Template-free reading of bank mail (decision record)

**Status: DECIDED by the owner (2026-10-23).** The bench that measured the options is in
`ios/tools/extract-bench`. The app work follows in later pull requests. Every example in
this file is synthetic. No real mail, merchant, amount, card, date or reference is in
this file or in the bench sources.

## The problem

The phone reads each bank notification with a template: one per sender and layout, in
`server/internal/tmpl/seed` (bundled in HasalaCore). A template reads the mail it was
written for perfectly. When the bank rewords its mail, changes a label, moves the amount
onto one line with its label, switches the language or changes the amount format, the
template stops matching, and each new mail lands in Review empty. Nothing tells us that
a template stopped matching (there is no drift tracking), so the first signal is a person
who sees a full Review queue and empty rows.

We wanted a reader that keeps working through these changes, that runs on the phone,
that is deterministic, and that does not send mail anywhere.

## What the bench measured

The bench (`ios/tools/extract-bench`, see its README) scores readers on labelled mail and
on simulated changes of the senders' layouts. It ran on the owner's real notification
mail, kept outside this repository: **405 mails, 401 from DIB and 4 from Emirates NBD**.
This is the main limitation: one bank is nearly all of the corpus, and the Emirates NBD
numbers rest on four mails.

Ten simulated changes were applied to the later half of each sender's mail, and only
that half was scored: `reword` (new label words), `reorder` (lines in another order),
`balance-line` (a new balance line next to the amount), `amount-format` (another way to
write the amount), `one-line` (label and value on one line), `english` and `arabic` (a
switch of language), `boilerplate` (promotional lines that contain amounts), and two
held-out changes, `reword-unseen` and `boilerplate-unseen`.

The first eight changes use words the readers were written to know: the reword labels
are in the rules' lexicon and the promotional lines use the promo filter's words. Their
results are therefore partly circular. The two held-out changes use labels, phrases and
promotional lines that are in no reader lexicon and not in the promo filter
(`MutationHeldOut.swift`). Keep them out of the lexicons, or they stop measuring
anything.

Readers compared:

| Reader | What it does |
|---|---|
| templates | Today's templates, unchanged. |
| rules | General English and Arabic rules: amount and currency patterns, direction words, merchant labels. No per-sender knowledge. |
| learned | Learns each sender's layouts by aligning that sender's earlier mails, then reads the fixed and variable parts of a new mail. Nothing is learned across people. |
| +promo | The same reader after promotional lines (a promotion word and a number, but no posted-transaction word) are removed. |
| chain | Templates first; a template hit is held for review when its currency is not an ISO code, or when both readers, each at 0.8 or more, agree on another amount, currency or direction. Otherwise rules and learned, each with promo lines removed. Confident only when both agree on amount, currency and stated direction, and each reader's own confidence is 0.8 or more. |

Results, as shares of the mails that are transactions (aggregate only). "Filed" is the
share of mails that would file with no review. "Confidently wrong" counts filed readings
that are not a transaction or have the wrong amount, currency or direction; a wrong or
invented merchant is counted on its own.

- On today's mail every reader found every transaction. Templates, rules and learned all
  read 99.7% of amounts and currencies correctly.
- Under `reword`, `one-line`, `english`, `arabic` and `amount-format`, templates read 0%
  to 3.2% of amounts. Rules and learned each read 99.0% to 100% of amounts under each of
  the first eight changes.
- Held out: under `reword-unseen`, rules read only 5.8% of amounts, learned 96.9%, and
  the chain 100% (it falls back to the one reader that reads). Under
  `boilerplate-unseen`, learned read 94.2% of amounts and took 3 promotional amounts for
  transactions; rules read 100%. The rules' robustness to rewording comes mostly from its
  lexicon.
- Promotional lines with amounts (`boilerplate`) misled the readers without the promo
  filter (rules 93.7% of amounts, learned 50.3%). With the filter both were back to 100%,
  but the filter knows the words that change inserts (see above).
- The chain read 100% of amounts and currencies under each of the ten changes.
- Filed with no review, by the chain (rerun 2026-10-24 with the per-reader gate, see
  below): 93.8% of today's mail; 86.8% to 99.0% under `reorder`, `balance-line`,
  `amount-format`, `one-line`, `english`, `boilerplate` and `boilerplate-unseen`; 5.4%
  under `reword` and 1.0% under `reword-unseen`; 0% of the 3 transactions under `arabic`.
  After a reword, rows are read but mostly go to Review prefilled, because the learned
  reader is not yet confident on the new layout.
- Confidently wrong readings for the chain: 0 on today's mail and 0 under each change.
  An earlier run counted 1 on today's mail, an Emirates NBD mail that states both an AED
  amount and a foreign amount. No code change removed it: its label was corrected on
  2026-10-24 to the AED amount (decision 4).
- Without templates, the combined reader alone files 80.7% of today's mail (90.1% under
  the earlier gate), with 0 confidently wrong readings.
- On the synthetic set (`--synthetic`), the chain files 93.7% of today's mail and reads
  93.0% to 100% of amounts under each change. Its confidently wrong readings are 4 under
  `amount-format` and 2 under `arabic`, all template hits that the readers could not
  confirm at 0.8 each (the synthetic senders have too few mails to learn a layout), and
  0 under each other change; the earlier gate also had 2 under `reword`.
- The template cross-check held no template hit of the real mail.
- Confidently wrong merchants: 42 on today's mail, all template hits on DIB account,
  transfer and refund notices, where the template fills the merchant with a transaction
  description, a code or an account while the mail names no counterparty. These rows
  file today. The merchant needs its own check (see Open work).
- 3 DIB mails that are not transactions are read as transactions by every reader except
  the templates. All three are pending-transfer notices. Under the gate above none of
  them files with no review; decision 3 removes them.

An earlier run of the bench, before its review, used a looser gate (the stronger
reader's confidence plus 0.05, so one strong reader could lift a weak one over 0.8),
did not cross-check templates and did not score direction. Its numbers are not used.

Clairic (a cloud model, see `cloud-suggestions.md`) was tried on synthetic mail only and
was not run on real mail. It read 93% of amounts and 55% of merchants, with 3
confidently wrong readings. The owner dropped it, and the bench no longer contains it.

## The decision

1. **Order.** Templates first, unchanged; they stay the fast path. When no template reads
   a mail, the combined reader runs: rules and learned layouts, promotional lines
   removed, gated on agreement. When it reads nothing, the row has today's empty Review
   shape. The learned reader learns from **every** mail of a sender, template hits
   included, and its layouts persist on the phone. Without that, after a bank rewords
   its mail the learner has no layout for the sender and agreement cannot reach 0.8.
2. **Filing without review.** A row may file without review only when all of today's
   trust gates pass (sender authentication and the other existing checks) **and** either
   a template read it, or the rule reader and the learned reader **each** have
   confidence 0.8 or more on their own and agree on amount, currency **and** direction
   (a direction that either reader only guessed does not count as agreement, nor does a
   debit that rests only on "transfer", "transferred", "sent" or "تحويل", nor a move that names
   money into one of your accounts and out of another). The
   combined confidence that `CombinedReader` reports is not the filing gate. The learned
   reader stays below 0.8 until it has seen a layout three times, so the first mail of an
   unlearned layout never files on its own. Otherwise the row goes to Review, prefilled
   with what was read. (2026-10-24, decided by the owner's delegate.) Since 2026-10-29 the
   trust gates have no card term: a mail with an unconfirmed recipient files on any card
   or none, and bank texts file on the same reader agreement, with no sender or card check
   ([filing-without-cards.md](filing-without-cards.md)). Since 2026-10-30 a row also waits in
   Review when either reader's amount came from the AED rule of decision 4, when any other
   amount that does not read as a balance differs from the one read, and when pending
   wording does not meet decision 3.
3. **Pending transfers are not transactions.** A notice that a transfer is pending or in
   process is disregarded. Only completed transfers and actual debit and credit notices
   count. A pending notice is followed by a completed one for the same transfer, so
   counting the pending one would count the money twice. Only a transfer notice is set
   aside this way: all its status lines say pending, or one sentence names the transfer and
   its amount with pending wording, and no wording says that money moved. A status line that
   a reader took as the merchant, or that follows an empty remark or beneficiary label, does
   not count. All other mail with pending wording goes to Review, with what was read.
   (2026-10-30.)
4. **Two currencies in one mail.** When one mail states both the AED amount debited and a
   foreign-currency amount, the transaction amount is the AED amount, because it is what
   left the account.
5. **One movement, two mails.** DIB sends a transfer notice and an account-debit alert
   for one movement. Today the app flags these pairs as possible duplicates
   (`Replay/V4/Duplicates.swift`, keyed on template ids) and the person resolves each
   pair in Review. The app will resolve such a pair itself, without the person, and must
   not count the money twice.
6. **Privacy.** Learned layouts stay on the phone. Nothing new leaves the phone; there is
   no network call and no machine-learning model. The privacy policy does not change. A
   saved layout holds no mail text (2026-10-30): only the words the readers ship with and
   the class of every other token. Other words, amounts and numbers are not kept in any
   form, not even hashed. So a merchant slot counts as varying only when its shape varies.
   Saved layouts are cleared when the link ends, and when this phone waits for a reconnect.
7. **Template cross-check.** When a template hit's amount, currency or direction differs
   from a reading that the two readers agreed on (each at 0.8 or more, on the same amount,
   currency and stated direction, with a stated currency), the row keeps the template's
   fields but goes to Review, and the `readerDisagreed` count counts it. When the two
   readers do not both reach 0.8, a template hit files as before. (2026-10-24.)
8. **ISO currencies only.** A template's currency must be an active ISO 4217 code (the
   list in `ExtractCurrency`, kept apart from the rule reader's lexicon). The template
   executor accepts only three upper-case letters as a currency, so DHS is the one AED
   alias that reaches this check, and it is read as AED. Any other code is not filed
   without review; the row goes to Review with the template's fields. (2026-10-24.)

## Rollout

- First the readers only prefill Review: a mail that no template reads arrives in Review
  with the amount, currency, direction and merchant already filled, and the person
  confirms it.
- Filing with no review (decision 2) needs the agreement of both readers, and it is
  measured on the bench before it is turned on.
- The bench stays in the repository so that each change to the readers is scored on the
  same changes again, on the owner's mail, locally.

## Open work

- Mail from more banks. The corpus is almost all DIB. Before the combined reader may file
  rows without review for another bank, it should be scored on that bank's mail.
- Drift tracking: a count, on the phone, of mails a template no longer reads, so that a
  stale template is noticed before the person sees it.
- Merchants: the combined reader sometimes names a merchant on mail that names no
  counterparty, or reads a wrong one after a reword, and the DIB account, transfer and
  refund templates fill the merchant with a description or a code. The agreement gate
  covers amount, currency and direction only, so the merchant needs its own check
  before a row files with no review.
- Held-out changes: add more phrasings that no reader knows, so that a lexicon change is
  not scored only against its own words.
