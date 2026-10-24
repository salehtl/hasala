# Sorting rework: one card per merchant (decision record)

**Status: built on `sorting/integration` (2026-10-23), waiting for the owner's review and
the merge to `main`.** The defaults below were adopted while the owner was away; each one
names what it changed and where. Every example is synthetic.

## Why

A first import can leave a hundred or more payments in Review. Before this rework each
payment was one card, a rule changed only the payments that arrived after it, a rejected
guess came back, and an automatic filing was visible only on the transaction sheet. The
rework has five goals:

1. Fewer actions: a first load is cleared with one action per merchant, not per payment.
2. One place to start: the Review tab shows Start, the list, at most one sorting card,
   and the unread-mail row (always, and not counted as the card).
3. No repeat mistakes: a guess the person rejects does not come back for that merchant.
4. Nothing hidden: every automatic filing can be seen afterwards and fixed in one tap.
5. Same privacy: nothing new leaves the phone, and the request to Cloudflare is the same,
   byte for byte.

## What was built

### D1 The merchant group key

`MerchantGroup.key(raw:)` (HasalaCore `Categorize/MerchantGroup.swift`) depends on the raw
merchant and the bundled dictionary only, never on the person's rules, so cards do not
regroup when a rule changes and the golden set stays reproducible. A dictionary hit gives
`d:<display name>`; otherwise the key is `n:` and the noise-stripped `Canon.subject`. A
known payment facilitator before a star (`PAYPAL *`, `SQ *`, `GOOGLE *` and others) is
noise and the part after the star is kept; any other star drops what follows. Trailing
digits and references, country codes, legal suffixes and `.com` go too. There is no fuzzy
matching. Cards group by key and direction, so a refund is never in the same card as the
payments. The projection stores the key in `txn.merchant_group` (projection version 8).
The Swift-owned golden set `conformance/merchant-group` holds the dictionary digest in its
header and the near-misses (Al Noor Trading against Al Noor Pharmacy, two PayPal
merchants, three spellings of one merchant).

### D2 No automatic rule after two filings

