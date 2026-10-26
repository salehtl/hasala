# Bank texts through Shortcuts (decision record)

**Status: DECIDED (owner, 2026-10-26). Build in progress.** Bank texts are a second way in
for transactions: the bank's SMS alerts, handed to Hasala on the phone by an automation
that the person makes in Apple's Shortcuts app. A person uses bank email **or** bank texts,
not both. The decisions are in [Decisions](#decisions). The questions that only the beta can
answer are in [Open checks](#open-checks-for-the-beta). Every example in this file is
synthetic.

## The problem

Before this, a transaction came only from bank mail that the phone reads from Gmail or
Outlook. This left out three groups of people:

- People whose bank texts a card payment but sends no mail for it, or sends mail only when
  they turn it on.
- People who will not give a budget app access to their inbox.
- People past the Google limit. The Google OAuth consent is not verified, and it allows 100
  users or fewer.

Almost every UAE bank texts each card payment. With bank texts, a person can use Hasala with
no mailbox at all.

## Rules that do not change

- **The server is blind.** The text is read on the phone. hasalad never sees it, and
  nothing sends it to any other service.
- **No raw message in the op log.** As with mail, only the parsed fields go into an op,
  with a key made under a secret that stays on the phone (see
  [The key for each text](#the-key-for-each-text)).
- **Nothing is dropped silently.** A bank payment text that the phone cannot read becomes a
  row in Review, prefilled when a reader reads it, as mail does in
  `ios/HasalaCore/Sources/HasalaCore/Mailbox/Disposition.swift`. Only texts that are not
  bank payments are dropped (D11), and the gate leans to Review when it is not sure.

## What was decided

### One catch-all automation

The app adds an App Intent, "Add bank text", with a `text` parameter and an optional
`sender` parameter. An `AppShortcutsProvider` in the main app target registers it, so the
action shows in Shortcuts with nothing to install and no shared iCloud shortcut. It runs
without opening the app (`openAppWhenRun = false`).

The person makes **one** automation, once, in Shortcuts:

1. Automation → New → Message.
2. Any sender, with no "Message contains" filter.
3. Run Immediately.
4. New Blank Automation → Add Action.
5. Hasala → Add bank text, with the message as its input.

There are no filter words for each bank and no automation for each bank. Why: in the
owner's DIB texts, only about 5% of the payment texts contain "AED". Most Arabic purchase
texts carry no currency word at all, so a "contains AED" filter would miss most payments,
with no sign that they are missing. A filter by sender does not work either, because bank
sender IDs are not contacts. (These are aggregate counts only. No text from that export is
in this repository.)

Thus the action runs on every incoming text. Hasala looks at each text on the phone, keeps
only bank payment texts, and drops every other text at once without storing it (D11). The
privacy policy and the set-up screen say this plainly.

What iOS allows, as the owner tested on a real iPhone:

- The Message trigger fires on incoming texts and passes the message content.
- A text sent to your own number fires it. This is the set-up test.
- An app cannot make the automation for the person. Hasala can only guide them.
- An automation sees only texts that arrive after it is made. Older texts can be pasted.

The app cannot see the automation, thus its status shows only what it observed ("Ran 4 min
ago", the last text for each bank). What the phone keeps for this, and nothing more, is in
[What the phone keeps about texts](#what-the-phone-keeps-about-texts).

The set-up test: when the person taps **Test**, the app opens a 10-minute window on that
iPhone. A text whose normalized body is "hasala test" that arrives in the window marks the
test as passed and is then dropped like any other text that is not a bank payment. Outside
the window the same text is just dropped. The test does not depend on the sender.

### One source for each person

A person's account uses bank email or bank texts, never both. The choice holds for the
whole account, not for one device, because the mailbox link is already account-wide: one
device reads the mailbox, and "Read your email on this iPhone?" moves it. Thus the same
payment cannot arrive through two channels, and no merge is needed.

- The source of truth is the account's mailbox link, which every device already learns from
  the server (the takeover flow in `ConnectProviderView` uses it). The account uses texts
  only while it has no mailbox link. No new op and no new server field is needed, so the
  server learns nothing new: it already knows whether a mailbox is linked.
- Onboarding asks "How do your banks reach you?" (email or texts, neither preselected). On a
  device that joins an account that already has a mailbox link, the texts choice is not
  offered; the device says that the account reads bank email and offers the switch.
- With texts set up, the mailbox connect is not offered, and the reverse.
- To change, the person switches in Profile › Bank alerts on any device. The switch stops
  the old channel for the whole account: it disconnects the mailbox, or, once a mailbox link
  exists, "Add bank text" on every device ignores texts from then on and the app tells the
  person to delete the automation in Shortcuts. Rows already added stay.
- "Add bank text" checks the account's mailbox link before it authors a row. It uses the
  last link state the device synced, because the action may run with no network. A device
  that has not synced since another device connected a mailbox can still add texts until it
  syncs. A payment in that window can then show twice, from a text and from mail, and the
  person archives one. The window ends at that device's next sync (each launch, each push).
  It is listed in [Open checks](#open-checks-for-the-beta).
- Switching from texts to email sets a cutoff (D10). The cutoff is the newest text row in
  the account, from any device, read from the synced ledger, not from one device's state.

### Reading happens inside Hasala, on the phone

In this order:

1. **The sender.** A sender that is a full phone number (a person) is dropped at once,
   except the set-up test above. A sender on the bundled list of bank sender IDs is a bank.
   Any other sender, and a text with no sender, goes on to step 2 as an unknown sender.
2. **The SMS templates.** Templates gain a text channel: `channel: "sms"` (absent means
   mail), `match.sms_sender` in place of `match.sender_domain`, and `date_from: "received"`
   for texts that carry no date. Go (`server/internal/tmpl`) and Swift
   (`HasalaCore/Template/Exec`) agree byte for byte, with the conformance sets. A template
   hit is a payment and is never dropped, whatever the sender.
3. **The explicit drop patterns** (D11): one-time codes, declined payments, card blocked or
   activated, registrations, promotions and service tickets. Each pattern is a closed,
   tested list (bank patterns for DIB, and narrow generic ones for one-time codes and
   declines). A text is dropped here only when a pattern matches.
4. **The payment shape.** A text with a payment word and either an amount (a number with a
   currency word or code, in English or Arabic) or a masked card token goes to Review: the
   template-free readers (`template-free-reading.md`) prefill it, and Apple's on-device
   model may fill what they leave, but neither ever files a row. This is where other banks'
   payment texts go, and every payment text that arrives with no sender.
5. **Anything else** is dropped. From a bank sender, it adds one to that day's count of
   texts set aside (see below); from any other sender, it leaves no trace.

The gate leans to Review: a bank payment is dropped only when an explicit drop pattern says
it is not a payment. The cost is that, with no sender, a text from a person that looks like
a payment ("I sent you AED 50") can reach Review. The privacy policy says so, and the person
can delete it there.

Nothing is sent off the phone to read a text. A merchant name read from a text can go to
Clef only under the Cloud suggestions opt-in, like a name read from mail
(`cloud-suggestions.md`). The text itself, its sender and its other fields never do.

**Templates tonight: DIB only.** DIB has SMS templates for its payment families (Arabic and
English purchases, debits, credits and salary, reversals, refunds, own transfers and card
payments). Texts from other banks go to Review, prefilled when a reader reads them. Real
texts stay in `salehtl/hasala-fixtures`; this repository has synthetic texts only.

### Filing with no review

A text files with no review (`needs_review: false`) only when all of these hold:

- an SMS template read it;
- iOS gave the action a sender, and it is in that template's `match.sms_sender`;
- the card in the text is **known**: its last four digits are on a row from the same bank
  that the person confirmed in Review or sorted themselves, or on a mail row that passed
  `gates.ar`. A row that filed itself does not make a card known.

Why the card: an alphanumeric sender ID can be faked, and iOS puts a faked "DIB" text in
the real DIB thread. Mail has the DMARC gate for this (`gates.ar: pass`); texts have no
equal. A faker must now also know a card that the person already uses with that bank. This
raises the bar; it does not close it, and the security page says so. Everything else goes
to Review, prefilled: no sender, another sender, an unknown card, a text with no card (most
credits, reversals and transfers), the readers, Apple's model, and every pasted text. A
person who uses only texts thus confirms their first payment on each card in Review.

### What the phone keeps about texts

On the device, outside the synced data, and never sent:

- the time the automation last ran (one value, overwritten on each run, for every text,
  because the app cannot see the automation any other way);
- for each bank, the time of its last text that Hasala kept;
- for each bank sender, a count for each day of texts set aside as not payments (step 5);
- whether a set-up test passed;
- the key secret for the text keys (below), in the Keychain, this device only;
- the before-first-unlock marker (D6).

Texts from other senders leave only the last-run time. No text body, sender or field of a
dropped text is kept. The privacy policy lists each item.

### The key for each text

A text has no message ID. Its `ingest_id` is the hex HMAC-SHA256 of the channel, the sender
(empty when none), the normalized text, the arrival minute and a repeat number `n`, under a
random 32-byte secret that the phone makes once and keeps in its Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The secret never syncs. Why not a
plain SHA-256: a text is a short template plus fields that the row keeps, so a plain hash
could confirm a guess of a dropped part, such as a balance line. Why not a key derived from
the account's data key: anyone who can open the rows holds that key too.

`n` is the lowest number whose key is not in the ledger yet. Thus a key **never** makes
Hasala drop a text:

- Two equal texts in the same minute (two equal charges, or a retried charge) get `n` 0 and
  1. The second is a probable copy: the fold holds it in Review, where "Keep both" or
  "Merge" decides (`Replay/V4/Duplicates.swift`, same bank, amount, card and merchant
  within ten minutes).
- An automation that runs two times for one text, in the same minute or across a minute
  boundary, gives two rows, and the fold holds the second as a probable copy in the same
  way. Nothing is doubled silently.
- Equal texts at different times (for example two equal reversals) stay two rows, which the
  owner's DIB texts showed is needed.
- A repeat that the fold cannot hold (no bank, or nothing read) is a second row in Review
  beside the first, never a row that files itself.

A pasted text has no sender and no arrival time, so its key uses the empty sender and the
paste minute, and cannot match the automation's key. Instead, before it adds a pasted text,
the paste sheet looks for a live row with the same bank, amount, currency, direction, card
and merchant, and the same minute when the text carries its date and time. When it finds
one, it shows that row and asks before it adds the text. A pasted row never merges by
itself. The support page tells people that the sheet does this.

### The op log

A row from a text is a v4 `txn_ingested` that today's decoder folds with no anomaly (checked
on `CoreReplay` at commit `fcf0dd54`: no anomaly, a repeat with a new key inside ten
minutes is a held probable copy, the same key again is `duplicate_ingest`). It uses only
existing values in closed enums, and two keys that older clients ignore:

| Field | Value for a text row | Why |
|---|---|---|
| `ingest_id` | the HMAC key above (64 hex digits) | The ledger refuses the same key twice. |
| `entry_method` | `mailbox` | The enum is closed (`mailbox`, `manual`, `import`; `Replay/V4/TxnV4.swift`). With `mailbox`, old and new clients run the probable-copy hold (`Duplicates.swift` needs it) and show the provenance line ("DIB transaction alert", "Read automatically"), which is true of a text. With `import` or none, text rows would lose both. |
| `tier` | `template` on a template hit, `heuristic` when a reader prefilled, `none` with `unparsed: true` when nothing read | The closed set in `CausalDecode.tierOf`. |
| `bank` | the template's bank, or the bank of the sender list; absent when unknown | |
| `gates.ar` | **absent** | It is a mail-only DMARC verdict. Absent, no client shows "Your mailbox couldn't confirm that this email came from your bank"; `no_ar` would. Thus `verifiedSender` is false for every text row: a text row never wins a certain-copy merge and never forms an implicit DIB transfer pair, which no account needs because mail and texts do not mix. |
| `gates.sender` | `trusted` only when the sender matched the template's `sms_sender`, else `untrusted` | |
| `gates.template` | `<id>@<version>` or `none` | |
| `gates.card` | `known` (as defined above), `unknown`, or `none` when the text has no card | |
| `gates.forwarded` | `false` | |
| `gates.kind` | absent | |
| `provenance` | **absent** | With a provider, a grant and a message ID, a client treats the row as mail that it can fetch again. A text cannot be fetched. |
| `dedupe` | **absent** | `dedupe.message_id` merges rows as a certain copy at once (`detectCopy`), and equal texts can be separate payments. |
| `posted_at`, `posted_precision` | the date and time in the text, `time`; with no date in the text, the arrival minute, `time` | Probable-copy detection needs `time`. |
| `needs_review` | `false` only as in [Filing with no review](#filing-with-no-review) | |
| `channel` | `"sms"` (new, optional) | New clients show "Bank text" as the source and text-specific Review copy. Old clients ignore it. |
| `received_at` | the arrival minute (new, optional) | The D10 cutoff and the status line. Old clients ignore it. |

This is op-authoring code, which has the highest risk in the repository, thus it has its own
review before it merges.

### Build obligations

The PRs that build bank texts also do this work, which the gate and the repository rules
need:

1. **The real-text fence (PR-A, before any SMS fixture lands).** Step 0 of
   `scripts/check.sh` covers only mail paths today. Extend it so that it fails on any file
   under `conformance/sms/` that is not named `synthetic-*`, on any `corpus-*` file in an
   SMS conformance set, and on any file under `server/internal/tmpl/seed/testdata`
   (already covered). Real texts go only to `salehtl/hasala-fixtures` at the same paths.
2. **The private fixtures lock.** After real texts are added to the private repository, run
   `scripts/private-fixtures-lock.sh write` and commit `private-fixtures.lock` with the
   change.
3. **The conformance table.** Each new directory in `conformance/` gets its entry in the
   `CONFORMANCE` table of `scripts/check.sh`. `conformance/sms-extract` is a Swift-owned
   golden set: add it to `GOLDEN_SETS` in `scripts/check.sh`, to `conformance/README.md`
   and to the list in `CLAUDE.md`. The Go-written sets (`conformance/templates`,
   `conformance/dialect`) stay Go-written.
4. **The bundled templates.** After a seed template is added or changed in
   `server/internal/tmpl/seed`, run `swift ios/tools/templates/sync.swift`.
5. **Tests.**
   - D1: a template hit with a matching sender and a known card files; with no sender, with
     another sender, with an unknown card, with no card and as a paste, it goes to Review.
   - D10: the cutoff comes from the newest text row in the account from any device; mail at
     or before it is skipped, not authored.
   - One source: "Add bank text" authors nothing while the account has a mailbox link.
   - D11: a synthetic fixture for each drop kind (one-time code, declined, card blocked,
     card activated, registration, promotion, service ticket), each dropped; a person's
     number, dropped; synthetic payment texts from other banks and with no sender, each in
     Review; a template hit that also looks like a drop kind, kept.
   - The key: equal texts in the same minute give two rows, the second a held probable
     copy; a double run across a minute boundary, the same; equal texts on different days,
     two rows with no hold; the secret is not in any op.
   - Paste: the pre-check finds a matching row and asks; a paste never files and never
     merges by itself.
   - D6: before the first unlock, nothing is stored but the marker; after the unlock, the
     notice shows and the marker is removed.
   - The op: a v4 canary op of a text row in the canary log (`Replay/Snapshot.swift`) and
     a fold golden `conformance/swift/fold-v4-sms-*.json` that folds it on the current
     decoder, with the probable-copy hold and `duplicate_ingest` cases.

### Cut from v1

- The Live Activity guide for the set-up.
- The "gone quiet" alert for a bank that sends no texts for some days.
- The locked-phone inbox (see D6).
- The Wallet transaction trigger (D7).

## Ruled out

- **A shortcut that sends the text to hasalad, or forwarding to a Hasala address.** The
  server would see plaintext. Shortcuts cannot do Hasala's encryption on the device.
- **An SMS filter extension (`ILMessageFilterExtension`).** It is sandboxed and cannot share
  data with the app. Its only way out is a network request to our server, which is plaintext
  again.
- **Filter words for each bank.** See [One catch-all automation](#one-catch-all-automation).
- **A source for each device.** The mailbox link is account-wide, so a choice on each device
  would let one iPhone read texts while another reads the mailbox, and every payment would
  arrive twice.

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Can a text file with no review? | **Decided:** only on an SMS template hit whose `sms_sender` matches the sender that iOS gave the action, **and** whose card is known (see [Filing with no review](#filing-with-no-review)). A sender name alone can be faked. Without a sender, every text goes to Review, prefilled when a reader reads it. A pasted text always goes to Review, because the person chose the text, not the bank. The readers and the on-device model only fill Review. |
| D2 | Can a person use Hasala with texts only, with no mailbox? | **Decided:** yes. Texts are an alternative to the mailbox, thus onboarding asks which one. |
| D3 | One channel, or merge mail and texts? | **Decided (2026-10-26):** one source for each person, for the whole account (see [One source for each person](#one-source-for-each-person)). No merge. |
| D4 | Which banks first? | **Decided:** DIB only, tonight. Other banks' payment texts go to Review. More banks follow as real texts reach `hasala-fixtures`. |
| D5 | Before or after the template-free readers ship in the app? | **Decided:** with them. Texts use templates first and the readers for Review. |
| D6 | What happens to a text before the first unlock after a restart? | **Decided:** no text and no field of it is stored, and there is no locked-phone inbox. The action still runs steps 1 to 3 of the reading order, which need only bundled data. For a text that would be kept, it writes a content-free marker (a count and the arrival minute of the latest) to a file with no data protection. It then fails with "Hasala can't save bank texts until you unlock your iPhone. Paste this text later." After the unlock, the app shows "N bank texts arrived while your iPhone was locked after a restart. Paste them from Messages." and removes the marker. This replaces the earlier proposal to keep raw text in an inbox until the next unlock. |
| D7 | Build the Wallet transaction trigger (Apple Pay) too? | **Decided:** not in v1. |
| D8 | Add to the 2026-10-11 decisions in CLAUDE.md? | **Decided:** yes. The "Transactions come from Gmail" line gains bank texts through the Shortcuts automation, read on the phone. |
| D9 | Which filter words catch every bank text? | **Decided:** none. One catch-all automation, because only about 5% of DIB payment texts contain "AED". |
| D10 | When a person switches from texts to email, what does email import? | **Decided:** only mail newer than the newest row from a text in the account, from any device, so the overlap is not counted twice. Listed mail at or before it is recorded as skipped and never authored. The switch alert says so. A switch from email to texts needs no rule: texts start from the switch. |
| D11 | What about texts that are not bank payments? | **Decided:** a text from a person's number, and a text that matches an explicit drop pattern (one-time codes, declined payments, card blocked or activated, registrations, promotions, service tickets), is dropped on the phone at once and never stored. A text with no template hit and no drop match that has a payment shape goes to Review, whatever the sender, and with no sender. Any other text is dropped; from a bank sender it adds one to a daily count on the device. A declined payment is never added. The fixtures include each kind. |

## Open checks for the beta

Only real phones and real testers can answer these. Until each is checked, the app's copy
avoids the claim.

- Whether iOS gives the action the sender, or only the text. Without a sender, D1 sends
  every text to Review, and step 4 of the reading order decides what reaches it.
- Whether the automation runs, and the action can write, while the iPhone is locked (after
  the first unlock).
- Whether iOS shows a banner for each run. With a catch-all automation, a banner would show
  on every text. The owner's test showed none.
- Whether the action takes the message as its input by default, so the person does not set
  it by hand.
- Whether iOS lists the action before Hasala has been opened once.
- Whether the action can write the D6 marker before the first unlock, and whether Shortcuts
  shows the action's failure then.
- How often a person switches to email on one iPhone while another iPhone still adds texts
  before it syncs, so that a payment shows twice.
- How often other banks' texts read well enough in Review to justify their templates.

## Legal pages

`docs/legal/privacy.md` says that the automation hands each incoming text to Hasala on the
iPhone, that Hasala keeps only bank payment texts and drops every other text at once
without storing it, what the phone keeps about texts, that nothing is sent to our server or
anyone else, and how to stop it. `docs/legal/support.md` has the set-up and removal steps
and how to switch between texts and email. `docs/legal/security.md` covers texts beside
bank emails, with the D1 filing rule and its limit.

The pages describe bank texts as they ship, and a merge to `main` deploys hasala.app. Thus
the change to the legal pages merges only after the app PRs for bank texts have merged and
a TestFlight build with bank texts is out to testers. Until then its pull request stays a
draft.
