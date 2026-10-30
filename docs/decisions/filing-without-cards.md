# Filing without cards (decision record)

**Status: DECIDED (owner, 2026-10-29).** Built on `filing/no-card-gates`. This record
changes parts of [bank-texts.md](bank-texts.md), [outlook-mailbox.md](outlook-mailbox.md),
[cloud-suggestions.md](cloud-suggestions.md), [sorting-rework.md](sorting-rework.md) and
[template-free-reading.md](template-free-reading.md). Where they disagree, this record
holds. Every example is synthetic.

## Why

Hasala tried to tell the person's cards from the bank's mail and texts. A card became
"mine" when the person confirmed a payment on it in Review, and the app made an account for
it. Two gates depended on this:

- A bank text filed with no review only when its card was known and its sender matched.
- A bank mail whose recipient check was unconfirmed filed only when its card was known, and
  a card marked "not mine" never filed.

This did not work in practice:

- Card identification from mail and texts proved unreliable. Many alerts name no card
  (salaries, refunds, transfers, DIB debit-card purchases), and the account that a card
  made was a guess at its kind.
- The person never saw the card step in the journey. Setup has no cards step, and no
  screen shows the link. The accounts that it made were not used.
- The Shortcuts automation passes no sender, so the sender check never passed and no text
  ever filed. Every text waited in Review.

A spoofed text costs the person one archive. That is a small cost for a person who uses
texts, against a Review queue that holds every payment. Mail keeps its DMARC checks,
because they are strong and cost nothing.

## What was decided

1. **Card and account linking are removed from the whole app** (texts, Gmail, Outlook). No
   code path writes `card_linked`, and no code path makes an account from a card. Sorting,
   marking a transfer or a refund, splitting and Add category in Review write only their
   own ops. Their undo writes back only what they changed. `CardLinkPlan`, `confirmLink`,
   `authorCards`, `knownCards` and `OpAuthor.linkCard` are gone. The fold still reads
   `card_linked` and `account_set`, because the op log is append-only and older builds
   wrote them.
