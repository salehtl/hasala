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
only texts that look like bank payments, and drops every other text at once without storing
it (D11). A text from a person that looks like a payment can reach Review (see the gate
below). The
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
- Onboarding asks "How do your banks reach you?" (email or texts, neither preselected). This
  is the design of screen A1 on the X6 Paper page and of the build plan, not a row in the
  Choose your email sheet: texts are a peer of email, chosen before any provider, and a
  person who uses only texts never needs the email sheet. The question is the first screen
  of setup's bank step (step 4), with **Skip** as today. Choosing email goes on to the bank
  step and the mailbox connect as they are now, so an email user gains this one choice and
  nothing else. Choosing texts leads to two screens: the banks, and a short automation
  guide that ends with **Test** or **Skip, confirm with my next bank text**. The test and the
  illustrated guide ("Show me how") are optional in setup and stay in Profile › Bank alerts,
  where a person who skipped them can finish them later. On a device that joins an account
  that already has a mailbox link, the texts choice is not offered; the device says that the
  account reads bank email and offers the switch.
- With texts set up, the mailbox connect is not offered, and the reverse.
- To change, the person switches in Profile › Bank alerts on any device. The switch stops
  the old channel for the whole account: it disconnects the mailbox, or, once a mailbox link
  exists, "Add bank text" on every device authors no row from then on and the app tells the
  person to delete the automation in Shortcuts. Rows already added stay.
