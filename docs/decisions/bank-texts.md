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
  with a key that cannot be reversed to the text.
- **Nothing is dropped silently.** A bank payment text that the phone cannot read becomes a
  row in Review, prefilled when a reader reads it, as mail does in
  `ios/HasalaCore/Sources/HasalaCore/Mailbox/Disposition.swift`. Only texts that are not
  bank payments are dropped (D11).

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
ago", the last text for each bank).

### One source for each person

A person sets up bank email or bank texts, never both, on each device. Thus the same
payment cannot arrive through two channels, and no merge is needed.

- Onboarding asks "How do your banks reach you?" (email or texts, neither preselected).
- With texts set up, the mailbox connect is not offered, and the reverse.
- To change, the person switches in Profile › Bank alerts. The switch stops the old
  channel: it disconnects the mailbox, or Hasala ignores texts from then on and tells the
  person to delete the automation in Shortcuts. Rows already added stay.
- Switching from texts to email sets a cutoff (D10).

### Reading happens inside Hasala, on the phone

In this order:

1. A sender and kind gate: texts that are not bank payments are dropped (D11).
2. The SMS templates. Templates gain a text channel: `channel: "sms"` (absent means mail),
   `match.sms_sender` in place of `match.sender_domain`, and `date_from: "received"` for
   texts that carry no date. Go (`server/internal/tmpl`) and Swift
   (`HasalaCore/Template/Exec`) agree byte for byte, with the conformance sets.
3. The template-free readers (`template-free-reading.md`), which fill Review.
4. Apple's on-device model, as a fallback that only fills Review. It never files a row.

Nothing is sent off the phone to read a text. A merchant name read from a text can go to
Clef only under the Cloud suggestions opt-in, like a name read from mail
(`cloud-suggestions.md`). The text itself, its sender and its other fields never do.

**Templates tonight: DIB only.** DIB has SMS templates for its payment families (Arabic and
English purchases, debits, credits and salary, reversals, refunds, own transfers and card
payments). Texts from other banks go to Review, prefilled when a reader reads them. Real
texts stay in `salehtl/hasala-fixtures`; this repository has synthetic texts only.

### The key for each text

A text has no message ID. The key is a SHA-256 over the channel, the sender, the normalized
text and the minute it arrived. An automation that runs two times for one text then makes
one row. Identical texts at different times (for example two equal reversals) stay two
rows, which the owner's DIB texts showed is needed.

### The op log

A row from a text uses only additive optional keys, with no new values in closed enums, so
older clients still fold it. It carries an optional `channel: "sms"` for the source line.
This is op-authoring code, which has the highest risk in the repository, thus it has its own
review before it merges.

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

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Can a text file with no review? | **Decided:** only on a template hit whose `sms_sender` matches the sender that iOS gave the action. Without a sender, every text goes to Review, prefilled when a reader reads it. A pasted text always goes to Review, because the person chose the text, not the bank. The readers and the on-device model only fill Review. |
| D2 | Can a person use Hasala with texts only, with no mailbox? | **Decided:** yes. Texts are an alternative to the mailbox, thus onboarding asks which one. |
| D3 | One channel, or merge mail and texts? | **Decided (2026-10-26):** one source for each person, on each device. No merge. |
| D4 | Which banks first? | **Decided:** DIB only, tonight. Other banks' texts go to Review. More banks follow as real texts reach `hasala-fixtures`. |
| D5 | Before or after the template-free readers ship in the app? | **Decided:** with them. Texts use templates first and the readers for Review. |
| D6 | What happens to a text before the first unlock after a restart? | **Decided:** nothing is stored. There is no locked-phone inbox. The text stays in Messages, and the person can paste it into Hasala. This replaces the earlier proposal to keep raw text in an inbox until the next unlock. |
| D7 | Build the Wallet transaction trigger (Apple Pay) too? | **Decided:** not in v1. |
| D8 | Add to the 2026-10-11 decisions in CLAUDE.md? | **Decided:** yes. The "Transactions come from Gmail" line gains bank texts through the Shortcuts automation, read on the phone. |
| D9 | Which filter words catch every bank text? | **Decided:** none. One catch-all automation, because only about 5% of DIB payment texts contain "AED". |
| D10 | When a person switches from texts to email, what does email import? | **Decided:** only mail newer than the last row from a text, so the overlap is not counted twice. The switch alert says so. A switch from email to texts needs no rule: texts start from the switch. |
| D11 | What about texts that are not bank payments? | **Decided:** texts from senders that are not banks, and bank texts that are not payments (one-time codes, declined payments, card blocked or activated, registrations, promotions, service tickets), are dropped on the phone at once and never stored. At most a count is kept. A declined payment is never added. The fixtures include each kind. |

## Open checks for the beta

Only real phones and real testers can answer these. Until each is checked, the app's copy
avoids the claim.

- Whether iOS gives the action the sender, or only the text. Without a sender, D1 sends
  every text to Review.
- Whether the automation runs, and the action can write, while the iPhone is locked (after
  the first unlock).
- Whether iOS shows a banner for each run. With a catch-all automation, a banner would show
  on every text. The owner's test showed none.
- Whether the action takes the message as its input by default, so the person does not set
  it by hand.
- Whether iOS lists the action before Hasala has been opened once.
- How often other banks' texts read well enough in Review to justify their templates.

## Legal pages

`docs/legal/privacy.md` says that the automation hands each incoming text to Hasala on the
iPhone, that Hasala keeps only bank payment texts and drops every other text at once
without storing it, that nothing is sent to our server or anyone else, and how to stop it.
`docs/legal/support.md` has the set-up and removal steps and how to switch between texts and
email. `docs/legal/security.md` covers texts beside bank emails.
