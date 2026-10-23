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

Eight simulated changes were applied to the later half of each sender's mail, and only
that half was scored: `reword` (new label words), `reorder` (lines in another order),
`balance-line` (a new balance line next to the amount), `amount-format` (another way to
write the amount), `one-line` (label and value on one line), `english` and `arabic` (a
switch of language) and `boilerplate` (promotional lines that contain amounts).

Readers compared:

| Reader | What it does |
|---|---|
| templates | Today's templates, unchanged. |
| rules | General English and Arabic rules: amount and currency patterns, direction words, merchant labels. No per-sender knowledge. |
| learned | Learns each sender's layouts by aligning that sender's earlier mails, then reads the fixed and variable parts of a new mail. Nothing is learned across people. |
| +promo | The same reader after promotional lines (a promotion word and a number, but no posted-transaction word) are removed. |
| chain | Templates first. Otherwise rules and learned, each with promo lines removed. Confident only when both agree on amount and currency. |

Results, as shares of the mails that are transactions (aggregate only):

- On today's mail every reader found every transaction. Templates, rules and learned all
  read 99.7% of amounts and currencies correctly.
- Under `reword`, `one-line`, `english`, `arabic` and `amount-format`, templates read 0%
  to 3.2% of amounts. Rules and learned each read 99.0% to 100% of amounts under every
  change.
- Promotional lines with amounts (`boilerplate`) misled the readers without the promo
  filter (rules 93.7% of amounts, learned 50.3%, with 9 and 4 confidently wrong
  readings). With the filter both were back to 100%.
- The chain read 100% of amounts and currencies under each of the eight changes, and
  98.9% to 100% of merchants where the mail names one.
- Confidently wrong readings (confidence 0.8 or more, so they would file with no review)
  stayed near zero for the chain: 3 on today's mail, 2 under `reword`, 0 under the other
  changes. On today's mail, one is an Emirates NBD mail that states both an AED amount and
  a foreign amount (the template misreads it too); decision 4 settles it. The other two
  are DIB notices of a pending transfer that both readers read as a transaction;
  decision 3 settles them. The two under `reword` are Emirates NBD merchants, read wrong
  with the right amount.
- 3 DIB mails that are not transactions were read as transactions by every reader except
  the templates. All three are pending-transfer notices.

Clairic (a cloud model, see `cloud-suggestions.md`) was tried on synthetic mail only and
was not run on real mail. It read 93% of amounts and 55% of merchants, with 3
confidently wrong readings. The owner dropped it, and the bench no longer contains it.

## The decision

1. **Order.** Templates first, unchanged; they stay the fast path. When no template reads
   a mail, the combined reader runs: rules and learned layouts, promotional lines
   removed, gated on agreement. When it reads nothing, the row has today's empty Review
   shape.
2. **Filing without review.** A row may file without review only when all of today's
   trust gates pass (sender authentication and the other existing checks) **and** either
   a template read it, or both readers agree on amount and currency with confidence 0.8
   or more. Otherwise the row goes to Review, prefilled with what was read.
3. **Pending transfers are not transactions.** A notice that a transfer is pending or in
   process is disregarded. Only completed transfers and actual debit and credit notices
   count. A pending notice is followed by a completed one for the same transfer, so
   counting the pending one would count the money twice.
4. **Two currencies in one mail.** When one mail states both the AED amount debited and a
   foreign-currency amount, the transaction amount is the AED amount, because it is what
   left the account.
5. **One movement, two mails.** DIB sends a transfer notice and an account-debit alert
   for one movement. Today the app flags these pairs as possible duplicates
   (`Replay/V4/Duplicates.swift`, keyed on template ids) and the person resolves each
   pair in Review. The app will resolve such a pair itself, without the person, and must
   not count the money twice.
6. **Privacy.** Learned layouts stay on the phone. Nothing new leaves the phone; there is
   no network call and no machine-learning model. The privacy policy does not change.

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
  counterparty, or reads a wrong one after a reword. The agreement gate covers amount and
  currency only, so the merchant needs its own check before a row files with no review.
