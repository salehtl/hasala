# Bank texts through Shortcuts (decision record)

**Status: PROPOSED (2026-10-26). Nothing is built.** This record collects the options for
a second way in for transactions: the bank's SMS alerts, handed to Hasala on the phone by
an iOS Shortcuts automation. The questions for the owner are in
[Decisions for the owner](#decisions-for-the-owner); each one marked **Open (owner)** waits
for an answer. Every example in this file is synthetic.

## The problem

Today a transaction comes only from bank mail that the phone reads from Gmail or Outlook.
This leaves out three groups of people:

- People whose bank texts a card payment but sends no mail for it, or sends mail only when
  they turn it on.
- People who will not give a budget app access to their inbox.
- People past the Google limit. The Google OAuth consent is not verified, and it allows 100
  users or fewer.

Almost every UAE bank texts each card payment. A path for bank texts would let a person use
Hasala with no mailbox at all.

## Rules that do not change

- **The server is blind.** The text is read on the phone. hasalad never sees it, and
  nothing sends it to any other service.
- **No raw message in the op log.** As with mail, only the parsed fields go into an op,
  with a key that cannot be reversed to the text.
- **Nothing is dropped silently.** A text that the phone cannot read becomes an empty row
  in Review, or is set aside and shown, as mail is in
  `ios/HasalaCore/Sources/HasalaCore/Mailbox/Disposition.swift`.

## Options

### 1. A Messages automation that calls a Hasala action (recommended)

The app adds an App Intent, "Add bank text", with a `text` parameter and an optional
`sender` parameter. An `AppShortcutsProvider` registers it, so the action shows in Shortcuts
with nothing to install and no shared iCloud shortcut. The only App Intents today are the
widget ones (`ios/HasalaWidgets/Intents.swift`).

The person makes the automation once, in Shortcuts:

1. Automation → New → Message.
2. Filter by sender, or by "Message contains" with a word the bank's texts always use.
3. Run Immediately.
4. Action: Hasala → Add bank text, with the message as its input.

What iOS allows:

- Since iOS 17, a Message automation can run immediately, with no tap to confirm.
- iOS always shows a banner when one of these automations runs. The app cannot hide it.
- An app cannot make the automation for the person. Hasala can only guide them.
- An automation sees only texts that arrive after it is made. It cannot read older texts.

**To check on a real iPhone before any build:** the exact fields of the Message trigger,
and whether the shortcut gets the sender or only the text. Bank sender IDs are usually not
contacts, so "Message contains" may be the only filter that works. In that case the action
must check the sender itself, or treat each text as from an unknown sender.

The app needs a setup screen ("Bank texts") with the steps for each bank and a test step.
In the test step, the person sends themselves a fixed phrase. The action recognises it and
confirms that the automation works. This screen goes on the Release surface (`BuildSurface`)
only when the path operates.

### 2. Paste or share one message

A "Paste bank message" control in Review, and the same App Intent from the share sheet. This
is the only way to bring in texts from before the automation. One variant is "add from
screenshot": the phone reads a screenshot of the bank's thread with Vision text recognition,
on the device.

### 3. Wallet transaction automation (beside option 1)

The Wallet "Transaction" trigger gives the amount, the merchant and the card name when the
person pays with Apple Pay. These are fields, not text, so nothing has to be parsed. It
covers Apple Pay only. It is an early signal that the bank's text or mail later confirms,
thus it needs the merge in [Duplicates](#duplicates-across-channels).

### Ruled out

- **A shortcut that sends the text to hasalad, or forwarding to a Hasala address.** The
  server would see plaintext. Shortcuts cannot do Hasala's encryption on the device.
- **An SMS filter extension (`ILMessageFilterExtension`).** It is sandboxed and cannot share
  data with the app. Its only way out is a network request to our server, which is plaintext
  again.

## Design

### Trust

Mail has trust gates: the provider's verdict, the verified bank domain, the template hit or
the two readers' agreement, the card, the folder and the recipient check
(`Disposition.swift`). A text has none of this. Sender IDs can be faked, and the action
accepts any text that a shortcut gives it.

Proposal: a text files with no review only when a template reads it and its sender matches
the template's sender ID. Each other text goes to Review, prefilled when a reader reads it.
A text from option 2 always goes to Review, because the person chose the text, not the bank.
See D1.

### Templates

Texts need a new channel in the template definition: `match.sms_sender` in place of
`match.sender_domain`, and the date from the time the text arrived. Today a template with no
`sender_domain` fails to load (`server/internal/tmpl/def_test.go`), so the rule becomes "one
of the two". This changes `server/internal/tmpl/def.go` and the Swift port, which must agree
byte for byte. It needs:

- A new conformance set for text templates, and its entry in the `CONFORMANCE` table in
  `scripts/check.sh`.
- Synthetic texts in `conformance/`, and real texts in `salehtl/hasala-fixtures` only.
- The seed templates in `server/internal/tmpl/seed`, synced to the app with
  `swift ios/tools/templates/sync.swift`.

The template-free readers (`template-free-reading.md`) should read texts well, because texts
are short and keep a fixed form. The extraction bench (`ios/tools/extract-bench`) can measure
this on the owner's texts before any template is written.

### Duplicates across channels

**Decided by the owner (2026-10-26): a person sets up one or the other, a mailbox or bank
texts, never both.** Thus the same payment cannot arrive through two channels, and no merge
is needed.

- Setup asks once how Hasala gets payments: bank email or bank texts.
- With texts set up, the mailbox connect is not offered, and the reverse.
- To change, the person switches in Settings. The switch stops the old channel: it
  disconnects the mailbox, or Hasala ignores texts from then on and tells the person to
  remove the automation in Shortcuts. Rows already added stay.

A merge (amount, currency, card and a time window, like the DIB notice merge) is not
planned. See D3.

### The key for each text

A text has no message ID. The key is a hash of the sender, the body and the minute it
arrived. A shortcut that runs two times for one text then makes one row. Two equal payments
in the same minute would make one key, but most texts include a balance or a time, thus
their bodies differ. The hash is salted for each account, so it cannot be compared across
people.

### A locked phone

The automation can run while the phone is locked, when the keys may not be available. The
action writes the text to a small inbox file that the phone can write before it is unlocked,
then returns. After unlock, the app reads the inbox, parses each text, writes the ops and
deletes the text. The inbox never leaves the device and is not in a backup. See D6.

### The op log

A row from a text needs a new source kind in the `txn_ingested` payload. Older clients must
still read the log. This is op-authoring code, which has the highest risk in the repository,
thus it needs its own review before it merges.

### Health

The setup screen shows the last text read for each bank. When a bank that is set up sends no
text for some days, the app tells the person. Without this, an automation that stopped
working fails with no sign.

### Legal pages

`docs/legal/privacy.md` must say that bank texts are read on the phone, that they never leave
it, and what the inbox keeps until the next unlock. `docs/legal/support.md` needs the setup
steps.

## Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| D1 | Can a text file with no review? | **Open (owner).** Recommendation: only on a template hit whose sender ID matches. Each other text, and each pasted text, goes to Review. |
| D2 | Can a person use Hasala with texts only, with no mailbox? | **Decided by D3:** yes. Texts are an alternative to the mailbox, thus onboarding asks which one. |
| D3 | One channel for each bank, or merge mail and texts? | **Decided (owner, 2026-10-26):** a person sets up one or the other, never both. No merge. See [Duplicates](#duplicates-across-channels). |
| D4 | Which banks first? | **Open (owner).** It depends on whose real texts can go into `hasala-fixtures`. Recommendation: the banks that already have mail templates (DIB, ADIB, Emirates NBD), so the two channels can be compared. |
| D5 | Before or after the template-free readers ship in the app? | **Open (owner).** Recommendation: after. Texts can then use templates and the readers from the start. |
| D6 | Can the locked-phone inbox keep raw text until the next unlock? | **Open (owner).** Recommendation: yes, on the device only, deleted after it is read, and stated in the privacy policy. The other choice is to drop texts that arrive while the phone is locked, which breaks "nothing is dropped silently". |
| D7 | Build option 3 (Apple Pay through the Wallet trigger) too? | **Open (owner).** Recommendation: not in v1. It needs the merge from D3. |
| D8 | Add to the 2026-10-11 decisions in CLAUDE.md? | **Open (owner).** Recommendation: when D1 to D3 are decided, add that transactions also come from bank texts, which the phone reads; that Shortcuts gives them to the app; and that nothing sends them off the phone. |

## Build plan (when decided)

1. Check the Message trigger on a real iPhone (fields, sender, a locked phone).
2. Bench: read the owner's texts with the template-free readers in `ios/tools/extract-bench`.
3. The text channel in the template definition, in Go and Swift, with its conformance set.
4. The text ingest in HasalaCore: the key, trust, disposition and the new source kind.
5. The App Intent and the locked-phone inbox.
6. The setup screen, the test step and health.
7. The legal pages and the TestFlight What to Test.
