# Sorting rework and rebuild (decision record)

**Status: built on `sorting/rebuild` (2026-10-24), waiting for the owner's review and the
merge to `main`.** The sorting rework (#182) is on `main`. The rebuild (#186, #188, #189,
#193, #194, #196 and this record) replaces #182's sorting screens and keeps its plumbing.
The owner made the rebuild's decisions on 2026-10-23. Every example is synthetic.

## Why the rebuild

A first import can leave a hundred or more payments in Review. Before #182 each payment was
one card, a rule changed only the payments that arrived after it, a rejected guess came
back, and an automatic filing was visible only on the transaction sheet. #182 (2026-10-23)
set out to clear a first load with one action per merchant. It showed one card per
merchant group with "Use for all N" and "Sort all N as X", a Sort each sheet, a result row
that stayed until it was dismissed, a **Not this** button, and an offer and a card to start
a Cloudflare AI run.

The owner tried #182 on the same day and rejected its sorting screens: they took more steps
and more reading than before. A payment with no suggestion took three steps or more (swipe,
tap, "Sort all N") and a note to read, against two steps before. The AI worked through the
backlog only when the person started a run. The rebuild holds every change to one bar:

- a sort takes at most a swipe and a tap;
- a suggested sort takes one tap;
- the card has nothing new to read;
- nothing pulls the person out of sorting.

| Task | Before #182 | #182 | Rebuild |
| --- | --- | --- | --- |
| Sort a payment with no suggestion | 2 (swipe, tap) | 3 or more (swipe, tap, "Sort all N"), and a note to read | 2 (swipe, tap) |
| Sort a payment with a suggestion | 1 (Use) | 1 (Use for all N) | 1 (Use) |
| Sort every payment of one merchant | 2 for each payment | 3 | 3 (swipe, tick Always use, tap) |
| Add a category while sorting | leave Review for Profile | leave Review for Profile | 3 in the sheet (New category, the name, Save) |
| Sort the backlog with Cloudflare AI | start a run | start a run from the offer | nothing: it runs by itself |

What #182 got right stays: a rule reaches back to earlier payments, every automatic filing
can be seen afterwards and fixed in one tap (Sorted for you), and nothing new leaves the
phone. The request to Cloudflare is the same, byte for byte.

## The decisions (owner, 2026-10-23)

1. [One payment per card](#one-payment-per-card).
2. [The bank's spelling decides the merchant](#the-banks-spelling-decides-the-merchant).
3. [Always use reaches every payment but your own](#always-use-reaches-every-payment-but-your-own).
4. [Your last pick beats the AI](#your-last-pick-beats-the-ai).
5. [The AI works in the background](#the-ai-works-in-the-background).
6. [New category in the pick sheet](#new-category-in-the-pick-sheet).
7. [Every pick sheet starts from a bucket](#every-pick-sheet-starts-from-a-bucket).

### One payment per card

Review shows one card per payment, as before #182 (#193). Merchant groups are never shown
as groups. A card shows one payment: the merchant, the bank's own words, the amount, and
the suggestion strip with Use. The tab badge, the count line ("6 to sort · about a minute")
and the deck position ("2 of 6") count payments, and VoiceOver says "Filed as Need. 3 of
6." after a sort.

A swipe, a direction pill or a VoiceOver action picks the bucket, and a tap on a category in
the pick sheet sorts the card at once. The sheet has no commit button. A card with a
suggestion sorts in one tap with Use.

The merchant group stays behind the scenes. It scopes "Always use it", it gives the
person's last pick and the order of the next card, and `GroupIndex` keeps each group's
filings by the person and its monthly bills. After the person sorts a card, the next card
is another waiting payment of the same merchant group and direction from the deck's own
cards, in date order, if there is one. Then date order resumes. This order is the only
place where grouping shows.

The deck keeps the cards it opened with. Its position counts that set. A card that was
sorted elsewhere meanwhile (by the background stage, another iPhone or a rule's reach) is
skipped when its turn comes. The top card stays until the person sorts it, skips it or
closes the deck, also when it is sorted elsewhere meanwhile, so nothing moves under the
finger. Undo brings a card back to its old place. A payment that arrives while the deck is
open waits for the next session. No card is held back or moved to the end of the deck while
Cloudflare sorts: the "Waiting for Cloudflare AI" hold is gone.

The Review tab shows the period row (#177), the count line, Start, the list of waiting
payments, the unread-mail row, the mail import card and the one-time Cloudflare AI ask.
Nothing else.

### The bank's spelling decides the merchant

`MerchantGroup.key` and the bundled dictionary decide which merchant a payment belongs to
([The merchant group key](#the-merchant-group-key)). There is no fuzzy matching. A rule
never reaches another merchant group: the dictionary keeps `talabat` and `talabat mart`
apart, so "Always use Dining for talabat" never files a talabat mart payment.

### Always use reaches every payment but your own

A rule comes only from the "Always use it" switch, which stays off by default (#176). The
switch is on the pick sheet, in Activity and on the transaction sheet, and it means the
same in each place. It is hidden on a payment with no merchant group, on a split payment,
and on a payment whose own spelling cannot be a pattern.

With the switch on, a tap on a category does three things in one batch (#189). It sorts the
card. It saves a rule for the merchant's spellings
([Exact group rules](#exact-group-rules)). It files every payment of that merchant group and
direction whose spelling the rule holds, in every month, past and future, except the
payments the person sorted.

`RuleReach.ruled(row, samePurchase:)` (HasalaCore `Domain/Author/RuleReach.swift`) decides
the reach. A row is in when its source is `none`, `dictionary`, `rule` or `model`, whatever
its category or review lane. So a payment that the merchant list, an older rule or the AI
filed is filed again, and a payment skipped in Review today is filed too. A row is out
when:

- the person sorted it (`user`), or a paused rule holds it (`held`);
- it is an unreadable alert, or its sender failed authentication;
- it is a held copy, a copy or a possible duplicate, or it is in a same-purchase pair;
- it is archived, a transfer or a split.

A row already in the rule's category and out of Review is left as it is. The live mapper
sets `Txn.ruled` from this predicate, so the screen files the same rows as the ops at once.

The rule writes `txn_categorized {category, needs_review: false, source: rule}` for each
row, in the same `Outbox.enqueue` as the person's own filing. A rule's filings never count
as corrections for [Trust on this phone](#trust-on-this-phone). New payments of the
merchant are filed by the rule when they arrive, like any rule. A rule has no direction at
ingest, as before: a rule with a spending category that hits money in only suggests it.

After each pull in the next 24 hours, the iPhone that made the rule reaches to rows that
arrived since and that it has not considered yet. Rows put back with Undo all are never
filed again by that pass.

**The undo line.** When "Always use it" files other payments too, the deck and the Review
tab show one line at the bottom, the app's toast: "Software for all 14 Tailscale payments"
with Undo (#193). It counts only the payments whose category changed. It drops "all" when
the rule leaves a payment of the group unfiled that it may file, because that spelling did
not fit in the 8 patterns or cannot be a pattern. The line stays about 6 seconds
(`HMotion.undoLineDwell`; 8 while VoiceOver runs, and longer while it is touched). It
comes and goes as every toast does, with only a fade under Reduce Motion. It is one toast
like any other, so the next toast replaces it, for example the next sort's "Sorted into
Groceries". A sort that files only its own card keeps the 4-second toast "Sorted into
Groceries". After the line goes, Sorted for you on Home lists the batch, with Undo all.

**Undo.** Undo on the line puts every payment back exactly as it was and removes the rule,
in one batch (`Inverse.refile`). Undo all in Sorted for you puts the rows back the same way
and keeps the rule (Stop this rule removes it): each row gets back the category, source and
review state it had before the rule filed it (`SortMemory.Batch.prior`). A payment that the
merchant list or Cloudflare filed goes back
to that filing, not to Review. A row with no recorded state goes back to Review. After
either Undo, a row keeps the time of its earlier filing (`Prior.categorizedMs`) while the
iPhone keeps that batch (the last 40, for 30 days), so an earlier rule or Cloudflare filing
does not show again in Sorted for you as new. A later Always use on the same group keeps
that time too. Undo on the toast of Undo all files the rows by the rule again and keeps
their earlier state, so a second Undo all puts them back the same way.

### Your last pick beats the AI

When the person has sorted a payment of a merchant group and direction themselves, every
payment of that group and direction that waits in Review suggests their latest pick (#194).
The pick is the category of the newest row of the group and direction whose current source
is `user`, newest by `txn.categorized_ms`, or by its posted time when that is empty
(`LastPick`, HasalaCore `Categorize/LastPick.swift`). These rows do not count: rows held by
a paused rule (`held`), rows that a rule, the merchant list or a model filed, a split
payment, and a row that waits in Review (an Undo can leave one with source `user`).

The live mapper (`LedgerStateMapper`) runs `LastPick.picks` over the rows it already reads
and sets `Txn.lastPick` on the rows that wait in Review. `LedgerReader.sweepRows` runs it for
the sweeps. An Undo of a sort writes the earlier filing again, and the projection stamps the
time of that write. So that the Undo also takes back the order of that sort, this iPhone
keeps the earlier `categorized_ms` in `SortMemory` (`undone`, kept like the rule priors),
and the mapper uses it while the payment stays as the Undo left it. Another iPhone sees only
the op, so there the payment counts as the newest sort. `GroupIndex` sets the pick for the
mock with the same rule. In the mock, whose clock does not move, two sorts with the same
time are ordered by when the person made them, and Undo takes that order back. In the mock,
sorting a split payment into one category removes the split, so that payment counts there.
The projection keeps it split, so it does not count.

That field is the card's suggestion. The strip shows it with "Your last pick" and Use. The
pick sheet of its bucket lists it first and marks it "Suggested". Use files exactly that
category: if the suggestion changed after the card showed it, Use files nothing and the
card shows the new one. A card with a pick does not say "New merchant". Only a merchant with
no pick shows an AI answer stored on the row, with the labels that name Cloudflare ("Suggested
by Cloudflare AI") or this iPhone ("Suggested on this iPhone"). A rejection from #182 still
hides an AI answer, but never the person's own pick. A pick is only a suggestion: the
payment waits in Review until the person taps Use or picks a category. A pick whose category
is hidden or archived since shows no suggestion, and no AI answer either.

The AI is not asked about a merchant the person sorted. `LedgerReader.sweepRows` sets
`SweepRow.picked` the way it sets the rejections, and `ModelSuggestionSweep.eligible` is
false for a picked row, also when the pick's category is hidden since. So neither
Cloudflare nor Apple's model is asked about it, in the foreground sweep or in the
background stage, and the background counts leave it out. An answer that comes back after
the person sorted the merchant is not written, because the sweeps read the rows again
before they author. A pick belongs to one direction, and a split payment is no pick. So a
merchant that the person sorted only as a refund, or only in a split, is still asked about
for its payments.

### The AI works in the background

With Merchant suggestions on, Hasala works through the waiting merchant names by itself
while the app is open, as a silent background stage (`BacklogSorter.ensure()`, #188). The
caps stay: 3 calls at once, 12 names a pass, 30 seconds between passes, 400 names a day on
each iPhone, and one name per request. The stage pauses in the background, offline and on a
429 or a 503, and resumes by itself. It has no card, no count and no button. A run that
ended after three failed passes is tried again at the next open, never in a loop. This
reverses the 2026-10-21 rule that a person starts each bulk sort.
[cloud-suggestions.md](cloud-suggestions.md#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23)
holds the details.

The one-time ask stays. With Merchant suggestions off, Review asks once on each iPhone, and
never again after Not now. Turn on sets both switches, and the background stage does the
rest. The slot above the queue holds only the ask or the importing card. Sort automatically
does not change: only Cloudflare (`cf-clef/`) files a payment, at 0.7 with a margin of 0.4 (0.8 before 2026-10-29).
Profile › Cloud suggestions keeps **Send Cloudflare's sorting back to Review**.

### New category in the pick sheet

The pick sheet for Need, Want and Save ends with a New category row, so a person who needs
a new category does not leave Review for Profile (#196). The row is not shown for Transfer
or for money in, and it is hidden when the person has 20 custom categories. A tap turns the
sheet into a short form: Back, a title that names the bucket the swipe chose ("Need · new
category"; the bucket cannot be changed there) and Save at the top, then the name and the
icons. The name field has the keyboard at once. The icon follows `CategoryIconGuess` until
the person picks one, so a new category takes three taps in the sheet: New category, the
name, Save. The parent is that bucket's entry in `CategoriesEngine.countsAsOptions`, the same
one that Profile's editor offers. Back returns to the list and writes nothing.

Save first asks `ReviewDeckModel.newCategoryRefusal`. It runs the store's own check
(`LedgerStore.categoryRefusal`: `CategoriesEngine.refusal`, and in the live store also the
projection's taxonomy, for example a name with bidi characters). The check runs before any
edit, also before the edit that settles a held copy. A refusal shows under the name, with
nothing written and no toast. Otherwise the sheet closes, and then `createAndSort` sends the
one atomic `.addCategoryAndSort` edit (#186), with Always use when the sheet's switch is on
and the project when one is chosen. The store gives the new category its id up front, before
it authors (`LedgerStore.newCategoryID()`), so the sort can name it in the same blob. The
card then leaves as after any sort, with "Sorted into
Coffee", or with the undo line when Always use files other payments too. The toast comes up
after the sheet has closed, never on top of it. If the name is refused at that point after
all (a sync added the same name meanwhile), the refusal is a toast and the card springs
back. Undo takes back the sort, the rule and its reach, and keeps the category. The name is a
custom category name, so it is never sent to Cloudflare
([cloud-suggestions.md](cloud-suggestions.md)).

### Every pick sheet starts from a bucket

A swipe, a tap on a direction pill or a VoiceOver action picks the bucket first: each
`ReviewPick` carries its `ReviewChoice`. The pick sheet lists only that bucket's
categories. Transfer lists the categories that are not spending, and also the income
categories for money in. Sort each was the only way into a pick sheet without a bucket (it
fell back to a Needs-only list), and it went with the group cards. Activity and the
transaction sheet keep their own category picker, which lists every bucket. The rebuild
changes that picker only so that its Always use reaches as
[Always use reaches every payment but your own](#always-use-reaches-every-payment-but-your-own)
says.

## What #182 built and the rebuild keeps

The labels D1 to D17 in this record name the decisions of #182's record
(`docs/decisions/sorting-rework.md` at commit `3a81270c`).

### The merchant group key

`MerchantGroup.key(raw:)` (HasalaCore `Categorize/MerchantGroup.swift`, #182 D1) depends on
the raw merchant and the bundled dictionary only, never on the person's rules, so a group
does not change when a rule changes and the golden set stays reproducible. A dictionary hit
gives `d:<display name>`; otherwise the key is `n:` and the noise-stripped `Canon.subject`.
A known payment facilitator before a star (`PAYPAL *`, `SQ *`, `GOOGLE *` and others) is
noise, and the part after the star is kept; any other star drops what follows. Trailing
digits and references, country codes, legal suffixes and `.com` go too. There is no fuzzy
matching. Groups are keyed by key and direction, so a refund is never with the payments.
The Swift-owned golden set `conformance/merchant-group` holds the dictionary digest in its
header and the near-misses (Al Noor Trading against Al Noor Pharmacy, two PayPal merchants,
three spellings of one merchant).

#182 took the projection from version 7 to 9: it added
`txn.merchant_group` (the group key), `txn.categorized_ms` (see
[Filed at, and Sorted for you](#filed-at-and-sorted-for-you)) and the `merchant_rejection`
table. The projection is now at version 11, from the DIB transfer pairs (#185, #195).
The rebuild changes no table, no op kind and no wire format, and no golden set.

### Exact group rules

A group rule is exact patterns of the spellings of every row of the group that the rule may
file, at most 8 (the limit of `rule_added`). The filed spelling comes first, then the most
used spellings of the rows it files, then those of the rows already in its category
(`RuleReach.patterns`). Every pattern is exact, so `PAYPAL *TAILSCALE` gives the exact
pattern, not `contains paypal`. A rule never crosses merchant groups.

`OpAuthor.groupRule` reads only exact rules, and a spelling never ends up without a rule.
Re-filing edits the existing rule in place when its spellings and the group's fit in 8
patterns. Otherwise the group's spellings move out of it into a new rule, and the old rule
keeps the rest. An enabled exact rule into another category gives its copies of the group's
spellings to the new rule.

### Batch authoring and undo

Every sorting edit is one `Outbox.enqueue`, and so is its undo, inside the page observer's
`WriteSerial`. Undo writes back each row's exact earlier filing (`Inverse.refile`), only
when the row is still at the version the edit wrote. `sort_memory` keeps the batches
(`seen`, `prior`, `cursor`) that the after-pull pass and Undo all read. See
[How the live app writes it](#how-the-live-app-writes-it).

### Old rejections

The rebuild removed **Not this** from the app (#193): there is no button, note or edit, and
the app writes no new rejections. What #182 wrote stays readable and still applies.

The op kind is `merchant_category_rejected {merchant_key, category, rejected}` (#182 D6, D6b
and D7), at schema v4 with no version bump. It is keyed per (merchant key, category), the
last write by position wins, and the fold keeps it in its own map, witnessed only when not
empty, so no existing golden moved. A pair is rejected for a row when any key of the row's
group has it, so a spelling that arrives later is covered.

The pusher closes the wire blob before and after every op of this kind
(`OpType.travelsAlone`), so the op always travels alone. A build from before #182 does not
know the kind: it sets that one blob aside and lists it as unreadable, and keeps everything
else. When it updates, the cold fold reads the blob again.

Rejections already in the log are applied on the phone after the answer. A rejected answer
reads as unknown for that stage, so Apple's model is asked next, and a cached Cloudflare
answer that was rejected is never sent to Cloudflare again. The phone keeps such an answer
in its own record (`fm_kept`, keyed by a hash of the name and the model tag only), apart
from the 30-day cache. The sweeps keep it whenever a rejected Cloudflare answer comes back;
#182 builds also wrote it when the person tapped Not this. When a rejection is undone on
another phone (a #182 build), the next sweep drops the record and the name is asked again.
The `allowed` list, the request bytes and the cache key never change
(`RejectionSweepTests`). A model-sourced row whose guess is rejected shows as a plain "You
decide" card. A rejection never hides the person's own pick.

### No rule after two filings

Rules come only from "Always use it" (#182 D2). An automatic rule after two matching
filings was proposed and not built: it would have reversed the owner's #176 default on the
same evening. See [Proposals for the owner](#proposals-for-the-owner).

### Trust on this phone

Auto-filing is unchanged (#182 D11): only Cloudflare (`cf-clef/`) with Sort automatically
on, at 0.7 with a margin of 0.4 (0.8 before 2026-10-29, [filing-without-cards.md](filing-without-cards.md)). Apple's model never files. Trust on this phone can only
raise the bar: after the person corrects two Cloudflare filings of one built-in category,
that category is suggested, not filed, on this iPhone (`Live/Runtime/TrustCounts.swift`). A
correction is a person's re-file of a row whose source was a model with
`needs_review: false`. The counts hold built-in category ids and integers only, live in
UserDefaults and are cleared by `LocalAccountData.forget()`. They are applied only when ops
are authored, through the `trusts` closure of `ModelSuggestionSweep.suggest` and
`BacklogSort.pass`, and `ModelTier.mayAutoFile` stays a pure tag check, so the projection's
review lane of rows already filed does not change when trust drops.

### Filed at, and Sorted for you

The projection stores `txn.categorized_ms`, the `authored_at` of the `txn_categorized` at
the entity head (#182 D13 and D14). Home shows "N sorted for you this week · Look" when rule
filings or Cloudflare auto-filings were made in the last 7 days by that time (dictionary
filings on ingest are not listed). Sorted for you lists each batch once, with "Undo all N"
and, for a rule, "Stop this rule", and each row has a one-tap fix that opens the category
picker. Activity rows and the transaction sheet name the source of an automatic filing
("Utilities · Your rule · 18:30").

### The crowd merchant list

Not built (#182 D12). [crowd-merchant-list.md](crowd-merchant-list.md) records it as a
proposal that needs the owner's decision.

## What the rebuild removed

- The group card (`ReviewGroupCardView`), "Use for all N", "Sort all N as X", the flying
  group card, and the group rows on the Review tab (#193). The `.sortGroup` edit went with
  them. Some of its parts stay in the code with no reader (see below).
- Sort each (`SortEachSheet`, the deck's More menu and footer) and its Needs-only list
  (#193).
- The pick sheet's group mode: its commit button and its history line (#193).
- **Not this**: the button, the note strip, the `.notThis` edit, `OpAuthor.reject`,
  `Inverse.rejection` and `keepRejected` (#193). Not this on an auto-filed row no longer
  counts as a correction for Trust on this phone.
- The result row (#182 D15): `SortResultRowView`, `SortResultEngine`, `.dismissSortReceipt`,
  `LedgerState.sortReceipt` and the receipt in `sort_memory` (#193). Nothing is kept for
  display, and a receipt that an earlier build wrote is ignored. The undo line replaces it.
- The group card's content (#182 D16 and D17): the spellings, the totals per currency, the
  AED estimate, the date range, "repeats monthly", the rows left out and the history
  footnote (#193).
- The "Waiting for Cloudflare AI" hold on deck cards (`CloudSortStatus.pendingTxnIDs`, #193).
- The run offer, the run card, its paused and result states and their dismissal
  (`RunOffer`, `CloudSortCard`, `CloudSortDismissal`, #188). The offer's memory in
  UserDefaults (`app.hasala.prefs.cloudSort.runOffer`) and the dismissed result
  (`app.hasala.prefs.cloudSort.dismissedRun`) are no longer written;
  `LocalAccountData.forget()` still removes them from older installs
  (`MerchantSuggestionsSetting.retiredKeys`).
- Check suggestions (`CheckSuggestionsSheet`, its route, the `.useSuggestions` edit and
  `SuggestionsEngine`, #188 and #193). Feedback #12 had asked to remove that sheet; #182 kept
  it on the result card of a bulk run only, and the rebuild removed it with that card.
- Profile's **Sort now**, **Later** and **Last sort** (#188).
- The run requests, the per-run cap of 250 names, the run stats, the run manifest and run
  undo (`BacklogSort.runNames`, `.runCap`, #188).
- The legacy branch of Always use that wrote `contains` and `starts_with` rules
  (`OpAuthor.learnRule`, `LearnedPattern`, #189).
- The Debug screens for the group card, Sort each, the result row, the run card and Check
  suggestions.

Parts stay in the code with no reader: `Txn.reachable` (set by `RuleReach.waiting` in
`LedgerStateMapper`, and by `SortPatch` and `MockReach` from `Txn.waits`, which has no other
use), `RuleReach.Scope.waiting` with the `scope` parameter of `RuleReach.plan`,
`RuleReach.members`, and `BacklogSort.Counts.pendingTxnIDs`. Only tests read them. A later
code PR removes them.

## How the live app writes it

- `LedgerEditAuthor` (`Live/Ledger/SortingEdits.swift`) authors every sorting edit: a sort
  with Always use and its reach (`categorizeReaching`), Undo all and Send back to Review
  (`returnToReview`), Stop this rule, the after-pull pass and the fork repair. A batch and
  its undo are each one `Outbox.enqueue`, so they are durable together or not at all.
- `.addCategoryAndSort` (`LiveCategoryEdits.swift`) writes `category_defined` and then
  `txn_categorized` in one blob (#186). With Always use on, the same blob also holds the
  rule, and the reach follows in the same `Outbox.enqueue`. If any part is refused, nothing
  is written.
- Every edit, the model sweep's commit and the background stage's commit read the rows again
  and enqueue inside the page observer's `WriteSerial`, so a suggestion for a row that a rule
  or the person filed meanwhile is dropped, not authored.
- Undo restores the exact earlier source of each row (`Inverse.refile`), only when the row
  is still at the version the edit wrote. A rule made by the edit is removed with
  `removed: true`; an edited rule gets its old record back.
- Stop this rule writes `rule_added removed: true` and keeps what the rule filed. Pausing a
  rule in Profile still holds its rows (`setRule` with held rows), the reached rows
  included.
- After a pull, a person's filing that lost a fork to this iPhone's automatic op (a reach,
  a re-file or an undo) is written again at the head.

## Old builds

- The rebuild adds no op kind and changes no wire format. Every op it writes
  (`txn_categorized`, `rule_added`, `category_defined`) is one that every build reads.
- A build from before #182 sets aside each Not this blob that a #182 build wrote and lists
  it as unreadable. It loses nothing else, because the op travels alone. It does not know
  the rejections, so its own model sweep can suggest a rejected guess again until it
  updates.
- A #182 build keeps its own screens (group cards, the result row, Not this and the run
  card) until it updates, and reads what the rebuild writes. On the same iPhone, the
  device-local records stay readable to it: `sort_memory` keeps #182's fields (the rebuild
  adds optional ones and no longer writes the receipt), and the `backlog_run` record still
  writes the fields that the run card build reads
  ([cloud-suggestions.md](cloud-suggestions.md#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23)).
- Old rules: a rule made before #182, or by #182's legacy path for a row with no merchant
  group, can be a `contains` or `starts_with` rule, and such a rule can cross merchants (a
  `contains talabat` rule hits talabat mart). The rebuild does not rewrite existing rules,
  and `OpAuthor.groupRule` edits only exact rules. The person can remove such a rule in
  Profile › Rules.

## The legal pages (owner, 2026-10-24)

The owner asked for the legal pages to be rewritten for an experimental beta whose state is
highly volatile (Sorting rebuild 9). The privacy policy and the terms open with a short
notice: an experimental, invite-only beta on TestFlight; features change often, sometimes
without notice; things can break and data can be lost or reset; Hasala is not the only
record of a person's money. The privacy policy's 30 days' notice is gone. Its "Changes in
the beta" says that a change takes effect when it is posted, and that the app or the
TestFlight notes say what changed when it affects how data is used. A new optional cloud
feature stays off until the person turns it on.

This answers the question this record held open: the background stage needs no 30-day
notice for people who turned Merchant suggestions on in an earlier build. The policy's
"Working through what's waiting" describes the stage from the day it ships, and the
TestFlight notes of that build say what changed. The pages also describe the rebuilt
sorting (one card per payment, the last pick, Always use and its reach, New category) as
this record does.

## Proposals for the owner

- **A rule after two filings.** Two filings of one group into one category by the person
  could offer "Sort Tailscale as Software from now on?" (Yes or Not now), never a silent
  rule, and never for a group already filed into two categories by any source, the
  dictionary included. Not built: it reverses the #176 default.
- **The crowd merchant list.** See [crowd-merchant-list.md](crowd-merchant-list.md).
- **Telling earlier testers about the new pages.** The rewrite drops the old 30 days' notice
  at once, and the background stage reaches people who turned Merchant suggestions on under
  the old policy. The cheapest step is to tell testers about the new pages in the app or by
  email when the build ships, not only in the TestFlight notes. Another is to show the
  one-time ask once more to those people before the background stage runs for them. Not
  built.

## Out of scope

A daily push nudge, over-the-air dictionary updates, Apple's model filing rows, fuzzy
grouping, and splitting or merging merchant groups by hand.

## Open questions for the owner

Each question has a default that the build uses until the owner answers.

- **A merchant with more than 8 spellings.** One exact rule cannot hold them all. Should
  such a group get a shared-prefix rule limited to the group? Default: the 8 spellings that
  [Exact group rules](#exact-group-rules) names. Payments with the other spellings stay for
  the person, and the undo line drops "all".
- **Syncing Paper.** The New category form and the undo line have no Paper design. They are
  built from existing parts (the category editor's fields and the app's toast), and Paper
  still shows #182's screens. Default: the owner reviews them on the iPhone build, and
  `hasala-paper-sync` brings Paper up to date after the merge to `main`.
- **Turn on in the one-time ask.** Should it still turn on Sort automatically too? Default:
  yes, as before, with the ask's text unchanged.
- **Sorted for you and the background stage.** Should Sorted for you list the background
  stage's Cloudflare filings apart, as it lists rules by batch? Today it groups them by
  merchant and category.
