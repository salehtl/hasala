# Crowd merchant list (proposal)

**Status: proposed — owner decision required.** Nothing in this record is built: no Worker,
no app switch, no privacy policy text. It lists what a crowd-taught merchant list would
need and the problems that stop it today. Every example is synthetic.

## The idea

People who sort a merchant that Hasala's list doesn't know could, if they opt in, send
"merchant group → built-in category" pairs. Pairs that enough people agree on would be
reviewed by the owner and added to the bundled dictionary in an app release, so the next
person's first import sorts more payments on the phone.

## Why it is not built

It adds a second path off the phone. The recorded decision (CLAUDE.md, cloud suggestions,
2026-10-20) allows exactly one: an identity-free Worker that receives one merchant string
and stores and logs nothing. A crowd list must store what it receives to count agreement.
That is a privacy decision only the owner can make.

## Open problems

1. **Counting people needs a credential.** "At least k agreeing contributors" can't be
   enforced without some identity: one person reaches k alone through several payments, a
   reinstall, a second iPhone or another network, and a per-IP limit doesn't stop it.
   Options: (a) hasalad issues blind, rate-limited tokens (Privacy Pass, RFC 9576-9578),
   one per account per merchant group per epoch, and the Worker keeps only spent-token
   hashes and totals; this needs blind RSA (RFC 9474), which CryptoKit doesn't offer, and
   a third-party crypto library trips the export-compliance guard
   (`docs/decisions/export-compliance.md`). (b) Drop the k claim: a manual, per-merchant
   "Send this to Hasala" action that the person reviews, like a bank request.
2. **The repository is public.** Approved pairs committed to
   `ios/tools/dictionary/seed-v1.csv` would put merchant strings from real people's bank
   mail into public history, and a small business's name can be a person's name. Only
   owner-written, normalized brand patterns of businesses that can be checked publicly
   could be committed; exports would have to stay out of the tree, with a real-mail-fence
   pattern for their file name.
3. **What a pair may carry.** An allowlist of built-in category ids only (groceries,
   transport, dining, entertainment, shopping, travel, subscriptions, utilities), never a
   custom category, never health, rent, debt, income, transfers or refunds. Only filings
   the person made by hand count, never a model suggestion, a rule or a reach-back, so the
   list doesn't learn Cloudflare's own answers back. Only debit card-template subjects
   whose group is not on the list already, sent as the noise-stripped group key, at most
   once per account, with a random delay of hours to days, never in the same window as a
   cloud suggestion request for that merchant.
4. **Worker fences.** One POST route that returns no stored data and no GET route; no
   secrets or service bindings; observability and log push off; one D1 binding whose
   schema holds only (group key, category id, count, first seen day); rows under the
   threshold deleted after a fixed time, with D1 Time Travel's window written down. The
   owner exports with `wrangler d1 export` from their own machine. `scripts/check.sh`,
   the `ci.yml` gate and its path rules, the `nixos-vm` skip and the CLAUDE.md layout table
   would each need the new Worker.
5. **App Store privacy labels.** Stored pairs are collected data (Purchase History, not
   linked). The build that first shows the switch on the Release surface must add that
   entry to `PrivacyInfo.xcprivacy` and the App Store Connect answers must change; a
   build without the Worker's URL should not show the switch.
6. **The privacy policy.** Every sentence it would make false needs rewriting before it
   ships: the short version, what we don't collect, how we use data, Limited Use 1, 2 and
   5 (human review of Gmail-derived data is allowed only when aggregated and anonymized,
   which needs an enforced k), the Outlook promises, the table of who else handles data
   (Cloudflare D1), retention for pairs and the Time Travel window, and your rights
   (contributions that can't be linked can't be erased, which must be said before the
   opt-in). The security page changes too.
7. **Google's assessment.** A Worker that stores data derived from Gmail enters the scope
   of the restricted-scope (CASA) assessment.

## If the owner approves

Write the decision with one of the two options in problem 1, then build the Worker with
its own fence tests and CI steps, the app switch behind `BuildSurface`, and the policy
and label changes, in one pull request, before any tester sees the switch.