2. **A text files with no review** (`needs_review: false`) when all of these hold:
   - the automation handed it (a paste never files);
   - the account has no mailbox link (the link state is not linked);
   - its fields were read;
   - an SMS template read it, **or**, with no template, the two template-free readers agree
     on amount, currency and direction, each at 0.8 or more. This is the rule that mail
     uses (`CombinedReader`, `ExtractReading.meetsFilingBar`);
   - nothing else holds it: no reader hold on a template hit, no transfer partner, no
     one-time-code or declined marker. A text that only the readers read as a transfer
     notice waits in Review, because the transfer pairing reads only template rows and
     the fold pairs only verified mail. A debit text that only the readers read waits in Review
     beside a template transfer notice or debit alert of the same amount within 30 minutes,
     in either order, as does the template hit that comes second. A text whose key is a repeat in the same minute
     waits in Review, with or without a bank: the fold's probable-copy key holds the
     merchant, which the readers may read differently once the first copy taught a layout.
     A text with no bank, which the fold cannot hold, also waits in Review when it repeats
     a text row of the last 10 minutes (same amount, currency and direction, and the same
     card when both show one). A text with
     a bank waits in Review the same way beside a text row with no bank, and beside a row of
     its bank that another template or the readers read (the fold's key needs the same
     merchant, which two readings may not share). A text that a live mail row of the last 24
     hours may already hold (the D10 twin rule, read from the text's side) waits in Review
     too, so a payment that came in both ways around a switch from email to texts does not
     file twice.
     The drop patterns for codes, declines and promotions, and the text twin of a mail
     (D10), do not change.

   There is no sender check and no card check. `gates.sender` still records whether the
   sender matched the template's `sms_sender`, for display only. So that the readers can
   agree on a text with no sender, the layouts learn from texts with no sender too (key
   `sms:`), as they learn from a bank sender (key `sms:<sender id>`). They stay in memory
   only.
3. **Mail filing drops its card terms** (`MessageDisposer.finalize`). A recipient check that
   is confirmed **or** unconfirmed may file; a mismatch may not. The `not_mine` card term is
   gone. Every other gate stays: A-R or DMARC pass, a trusted sender, not forwarded, not in
   Spam, the reader confidence for a template-free reading, no hold and no text twin. The
   reader confidence (`ExtractReading.meetsFilingBar`) is the one bar texts use, so a
   template-free mail whose only debit words are "transfer", "transferred", "sent" or
   "تحويل", or that moves money between your own accounts, now waits in Review too.
4. **Clef "Sort automatically"** files at a probability of 0.7 or more with a margin of 0.4
   (`CloudCategoryModel.autoFileThreshold`; it was 0.8 / 0.4). The suggestion gate stays
   0.6 / 0.2. Apple's model still never files (`ModelTier.autoConfirm = false`). Trust on a
   phone can still only raise the bar.
5. **Categorization does not change.** The order stays: user rules, the dictionary, the
   last pick (`LastPick`), Apple's model or Clef, then Review.
6. **Texts set-up and Profile** show no bank list for texts. Email keeps its bank list.
7. **No sender warning (2026-10-30).** The app no longer shows "Couldn't verify sender",
   for Gmail and Outlook alike: no badge in Review or Activity, no reason strip or "About
   this alert" sheet, and no `Sender check: <code>` line on the transaction. Most of these
   rows were real alerts (a forward, a bank's own DKIM set-up, Junk), the warning gave the
   person nothing to do that Review does not already ask, and a spoof can only add a wrong
   row. The check itself stays: a mail that fails its A-R or DMARC rule never files itself
   and waits in Review as an ordinary card. A pass for a domain outside the trusted set
   counts the same (`TxnGates.senderUnverified`), and the lane reads a `From` value's domain
   from the addr-spec the A-R rule reads (`BankDomains.domainOf`). Known limit: a sender
   added as a child domain whose bank signs with the parent's DKIM reads as a pass from an
   untrusted sender. Its mail never files itself, and neither a rule nor a sweep reaches it;
   only the person sorts it. Neither a rule (`RuleReach.Row.unverified`) nor
   a sweep, so not Clef's "Sort automatically" either (`SweepRow.candidate`), reaches it;
   only the person sorts it. The op keeps the code in `gates.ar`, the core reads it as
   `TxnRow.senderUnverified`, and the app keeps `Txn.senderUnverified` for the rule reach
   only. `TxnReviewReason` has no `sender_unverified` case.

New payloads have no `gates.card`. The key was always optional in the fold, so older builds
read the new rows.

## What still reads accounts and cards

Each of these keeps working with no new card links:

- **Manual entry** keeps its `accountID`. The person picks an account they made.
- **The bills and accounts fold** (`Replay/V4/BillsAccounts.swift`) keeps `applyCardLinked`
  and the `card` table, so an older log replays to the same state.
- **`LedgerReader.accounts()` and `LedgerReader.cards()`** stay. The state mapper shows the
  last four digits of an account that an older build linked.
- **`Attribution.accountOf`** keeps its order: an explicit `account_id`, then a card link
  from an older build, else no account.
- **`OpAuthor.cardAccountID`** stays. The sample seed export and its tests derive the
  sample's account ids from it. The Maya sample keeps its `card_linked` ops, which the fold
  reads as any older log.

## Risks

- A faked bank text, from any sender, that a template reads or that the readers agree on,
  files a payment. The person archives it. Check payments you don't recognise against the
  bank's app.
- A mail whose recipient check is unconfirmed (no signed To or Cc that names the mailbox)
  files when every other gate passes. Mail must still pass A-R or DMARC and come from a
  trusted sender, so a spoof must first pass those.
- A Clef answer between 0.7 and 0.8 now files. The spike measured 0.7 / 0.3 (94 of 114
  answered, 99% right) and 0.8 / 0.4 (81 answered, 100% right), not 0.7 / 0.4. Watch for
  wrong auto-sorts in the beta, and raise the gate if testers report them.
