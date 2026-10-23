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

### D3 and D3b Waiting rows and reach-back

One Core predicate decides which rows a group action may file:
`RuleReach.waiting(row, samePurchase:)` (HasalaCore `Domain/Author/RuleReach.swift`). A
row waits when its review lane is `needs_review` or `uncategorized` and it has no review
reason (a sender that failed authentication included), is not a held copy, a copy or a
possible duplicate, is not in a same-purchase pair, is not archived, a transfer or a
split, and its source is not the person's (`user`) or held. A row a dictionary entry or a
rule already filed does not wait. The live mapper sets `Txn.reachable` from this
predicate, so every count on a card is the number of rows a tap files. A row that fails
it stays its own card with its own strip ("Couldn't verify sender").

A rule made from a group reaches back to rows that the rule hits, that are in the same
group and direction, and that wait (`RuleReach.plan`). It writes
`txn_categorized {category, needs_review: false, source: rule}` for each. Rows a model
filed automatically and rows the person filed are left alone. A group rule is exact
patterns of the group's spellings, at most 8 (the limit of `rule_added`), the filed
spelling first, then the most used. "Always use it" is hidden when no spelling fits a
pattern. A learned pattern never starts with a payment facilitator, so
`PAYPAL *TAILSCALE` gives the exact pattern, not `contains paypal`.

After a pull, the iPhone that made the rule reaches back once more, for 24 hours, to rows
that arrived since and that it has not considered yet. Rows the person sent back to
Review with Undo all are never filed again by that pass.

### D4 and D5 Sorting a group

"Sort all N as X" files the group's waiting rows in every month as the person's own
choice (`source: user`). It makes a rule only when "Always use it" is on. "Sort each one"
is always there on a group card. "Always use it" from one row, in Review, Activity or the
transaction sheet, writes the same group rule and reaches back the same way, with the
same result row and Undo.

### D6, D6b and D7 Not this

A new op kind, `merchant_category_rejected {merchant_key, category, rejected}`, at schema
v4 with no version bump. It is keyed per (merchant key, category), the last write by
position wins, and the fold keeps it in its own map, witnessed only when not empty, so no
existing golden moved. Not this writes one op for each spelling key of the group, and a
pair is rejected for a row when any key of the row's group has it, so a spelling that
arrives later is covered. The same edit returns the rows whose category is the rejected
model guess to `category: null, needs_review: true, source: none`. Undo writes
`rejected: false` for the pairs it wrote and restores the rows.

The pusher closes the wire blob before and after every op of this kind
(`OpType.travelsAlone`), so the op always travels alone. A build from before this rework
does not know the kind: it sets that one blob aside and lists it as unreadable, and keeps
everything else. When it updates, the cold fold reads the blob again.

Rejections are applied on the phone after the answer: a rejected answer reads as unknown
for that stage, so Apple's model is asked next, and a cached Cloudflare answer that was
rejected is never sent to Cloudflare again. The `allowed` list, the request bytes and the
cache key never change (`RejectionSweepTests`). A model-sourced row whose guess is
rejected shows as a plain "You decide" card.

### D8, D9 and D10 One card on the Review tab

The consent ask is shown once on each iPhone and never again after Not now. The run offer
appears only when Merchant suggestions is already on, once the first load is done: a
mailbox reached `active`, this iPhone's sync caught up and payments wait. A mailbox
waiting for cards, and a mailbox held by another iPhone, count after the second Review
open, because "another iPhone holds it" does not say that its import finished. The offer
comes back when 20 or more new waiting merchant groups arrived since the last run, or a
newly connected mailbox finishes its import. The memory is one integer snapshot and a few
flags in UserDefaults, cleared by `LocalAccountData.forget()`. Check suggestions opens only
from the result card of a bulk run (see [Feedback #12](#feedback-12-and-check-suggestions)).

### D11 Trust on this phone

Auto-filing is unchanged: only Cloudflare (`cf-clef/`) with Sort automatically on, at 0.8
with a margin of 0.4. Apple's model never files. Trust on this phone can only raise the
bar: after the person corrects two Cloudflare filings of one built-in category, that
category is suggested, not filed, on this iPhone (`Live/Runtime/TrustCounts.swift`). A
correction is a person's re-file of a row whose source was a model with
`needs_review: false`; Not this on such a row counts too. The counts hold built-in
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

### D15 The result row

The result of a group sort or a reach-back is a row in the deck footer and on the Review
tab, not a toast: "Sorted 30 Tailscale as Software", with "Including 12 from other months"
when rows outside the period were filed, Undo while it can be undone, and Stop this rule
when a rule was made. It stays until it is dismissed or the next batch replaces it. On the
live app it is kept in the account's own store (`sort_memory`), not in UserDefaults,
because it names transactions; it survives a relaunch without Undo, because undo tokens
do not survive one. It goes with the account's files when the account leaves the iPhone.

### D16 and D17 Card content and units

A group card shows the merchant, the spellings it covers, the total per currency (never
summed across currencies; with two or more, an estimate in AED from the home amounts,
labelled as an estimate), the date range, "repeats monthly" when a bill covers the
merchant, and the rows left out and why. Its buttons say what a tap files: "Use for all
30", "Sort all 30 as Software" count the group's waiting rows in every month, and the meta
line names the ones from other months. A swipe or a flick opens the pick sheet; it never
files 30 rows. The tab badge counts payments, the count line reads "Tailscale and 39 more ·
120 payments", the deck position counts cards, and VoiceOver says "Filed 30 Tailscale
payments as Software. 39 left." after a group sort.

## How the live app writes it

- `LedgerEditAuthor` (`Live/Ledger/SortingEdits.swift`) authors every rework edit. A batch
  and its undo are each one `Outbox.enqueue`, so they are durable together or not at all.
- Every edit, the model sweep's commit and the bulk sort's commit re-read the rows and
  enqueue inside the page observer's `WriteSerial`, so a suggestion for a row that a rule
  or the person filed meanwhile is dropped, not authored.
- Undo restores the exact earlier source of each row (`Inverse.refile`), only when the row
  is still at the version the edit wrote. A rule made by the edit is removed with
  `removed: true`; an edited rule gets its old record back.
- Stop this rule writes `rule_added removed: true` and keeps what the rule filed. Pausing a
  rule in Profile still holds its rows (`setRule` with held rows), the reach-back rows
  included.
- After a pull, a person's filing that lost a fork to this iPhone's automatic op (a
  reach-back, a re-file or an undo) is written again at the head.

## Feedback #12 and Check suggestions

Feedback #12 asked to remove the Check suggestions sheet. It is kept, but only on the
result card of a bulk run: after a run that leaves 30 or more suggestions, ticking them in
one list is faster than 30 deck taps. Everywhere else the deck's group cards replace it.

## Old builds

- A build from before this rework sets aside each Not this blob and lists it as unreadable.
  It loses nothing else, because the op travels alone.
- Such a build does not know the rejections, so its own model sweep can suggest a rejected
  guess again until it updates.
- Group cards, reach-back and the result row are new behaviour only; the ops they write
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

- Should the run offer count groups or names when it says "Sort 40 merchants"? The offer's
  trigger counts groups; its card still counts the names it will ask about.
- Should a group whose spellings carry many references (more than 8) get a shared-prefix
  rule limited to the group, instead of the 8 most used spellings?
- Should Sorted for you list the bulk run's Cloudflare filings by run, as it lists rules
  by batch? Today it groups them by merchant and category.