- While the account has a mailbox link, "Add bank text" still runs the reading order below
  through step 4, but authors nothing and keeps no field. For each text that it would have
  kept (a template hit or a payment shape), it adds one to that day's count of bank payment
  texts ignored because the account reads email: a number only, on the device, for the last
  30 days. Profile › Bank alerts shows it ("3 bank payment texts were ignored in the last 30
  days because this account reads bank email") with two ways out: delete the automation in
  Shortcuts, or switch the account to texts. Thus a bank that texts some payments and mails
  none of them does not lose them with no trace.
- "Add bank text" checks the account's mailbox link before it authors a row. The link state
  is not in the op log, and the app holds the server's answer only in memory
  (`AccountRuntime.serverLink`, nil until `GET /mailbox/link` answers), while the action may
  run cold in the background with no network. So the device keeps a **copy of the last
  answer** on disk, outside the synced data: linked or not linked, and when it was learned.
  The copy is written on every answer from the server and on this device's own connect,
  disconnect and switch, and deleted on sign-out and account deletion. The action reads it:
  - **not linked**: the text is read and authored as below;
  - **linked**: the action authors nothing and counts the ignored payment texts as above;
  - **unknown** (no answer yet on this device, for example the first run after an install,
    cold in the background with no network): the action asks the server first when it can
    within its run time. When it cannot, it authors the text as for "not linked", but always
    with `needs_review: true`, so the row never files itself. Nothing is dropped, and if the
    answer later says linked, the row waits in Review, where the person archives a copy.

  A device whose copy is stale (another device connected a mailbox since its last answer)
  can still add texts until it next hears from the server. A payment in that window can then
  show twice, from a text and from mail, and the person archives one. The window ends at that
  device's next answer (each launch, each push). It is listed in
  [Open checks](#open-checks-for-the-beta).
- Switching from texts to email sets a cutoff (D10). The cutoff is the newest text row in
  the account, from any device, read from the synced ledger, not from one device's state.
  The cutoff skips no mail. It marks the overlap: the mail that the connect lists, dated at
  or before the cutoff plus 24 hours. In the overlap, a mail that has a **text twin** (a
  text row in the account with the same bank, amount, currency, direction and card, or no
  card on both, whose `posted_at` is within 24 hours of the mail's) is authored with
  `needs_review: true`, whatever its gates, and its Review card names the twin ("This may
  be the same payment as a bank text from DIB on 3 March"). The person keeps both or
  archives it. A mail in the overlap with no text twin is authored as any mail, because no
  text brought that payment in: a text that the automation missed, that arrived before the
  first unlock and was not pasted, or that the reading order set aside. When
  the merchant strings match, the fold's probable-copy hold applies too. The twin test does
  not use the merchant, because a bank's mail and its text often spell it differently.

### Reading happens inside Hasala, on the phone

First, the sender is sorted, and nothing is dropped for it yet: a sender on the bundled list
of bank sender IDs is a **bank sender**; a full phone number is a **person's number**; any
other sender is an **unknown sender**; and a text that iOS gives with no sender has **no
sender**. The set-up test (above) is checked before step 1. Then, in this order:

1. **The never-a-payment patterns** (D11): declined payments and one-time codes. Each is a
   closed, tested list (DIB's wordings, and narrow generic ones). They run before the
   templates, because a declined purchase, or a one-time code for a purchase, can carry the
   same words, amount and merchant as a purchase, and no template may keep it, let alone
   file it. A text is dropped here only when a pattern matches.
2. **The SMS templates.** Templates gain a text channel: `channel: "sms"` (absent means
   mail), `match.sms_sender` in place of `match.sender_domain`, and `date_from: "received"`
   for texts that carry no date. A template is tried on the body whatever the sender;
   `match.sms_sender` decides only whether the hit may file (D1). Go
   (`server/internal/tmpl`) and Swift (`HasalaCore/Template/Exec`) agree byte for byte,
   with the conformance sets. A template hit is a payment and is never dropped by a later
   step, whatever the sender, a person's number included: a bank text that a roaming
   network or an international gateway delivers with a numeric sender is still kept (in
   Review, because its sender does not match).
3. **The notice patterns** (D11): card blocked or activated, registrations, promotions and
   service tickets. Each is a closed, tested list (DIB's wordings). They run after the
   templates, so a payment text with a promotion line added is still a template hit and is
   kept. A text is dropped here only when a pattern matches.
4. **The payment shape.** A text with a payment shape goes to Review: the template-free
   readers (`template-free-reading.md`) prefill it, and Apple's on-device model may fill
   what they leave, but neither ever files a row. The shape depends on the sender:
   - from a **bank sender**, or with **no sender**: a payment word (a closed, bundled list
     in English and Arabic, such as "purchase", "debited", "credited", "refund",
     "reversal", "transfer", "شراء", "مشتريات", "بمبلغ", "خصم", "ايداع", "إيداع", "تحويل") and
     any number. No currency word and no card are needed, because most DIB Arabic purchase
     texts carry no currency word and most credits, reversals and transfers carry no card.
     A bank text that a changed wording takes out of its template thus still reaches
     Review. A text with no sender gets the same lenient shape because Hasala cannot tell
     a bank from a person then, and if iOS never gives the action a sender (an open check),
     every bank text arrives this way;
   - from a person's number or an unknown sender: a payment word and either an amount (a
     number with a currency word or code, in English or Arabic) or a masked card token.

   This is where other banks' payment texts go, every payment text that arrives with no
   sender, and a bank's texts that no template reads.
5. **Anything else** is dropped.

**What a drop leaves.** A text from a bank sender that step 1, 3 or 5 drops adds one to that
day's count of texts set aside for that bank, by kind: one-time code, declined, notice,
promotion, or no payment shape. Thus a pattern that wrongly matches a payment shows as a
count that the person can see in Profile › Bank alerts. A drop of a text from a person's
number, an unknown sender, or with no sender leaves no trace, because such a text can be
anyone's message; with no sender, the lenient shape of step 4 is what keeps a bank's
payment texts.

The gate leans to Review: a text from a bank sender, or with no sender, is dropped only when
an explicit drop pattern says it is not a payment, or when it has no payment word or no
number at all. The cost is that a text from a person that looks like a payment ("I sent you
AED 50"), and, with no sender, any text with a payment word and a number ("the transfer is
200"), reaches Review as a synced row with the fields of any text row (see
[The op log](#the-op-log)), such as `merchant_raw`, the amount and `last4`, until the person
deletes it. The privacy policy says so.

Nothing is sent off the phone to read a text. A merchant name read from a text can go to
Clef only under the Cloud suggestions opt-in (`cloud-suggestions.md`), and with the same
limit as mail: only a row read by a card-purchase template whose ID is in
`ModelSuggestionSweep.cloudTemplates`. For texts, only the SMS card-purchase templates (for
DIB, the Arabic and English purchase templates) may join that list. The DIB SMS templates
for transfers, salary, credits, refunds, reversals and card payments never do, because the
merchant of a transfer or a salary can be a person's name. The list stays fail-closed: a
text row from the readers, from Apple's model, or with `tier: none` has no template in the
list and is never sent. The text itself, its sender and its other fields never leave the
phone.

**Templates tonight: DIB only.** DIB has SMS templates for its payment families (Arabic and
English purchases, debits, credits and salary, reversals, refunds, own transfers and card
payments). Texts from other banks go to Review, prefilled when a reader reads them. Real
texts stay in `salehtl/hasala-fixtures`; this repository has synthetic texts only.

### Filing with no review

A text files with no review (`needs_review: false`) only when all of these hold:

- an SMS template read it;
- iOS gave the action a sender, and it is in that template's `match.sms_sender`;
- the card in the text is **known**: the account has a `card_linked` for that bank and last
  four digits with `state: mine`.

The card gate is mail's, reused as it is: `RuntimeMailboxLedger.knownCards()` reads the
projection's `card_linked` links, and `gates.card` maps them as `Disposition.finalize` does
for mail: `mine` is `known`, `not_mine` is `not_mine`, no link is `unknown`, a text with no
card is `none`. A `not_mine` card never files a text, as it never files mail; its texts go
to Review with `gates.card: not_mine`. Thus `gates.card` means the same on a text row and a
mail row.

How a text-only person's cards become `mine`: when the person confirms or sorts, in Review,
a text row whose bank and card have no `card_linked` yet, the app authors `card_linked
{bank, last4, state: mine, account}` (with `account_set` when the card's account is new)
through `RuntimeMailboxLedger.authorCards`, in the same edit as the confirm. A row that filed
itself, and a row from the readers or Apple's model that the person did not confirm, links
no card. A card that the person already linked, as `mine` or `not_mine`, from mail or
otherwise, keeps its link; the confirm does not change it.

Why the card: an alphanumeric sender ID can be faked, and iOS puts a faked "DIB" text in
the real DIB thread. Mail has the DMARC gate for this (`gates.ar: pass`); texts have no
equal. A faker must now also know a card that the person already uses with that bank. This
raises the bar; it does not close it, and the security page says so. Everything else goes
to Review, prefilled: no sender, another sender, an unknown or `not_mine` card, a text with
no card (most credits, reversals and transfers), the readers, Apple's model, and every
pasted text. A person who uses only texts thus confirms their first payment on each card in
Review.

### What the phone keeps about texts

On the device, outside the synced data, and never sent:

- the time the automation last ran (one value, overwritten on each run, for every text,
  because the app cannot see the automation any other way);
- for each bank, the time of its last text that Hasala kept;
- for each bank sender, a count for each day and each kind of texts set aside as not
  payments (steps 1, 3 and 5; see [What a drop leaves](#reading-happens-inside-hasala-on-the-phone)),
  for the last 30 days only; an older day's count is deleted;
- the copy of the server's last answer about the account's mailbox link, linked or not, and
  when it was learned (see [One source for each person](#one-source-for-each-person));
- while the account reads bank email, a count for each day of bank payment texts ignored
  for that reason (see [One source for each person](#one-source-for-each-person)), for the
  last 30 days only;
- whether a set-up test passed, and, while a test runs, the time its 10-minute window
  opened (deleted when the window closes);
- the key secret for the text keys (below), in the Keychain, this device only;
- the before-first-unlock marker (D6): a count and the arrival minute of the latest, deleted
  once the app has shown its notice.

These facts are deleted when the account is deleted and when the person signs out on that
device. The files go with the app when it is deleted. The Keychain secret is the exception:
iOS can keep a Keychain item after its app is deleted. The app deletes a secret that it finds
with no account data on its first launch after an install, and makes a new one when it next
needs it. A secret left behind by a deleted app is a random key that holds no data of the
person and opens nothing.

A text that is dropped leaves only the last-run time, which the next text replaces, and,
from a bank sender, one more in that day's count. No text body, sender or field of a dropped
text is kept. A text that is kept, from any sender, is different: a template hit, and a text
with a payment shape from a bank, a person's number, an unknown sender or no sender, becomes
a synced row in Review (or a filed row, under D1) with the fields in [The op log](#the-op-log),
such as `merchant_raw`, the amount and `last4`, until the person deletes it. Before the first
unlock, such a text adds to the D6 marker instead. The privacy policy lists each item.

### The key for each text

A text has no message ID. Its `ingest_id` is the hex HMAC-SHA256 of the channel, the sender
(empty when none), the normalized text, the arrival minute and a repeat number `n`, under a
random 32-byte secret that the phone makes once and keeps in its Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The secret never syncs. Why not a
plain SHA-256: a text is a short template plus fields that the row keeps, so a plain hash
could confirm a guess of a dropped part, such as a balance line. Why not a key derived from
the account's data key: anyone who can open the rows holds that key too.

`n` is the lowest number whose key is not in the ledger yet. "In the ledger" counts the
projection and the ops still in the outbox, as `RuntimeMailboxLedger.isIngested` does with
`store.hasPendingIngest`. The choice of `n` and the write of the op to the outbox are one
step inside one actor that every "Add bank text" run goes through, so two runs at the same
time cannot both take the same `n`: the second waits for the first's op to be in the outbox,
then sees that key as taken. The action runs only in the app's process (no App Intents
extension), so one actor covers every run on the device. Thus a key **never** makes Hasala
drop a text:

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

An **unparsed text row** is a payment-shaped text whose amount no reader could read
(`tier: none`, `unparsed: true`). `CausalDecode.decodeTxnPayload` forbids an amount, a
currency and a direction on it, and a text cannot be fetched again as mail can. So that the
person can still find the payment, it keeps what the decoder allows and what the phone has:
`bank` (from the sender list, absent when unknown), `last4` when a masked card was read,
`merchant_raw` when a reader read one (else empty), `posted_at` with `posted_precision:
time` (the date and time in the text, else the arrival minute), `received_at` and `channel:
"sms"`. Its Review card says: "Hasala couldn't read this bank text. Find the text from
\<bank\> at \<time\> in Messages, copy it and paste it here, or add the payment yourself."
The paste pre-check also matches it: a pasted text from the same bank (and the same card,
when both have one) whose date and time are within ten minutes of the unparsed row's
`posted_at`, or, when the pasted text has no date, any unparsed text row of that bank from
the last 7 days, is shown beside that row, and the sheet asks whether the paste replaces
it. On yes, the pasted row is added and the unparsed row is archived in the same edit. The
op log has no delete op: the archive is a `txn_annotated` with `field: archived`, which
`Keyed03c.annotationAllowedOnUnparsed` allows on an unparsed row, as the unread-mail flow
does today.

### The op log

A row from a text is a v4 `txn_ingested` that today's decoder folds with no anomaly (checked
on `CoreReplay` at commit `fcf0dd54`: no anomaly, a repeat with a new key inside ten
minutes is a held probable copy, the same key again is `duplicate_ingest`). It uses only
existing values in closed enums, and two keys that older clients ignore:

| Field | Value for a text row | Why |
|---|---|---|
| `ingest_id` | the HMAC key above (64 hex digits) | The ledger refuses the same key twice. |
| `entry_method` | `mailbox` | The enum is closed (`mailbox`, `manual`, `import`; `Replay/V4/TxnV4.swift`). With `mailbox`, old and new clients run the probable-copy hold (`Duplicates.swift` needs it) and show the provenance line ("DIB transaction alert", "Read automatically"), which is true of a text. With `import` or none, text rows would lose both. |
| `tier` | `template` on a template hit, `heuristic` when a reader prefilled, `none` with `unparsed: true` when nothing read (see the unparsed text row above for the fields it keeps) | The closed set in `CausalDecode.tierOf`. |
| `bank` | the template's bank, or the bank of the sender list; absent when unknown | |
| `gates.ar` | **absent** | It is a mail-only DMARC verdict. Absent, no client shows "Your mailbox couldn't confirm that this email came from your bank"; `no_ar` would. Thus `verifiedSender` is false for every text row: a text row never wins a certain-copy merge and never forms an implicit DIB transfer pair, which no account needs because mail and texts do not mix. |
| `gates.sender` | `trusted` only when the sender matched the template's `sms_sender`, else `untrusted` | |
| `gates.template` | `<id>@<version>` or `none` | |
| `gates.card` | `known`, `not_mine`, `unknown`, or `none` when the text has no card | From `knownCards()`, mapped as for mail (see [Filing with no review](#filing-with-no-review)). |
| `gates.forwarded` | `false` | |
| `gates.kind` | absent | |
| `provenance` | **absent** | With a provider, a grant and a message ID, a client treats the row as mail that it can fetch again. A text cannot be fetched. |
| `dedupe` | **absent** | `dedupe.message_id` merges rows as a certain copy at once (`detectCopy`), and equal texts can be separate payments. |
| `posted_at`, `posted_precision` | the date and time in the text, `time`; with no date in the text, the arrival minute, `time` | Probable-copy detection needs `time`. |
| `needs_review` | `false` only as in [Filing with no review](#filing-with-no-review) | |
| `channel` | `"sms"` (new, optional) | New clients show "Bank text" as the source and text-specific Review copy. Old clients ignore it. |
| `received_at` | the arrival minute (new, optional) | The D10 cutoff and the status line. Old clients ignore it. |

**On older builds.** A build from before bank texts folds text rows correctly but does not
know `channel`, so it shows them as mail. Two places read wrongly there, and this is
accepted with no minimum build: an unparsed text row is listed in Review among the bank
emails Hasala couldn't read, as an unnamed "Bank email" with no paste instruction, because
`LedgerStateMapper.unreadMail` names the bank only from a mail message's sender; and a held
probable copy of a text shows the mail copy ("Bank alerts often reach two inboxes"). Nothing
is lost or doubled: the row, its Review hold and its archive work the same. It reaches only a
person who keeps an older build on a second iPhone while texts are added on another, in a
TestFlight beta whose testers get each new build.

This is op-authoring code, which has the highest risk in the repository, thus it has its own
review before it merges.

### Build obligations

The PRs that build bank texts also do this work, which the gate and the repository rules
need:

1. **The real-text fence (PR-A, before any SMS fixture lands).** Step 0 of
   `scripts/check.sh` (the real-mail fence, which `--fence-only` runs alone in CI job
   `secrets`) covers only mail paths today. Each SMS set gets an exact-directory allowlist
   in that step, as `conformance/normalizer` has:
   - `conformance/sms-extract/`: every file must be named `synthetic-*`, except
     `README.md` (`find conformance/sms-extract -type f ! -name 'synthetic-*' ! -name
     README.md ! -name '.*'` must list nothing);
   - SMS template cases go only in `conformance/templates/sms/`, where every file must be
     named `synthetic-*` (`find conformance/templates/sms -type f ! -name 'synthetic-*' !
     -name '.*'`); a file directly in `conformance/templates/` that holds `"channel":
     "sms"` fails the fence, so an SMS case cannot sit outside the allowlisted directory;
   - any later directory `conformance/sms-*` gets the same rule in the same step before
     its first fixture lands;
   - `conformance/swift/fold-v4-sms-*.json` holds only synthetic ops, and
     `server/internal/tmpl/seed/testdata` stays fenced as it is.

   Real texts go only to `salehtl/hasala-fixtures`, at the same paths. The fence has its
   own test: a file named `corpus-1.json` or `x.json` in each of these directories makes
   `scripts/check.sh --fence-only` fail.

   **The template runners read `templates/sms/`.** Today both runners read only the top
   level of `conformance/templates`: Go `readTemplateFixtures`
   (`server/internal/tmpl/corpus_test.go`) globs `synthetic-*.json` and the private
   `corpus-*.json` there, and Swift `TemplateFixtures.files`
   (`TemplateFixtureTests.swift`) lists one directory. SMS cases in `templates/sms/` would
   never run, and the gate would stay green. PR-A extends both runners, and the Go check
   that pins the synthetic files to this build, to `conformance/templates/sms/` (public
   `synthetic-*`, private `corpus-*`). It also extends the corpus-per-seed check in
   `TestTemplateFixturesAreWhatThisBuildProduces`: a seed template with `channel: "sms"`
   needs its `corpus-<id>.json` in the private `templates/sms/`, and a mail seed template
   in the private `templates/`. The Go public-corpus guard (no `corpus-*.json` in this
   repository) covers `templates/sms/` too.
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
   - D1: a template hit with a matching sender and a `card_linked` mine card files; with
     no sender, with another sender, with an unknown card, with a `not_mine` card (as
     `gates.card: not_mine`), with no card and as a paste, it goes to Review. Confirming
     a text row with an unlinked card in Review authors `card_linked` mine in the same
     edit, and the next text on that card files; a row that filed itself, or a reader row
     left unconfirmed, links no card; a card already linked `not_mine` stays `not_mine`.
   - D10: the cutoff comes from the newest text row in the account from any device; no
     listed mail is skipped; a mail in the overlap with a text twin (also with a merchant
     string that differs from the text's, and dated minutes after it) is authored with
     `needs_review: true`; a mail in the overlap with no twin (a payment that no text
     brought in) is authored as any mail.
   - The template runners: a synthetic SMS case in `conformance/templates/sms/` runs in Go
     and in Swift (a case whose expected output is changed by hand makes each runner
     fail); with the private fixtures, an SMS seed template with no private
     `templates/sms/corpus-<id>.json` fails the corpus-per-seed check.
   - One source: "Add bank text" authors nothing while the account has a mailbox link; a
     bank payment text then adds one to that day's ignored count, a text that is not a
     payment does not, and Profile › Bank alerts shows the count with the advice.
   - The link copy: with no network, a copy that says linked authors nothing and counts;
     a copy that says not linked authors; with no copy and no network, a payment text is
     authored with `needs_review: true` and never files, also on a template hit with a
     matching sender and a known card; the copy is written on each server answer and on
     this device's connect, disconnect and switch, and is deleted on sign-out.
   - D11: a synthetic fixture for each drop kind (one-time code, declined, card blocked,
     card activated, registration, promotion, service ticket), each dropped, and from the
     DIB sender, counted by kind; a declined DIB purchase and a one-time code for a DIB
     purchase, each worded so that a DIB purchase template would read it, dropped before
     the templates and never filed, also from the DIB sender with a known card; a DIB
     template hit with a promotion line added, kept; a text from a person's number with no
     payment shape, dropped with no trace; a DIB template hit from a numeric sender, kept
     (in Review); synthetic payment texts from other banks, in Review; a synthetic Arabic
     DIB payment text with no sender that no template reads and that has no currency word
     and no card, in Review; the same text from the DIB sender, in Review; a text with no
     sender and no payment word, dropped with no trace; a text from a bank sender with no
     payment word, dropped and counted.
   - Cloud suggestions: a text row read by a DIB SMS purchase template may leave the
     device under the opt-in (`mayLeaveDevice` is true); rows read by the DIB SMS
     transfer, salary, credit, refund, reversal and card-payment templates, rows from the
     readers or Apple's model, and unparsed rows may not.
   - The key: equal texts in the same minute give two rows, the second a held probable
     copy; a double run across a minute boundary, the same; two runs of equal texts at
     the same time (started together, before either op is in the outbox) give `n` 0 and
     1 and two rows, and neither op is refused as `duplicate_ingest`; a key whose op is
     still in the outbox counts as taken; equal texts on different days, two rows with no
     hold; the secret is not in any op; the secret is deleted on sign-out and on account
     deletion, and a secret found with no account data on first launch is replaced.
   - Paste: the pre-check finds a matching row and asks; a paste never files and never
     merges by itself; a pasted text that matches an unparsed text row (same bank and
     card, within ten minutes) offers to replace it, and on yes the unparsed row is
     archived (`txn_annotated`, `field: archived`) in the same edit, and the fold accepts
     that annotation with no anomaly.
   - The unparsed text row: a payment-shaped bank text with no readable amount gives a
     row with `tier: none`, `unparsed: true`, `bank`, `last4`, `posted_at` (`time`),
     `received_at` and `channel: "sms"`, no amount, currency or direction, that today's
     decoder folds with no anomaly; its Review copy tells the person to paste the text.
   - What the phone keeps: a day's set-aside or ignored count older than 30 days is
     deleted; a set-aside count is kept for each kind; the Test window's open time is deleted when it closes.
   - D6: before the first unlock, nothing is stored but the marker; a template hit and a
     payment-shaped text each add to the marker, and a promotion, a one-time code, a
     declined purchase and a text with no payment shape do not; after the unlock, the notice shows and the marker
     is removed.
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
| D6 | What happens to a text before the first unlock after a restart? | **Decided:** no text and no field of it is stored, and there is no locked-phone inbox. The action still runs steps 1 to 4 of the reading order (the drop patterns, the templates and the payment shape), which need only bundled data. Only for a template hit or a text with a payment shape, the texts that would be kept, it writes a content-free marker (a count and the arrival minute of the latest) to a file with no data protection. It then fails with "Hasala can't save bank texts until you unlock your iPhone. Paste this text later." A text that the reading order drops leaves no marker. After the unlock, the app shows "N bank payment texts arrived while your iPhone was locked after a restart. Paste them from Messages." and removes the marker. The privacy policy and the support page use the same words: the marker counts only texts that look like a bank payment. This replaces the earlier proposal to keep raw text in an inbox until the next unlock. |
| D7 | Build the Wallet transaction trigger (Apple Pay) too? | **Decided:** not in v1. |
| D8 | Add to the 2026-10-11 decisions in CLAUDE.md? | **Decided:** yes. The "Transactions come from Gmail" line gains bank texts through the Shortcuts automation, read on the phone. |
| D9 | Which filter words catch every bank text? | **Decided:** none. One catch-all automation, because only about 5% of DIB payment texts contain "AED". |
| D10 | When a person switches from texts to email, what does email import? | **Decided:** all the mail that the connect lists, as for any connect; nothing is skipped by time, because a skip would lose payments that no text brought in. The cutoff, the newest row from a text in the account from any device, marks the overlap (mail dated at or before the cutoff plus 24 hours). A mail in the overlap that has a text twin (same bank, amount, currency, direction and card within 24 hours) waits in Review beside the twin and never files itself; the person keeps both or archives it. A mail in the overlap with no twin is authored as any mail. Thus a payment is neither lost nor counted twice without the person seeing it (see [One source for each person](#one-source-for-each-person)). The switch alert says so. A switch from email to texts needs no rule: texts start from the switch. |
| D11 | What about texts that are not bank payments? | **Decided:** declined payments and one-time codes are dropped first, before the templates, so a declined purchase or a code for a purchase is never added, even when a purchase template would read it. Then a template hit is kept whatever the sender, a person's number included. Then a text that matches a notice pattern (card blocked or activated, registrations, promotions, service tickets) is dropped. A text with no template hit and no drop match that has a payment shape goes to Review, whatever the sender, and with no sender. From a bank sender, or with no sender, the shape is a payment word and any number; from a person's number or another sender, a payment word and an amount with a currency, or a masked card. Any other text is dropped. Every text dropped is dropped on the phone at once and never stored. A drop of a bank sender's text, by a pattern or for no payment shape, adds one to that day's count for its kind on the device; a drop of any other text leaves no trace. The fixtures include each kind. |

## Open checks for the beta

Only real phones and real testers can answer these. Until each is checked, the app's copy
avoids the claim.

- Whether iOS gives the action the sender, or only the text. Without a sender, D1 sends
  every kept text to Review, and step 4 of the reading order uses the lenient shape (a
  payment word and any number) for every text, so a person's texts with a payment word and
  a number reach Review more often.
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
iPhone, that Hasala keeps only texts that look like payments and drops every other text at once
without storing it, what the phone keeps about texts, that nothing is sent to our server or
anyone else, and how to stop it. `docs/legal/support.md` has the set-up and removal steps
and how to switch between texts and email. `docs/legal/security.md` covers texts beside
bank emails, with the D1 filing rule and its limit.

The pages describe bank texts as they ship, and a merge to `main` deploys hasala.app. Thus
the legal pages merge together with, or after, the last app PR for bank texts, as the build
plan merges them with the rest before the TestFlight build. Until then their pull request
stays a draft. This record and the CLAUDE.md line change nothing on hasala.app. The app PRs
are built from this record on its branch; if one of them needs the record on `main` sooner,
`docs/legal/*` moves to its own draft pull request and the record merges first.