Rules come only from the "Always use it" switch, which stays off by default (#176). An
automatic rule after two matching filings was proposed and not built: it would have
reversed the owner's #176 default on the same evening. See [Proposals](#proposals-for-the-owner).

### D3 and D3b Waiting rows and the reach of a rule

`RuleReach.waiting(row, samePurchase:)` (HasalaCore `Domain/Author/RuleReach.swift`)
decides which rows of a merchant group wait in Review. A row waits when its review lane is
`needs_review` or `uncategorized` and it has no review reason (a sender that failed
authentication included), is not a held copy, a copy or a possible duplicate, is not in a
same-purchase pair, is not archived, a transfer or a split, and its source is not the
person's (`user`) or held. A row a dictionary entry or a rule already filed does not wait.
The live mapper sets `Txn.reachable` from this predicate. `Txn.waits` (HasalaModels) is the
same test on a `Txn`: the mock sets `reachable` from it, and so does the screen after Undo
all.

A rule from "Always use it" reaches further (sorting rebuild, 2026-10-23). It files every
payment of that merchant group and direction whose spelling the rule holds, in every month,
past and future, except the payments the person sorted. `RuleReach.ruled(row, samePurchase:)`
decides it. A row is in when its source is `none`, `dictionary`, `rule` or `model`,
whatever its category or review lane. A row is out when the person sorted it (`user`), a paused rule holds it
(`held`), it is an unreadable alert, its sender failed authentication, it is a held copy, a
copy or a possible duplicate, it is in a same-purchase pair, or it is archived, a transfer
or a split. A row already in the rule's category and out of Review is left as it is. The
live mapper sets `Txn.ruled` from this predicate, so the screen files the same rows as the
ops at once.

The bank's spelling decides the merchant, through `MerchantGroup.key` and the dictionary. A
rule never reaches another merchant group: the dictionary keeps `talabat` and
`talabat mart` apart, so "Always use Dining for talabat" never files a talabat mart
payment.

The rule writes `txn_categorized {category, needs_review: false, source: rule}` for each
row, in the same `Outbox.enqueue` as the person's own filing. Its patterns are exact
patterns of the spellings of every row of the group that the rule may file, at most 8 (the
limit of `rule_added`): the filed spelling first, then the most used spellings of the rows
it files, then those of the rows already in its category. "Always use it" is hidden on a
row with no merchant group, on a split, and when no spelling fits a pattern. Every pattern
is exact, so `PAYPAL *TAILSCALE` gives the exact pattern, not `contains paypal`. A payment
skipped in Review today is filed too. The result reads "Software for all 14 Tailscale
payments" and counts only the payments whose category changed; it drops "all" when the
rule leaves a payment of the group unfiled that it may file (its spelling did not fit in
the 8 patterns, or cannot be a pattern). A rule's filings never count as corrections for
Trust on this phone.

Undo puts each row back exactly (`Inverse.refile`). Undo all in Sorted for you does the
same: each row gets back the category, source and review state it had before the rule
filed it (`SortMemory.Batch.prior`). A payment that the merchant list or Cloudflare filed
goes back to that filing, not to Review. A row with no recorded state goes back to Review.
After either Undo, a row keeps the time of its earlier filing (`Prior.categorizedMs`) while
the iPhone keeps that batch (the last 40), so an earlier rule or Cloudflare filing does not
show again in Sorted for you as new. A later Always use on the same group keeps that time
too. Undo on the toast of Undo all files the rows by the rule again and keeps their earlier
state, so a second Undo all puts them back the same way.

After a pull, the iPhone that made the rule reaches back once more, for 24 hours, to rows
that arrived since and that it has not considered yet. Rows put back with Undo all are
never filed again by that pass.

### D4 and D5 One card per payment

The sorting rebuild (2026-10-23) removed the group card, "Use for all N", "Sort all N as X",
Sort each one and the pick sheet's group mode (its commit button and history line). Review
shows one card per payment again. A swipe, a direction pill or a VoiceOver action picks the
bucket, and a tap on a category in the pick sheet sorts the card at once. A card with a
suggestion sorts in one tap with Use. The merchant group stays behind the scenes: it
scopes "Always use it" (D3), it gives the person's last pick
([Your last pick](#your-last-pick)) and the order of the next card, and `GroupIndex` keeps
each group's filings by the person and its monthly bills. "Always use it" from one card, in Review, Activity or the transaction
sheet, writes a group rule and reaches every payment D3 names. The app no longer uses
`RuleReach.Scope.waiting` or `RuleReach.members`.

The deck keeps the cards it opened with. Its position ("2 of 6") counts that set, and a
card that was sorted meanwhile elsewhere (the background stage, another iPhone, a rule's
reach) is skipped when its turn comes. The top card stays until the person sorts it, skips
it or closes the deck, also when it is sorted elsewhere meanwhile. Undo brings a card back
to its old place. A payment that arrives while the deck is open waits for the next session.
The "Waiting for Cloudflare AI" hold is gone: no card is moved to the end of the deck while
Cloudflare sorts.

### Your last pick

The sorting rebuild (2026-10-23) puts the person's own pick before the AI. When the person
has sorted a payment of a merchant group and direction themselves, every payment of that
group and direction that waits in Review suggests their latest pick. The pick is the
category of the newest row of the group and direction whose current source is `user`,
newest by `txn.categorized_ms`, or by its posted time when that is empty
(`LastPick`, HasalaCore `Categorize/LastPick.swift`). Rows held by a paused rule (`held`)
and rows a rule, the merchant list or a model filed do not count, and neither does a split
payment or a row that waits in Review (an Undo can leave one with source `user`).
`LedgerReader.lastPicks()` reads it, and the live mapper sets `Txn.lastPick` on the
rows that wait in Review. `GroupIndex` sets it for the mock with the same rule; in the
mock, whose clock does not move, two sorts with the same time are ordered by when the
person made them, and Undo takes that order back.

That field is the card's suggestion. The strip shows it with "Your last pick" and Use, the
pick sheet of its bucket lists it first and marks it "Suggested", and Use files exactly
that category: if the suggestion changed after the card showed it, Use files nothing and
the card shows the new one. A card with a pick does not say "New merchant". Only a
merchant with no pick shows an AI answer stored on the row, with the labels that name
Cloudflare or this iPhone. A rejection from #182 still hides an AI answer
but never the person's own pick. A pick is only a suggestion: the payment waits in Review
until the person taps Use or picks a category. A pick whose category is hidden or archived
since shows no suggestion, and no AI answer either.

The AI is not asked about a merchant the person sorted. `LedgerReader.sweepRows` sets
`SweepRow.picked` the way it sets the rejections, and `ModelSuggestionSweep.eligible` is
false for a picked row, also when the pick's category is hidden since. So neither
Cloudflare nor Apple's model is asked about it, in the foreground sweep or in the
background stage, the background counts leave it out, and an answer that comes back after
the person sorted the merchant is not written, because the sweeps re-read the rows before
they author. A pick belongs to one direction and a split payment is no pick, so a merchant
the person sorted only as a refund, or only in a split, is still asked about for its
payments.

After the person sorts a card, the next card is another waiting payment of the same
merchant group and direction from the deck's own cards, in date order, if there is one;
then date order resumes. A payment of that merchant sorted meanwhile elsewhere is skipped,
as D4 and D5 say.

### D6, D6b and D7 Not this

The sorting rebuild (2026-10-23) removed Not this from the app: there is no button, note or
edit, and the app writes no new rejections. What #182 wrote stays
readable.

The op kind is `merchant_category_rejected {merchant_key, category, rejected}`, at schema
v4 with no version bump. It is keyed per (merchant key, category), the last write by
position wins, and the fold keeps it in its own map, witnessed only when not empty, so no
existing golden moved. A pair is rejected for a row when any key of the row's group has
it, so a spelling that arrives later is covered.

The pusher closes the wire blob before and after every op of this kind
(`OpType.travelsAlone`), so the op always travels alone. A build from before #182 does not
know the kind: it sets that one blob aside and lists it as unreadable, and keeps
everything else. When it updates, the cold fold reads the blob again.

Rejections already in the log are applied on the phone after the answer: a rejected answer
reads as unknown for that stage, so Apple's model is asked next, and a cached Cloudflare
answer that was rejected is never sent to Cloudflare again. The phone keeps such an answer
in its own record (`fm_kept`, keyed by a hash of the name and the model tag only), apart
from the 30-day cache. The sweeps keep it whenever a rejected Cloudflare answer comes back;
builds with Not this also wrote it at once. When a rejection is undone on another
phone, the next sweep drops the record and the name is asked again. The `allowed` list, the
request bytes and the cache key never change (`RejectionSweepTests`). A model-sourced row
whose guess is rejected shows as a plain "You decide" card.

### D8, D9 and D10 One card on the Review tab

The consent ask is shown once on each iPhone and never again after Not now. Turn on sets
both switches. The run offer, the run card, its paused and result states and Check
suggestions were removed in the sorting rebuild (2026-10-23): with Merchant suggestions
on, Hasala asks Cloudflare about the waiting merchant names by itself while the app is
open, as a background stage (`BacklogSorter.ensure()`, see
[cloud-suggestions.md](cloud-suggestions.md#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23)).
The slot above the queue now holds only the ask or the importing card. The offer's memory
in UserDefaults (`app.hasala.prefs.cloudSort.runOffer`) and the dismissed result
(`app.hasala.prefs.cloudSort.dismissedRun`) are no longer written; `LocalAccountData.forget()`
still removes them from older installs.

### D11 Trust on this phone

Auto-filing is unchanged: only Cloudflare (`cf-clef/`) with Sort automatically on, at 0.8
with a margin of 0.4. Apple's model never files. Trust on this phone can only raise the
bar: after the person corrects two Cloudflare filings of one built-in category, that
category is suggested, not filed, on this iPhone (`Live/Runtime/TrustCounts.swift`). A
correction is a person's re-file of a row whose source was a model with
`needs_review: false`. The counts hold built-in
category ids and integers only, live in UserDefaults and are cleared by
`LocalAccountData.forget()`. They are applied only when ops are authored, through the
`trusts` closure of `ModelSuggestionSweep.suggest` and `BacklogSort.pass`, and
`ModelTier.mayAutoFile` stays a pure tag check, so the projection's review lane of rows
already filed does not change when trust drops.

### D12 The crowd merchant list

Not built. [crowd-merchant-list.md](crowd-merchant-list.md) records it as a proposal that
needs the owner's decision.

### D13 and D14 Filed at, and Sorted for you

The projection stores `txn.categorized_ms`, the `authored_at` of the `txn_categorized` at
the entity head. Home shows "N sorted for you this week · Look" when rule filings or
Cloudflare auto-filings were made in the last 7 days by that time (dictionary filings on
ingest are not listed). Sorted for you lists each batch once, with "Undo all N" and, for
a rule, "Stop this rule", and each row has a one-tap fix that opens the category picker.
Activity rows and the transaction sheet name the source of an automatic filing
("Utilities · Your rule · 18:30").

### D15 The undo line

The result row was removed in the sorting rebuild (2026-10-23). When "Always use it" files
other payments too, the deck and the Review tab show one line at the bottom, the app's
toast: "Software for all 14 Tailscale payments" with Undo. It stays about 6 seconds
(`HMotion.undoLineDwell`; 8 while VoiceOver runs, longer while touched) and comes and goes
as every toast does, with only a fade under Reduce Motion. It is one toast like any other,
so the next toast replaces it, for example the next sort's "Sorted into Groceries". A sort
that files only its own card keeps the 4-second toast "Sorted into Groceries". Undo puts
every payment back as it was and removes the rule, in one batch. After the line goes,
Sorted for you on Home lists the batch, with Undo all.

Nothing is kept for display: `LedgerState.sortReceipt`, the receipt in `sort_memory` and the
dismiss edit are gone, and a receipt an earlier build wrote is ignored. `sort_memory` keeps
the batches (`seen`, `prior`, `cursor`) that the after-pull pass and Undo all read.

### D16 and D17 Card content and units

A card shows one payment: the merchant, the bank's own words, the amount, and the
suggestion strip with Use, as before #182. The group card's spellings, totals per currency,
AED estimate, date range, "repeats monthly", left-out rows and history footnote went with
it. The tab badge, the count line ("6 to sort · about a minute") and the deck position all
count payments, and VoiceOver says "Filed as Need. 3 of 6." after a sort.

## How the live app writes it

- `LedgerEditAuthor` (`Live/Ledger/SortingEdits.swift`) authors every rework edit. A batch
  and its undo are each one `Outbox.enqueue`, so they are durable together or not at all.
- Every edit, the model sweep's commit and the background sort's commit re-read the rows and
  enqueue inside the page observer's `WriteSerial`, so a suggestion for a row that a rule
  or the person filed meanwhile is dropped, not authored.
- Undo restores the exact earlier source of each row (`Inverse.refile`), only when the row
  is still at the version the edit wrote. A rule made by the edit is removed with
  `removed: true`; an edited rule gets its old record back.
- Stop this rule writes `rule_added removed: true` and keeps what the rule filed. Pausing a
  rule in Profile still holds its rows (`setRule` with held rows), the reach-back rows
  included.
- A group rule never drops a spelling an existing rule holds. Re-filing edits the
  existing rule in place when its spellings and the group's fit in 8 patterns; otherwise
  the group's spellings move out of it into a new rule, and the old rule keeps the rest.
- After a pull, a person's filing that lost a fork to this iPhone's automatic op (a
  reach-back, a re-file or an undo) is written again at the head.

## Feedback #12 and Check suggestions

Feedback #12 asked to remove the Check suggestions sheet. The rework kept it on the result
card of a bulk run only; the sorting rebuild (2026-10-23) removed it with that card.

## Old builds

- A build from before this rework sets aside each Not this blob that a #182 build wrote and
  lists it as unreadable. It loses nothing else, because the op travels alone.
- Such a build does not know the rejections, so its own model sweep can suggest a rejected
  guess again until it updates.
- Reach-back and the undo line are new behaviour only; the ops they write
  (`txn_categorized`, `rule_added`) are ones every build reads.

## Proposals for the owner

- **A rule after two filings.** Two filings of one group into one category by the person
  could offer "Sort Tailscale as Software from now on?" (Yes or Not now), never a silent
  rule, and never for a group already filed into two categories by any source, the
  dictionary included. Not built: it reverses the #176 default.
- **The crowd merchant list.** See [crowd-merchant-list.md](crowd-merchant-list.md).

## Out of scope

A daily push nudge, over-the-air dictionary updates, Apple's model filing rows, fuzzy
grouping, and splitting a group from its card.

## Open questions

- Should a group whose spellings carry many references (more than 8) get a shared-prefix
  rule limited to the group, instead of the 8 most used spellings?
- Should Sorted for you list the background stage's Cloudflare filings apart, as it lists
  rules by batch? Today it groups them by merchant and category.
