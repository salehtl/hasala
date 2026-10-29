# Bank texts through Shortcuts (decision record)

**Status: DECIDED (owner, 2026-10-26). Built (2026-10-27)** in #228 (templates), #229 (app
set-up and settings), #230 (HasalaCore reading and authoring), #232 (the action and the live
lane) and #231 (the overlap check, card links and Review copy). Where the build chose a
detail that the first draft of this record did not settle, the record now describes what
the code does. **Amended 2026-10-29** by [filing-without-cards.md](filing-without-cards.md):
a text files with no sender check and no card check, and no edit links a card. Bank texts are a second way in
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

### One automation that looks for a full stop

The app adds an App Intent, "Add bank text", with a `text` parameter and an optional
`sender` parameter. An `AppShortcutsProvider` in the main app target registers it, so the
action shows in Shortcuts with nothing to install and no shared iCloud shortcut. It runs
without opening the app (`openAppWhenRun = false`). A cold background launch does not start
the account's live graph: a silent push, a background task, a kept text or the app's window
starts it, so a text that the reading order drops never starts a request.

The person makes **one** automation, once, in Shortcuts:

1. Automation → New → Message.
2. No sender, and "Message Contains" set to a single full stop (`.`).
3. Run Immediately.
4. New Blank Automation → Add Action.
5. Hasala → Add bank text, with the message as its input.

There are no filter words for each bank and no automation for each bank. Why: in the
owner's DIB texts, only about 5% of the payment texts contain "AED". Most Arabic purchase
texts carry no currency word at all, so a "contains AED" filter would miss most payments,
with no sign that they are missing. A filter by sender does not work either, because bank
sender IDs are not contacts.

The first design was a catch-all automation (any sender, no "Message Contains"). On a real
iPhone (owner, 2026-10-27), Shortcuts refuses a Message automation with neither a sender
nor a "Message Contains" phrase. A single full stop is the widest phrase it allows that
still reaches every bank payment text: all 4,511 payment texts in the owner's DIB export
contain "." (each has a decimal amount, such as 12.50), and so do 429 of its 457 other
texts. (These are aggregate counts only. No text from that export is in this repository.)
A text with no full stop never reaches Hasala; a bank that writes an amount with no
decimals ("AED 50") and no other full stop would be missed (an open check).

Thus the action runs on almost every incoming text. Hasala looks at each text on the phone, keeps
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

The set-up test: when the person taps **I made it, send a test** in setup, or **Test it
again** in Profile › Bank alerts, the app opens a 10-minute window on that iPhone. A text
whose folded body is "hasala test" (any case, with trailing spaces, "." and "!" ignored)
that arrives in the window marks the test as passed,
with its time, and is then dropped like any other text that is not a bank payment. Outside
the window the same text is dropped with no trace, from any sender, a bank sender included.
The test does not depend on the sender. The app asks for "Hasala test." with the full stop,
so that the automation runs for it.

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
  nothing else. Choosing texts leads to two screens: the banks ("Which banks text you?"),
  and a short automation guide ("Make the automation") that ends with **I made it, send a
  test** or **Skip, confirm with my next bank text**. The test and the illustrated guide
  ("Show me how, step by step") are optional in setup and stay in Profile › Bank alerts
  ("Test it again", "Show me how"), where a person who skipped them can finish them later.
  Finishing the texts path sets a content-free flag on this iPhone that texts were chosen
  here (see [What the phone keeps about texts](#what-the-phone-keeps-about-texts)); without
  it, setup and Bank alerts could not tell a texts user from a person with no source. On a
  device that joins an account that already has a mailbox link, the texts choice is not
  offered; the device says that the account reads bank email and points to the switch in
  Profile › Bank alerts (on the iPhone that reads the mailbox, when that is another one).
- With texts set up, the mailbox connect is not offered, and the reverse.
- To change, the person switches in Profile › Bank alerts. The switch stops the old channel
  for the whole account: it disconnects the mailbox, or, once a mailbox link exists, "Add
  bank text" on every device authors no row from then on and the app tells the person to
  delete the automation in Shortcuts. Rows already added stay. The switch to email can be
  made on any device. The switch to texts disconnects the mailbox, and only the iPhone that
  reads the mailbox can do that: the live mailbox lane refuses a disconnect from another
  iPhone on purpose, because that iPhone holds no token for the mailbox's grant. On another
  iPhone, Bank alerts says that a different iPhone reads the mailbox and asks the person to
  disconnect it there first (or to remove Hasala on the provider's permissions page), then
  switch. A device that set up texts, or saw the automation run, while another iPhone reads
  the mailbox shows both: the sentence that tells the person to delete the automation, and
  that blocker.
- While the account has a mailbox link, "Add bank text" still runs the reading order below
  through step 4, but authors nothing and keeps no field. For each text that it would have
  kept and that may be a bank's (a template hit, or a payment shape from a bank sender or
  with no sender; not a payment shape from a person's number or an unknown sender), it adds
  one to that day's count of payment texts ignored because the account reads email: a
  number only, on the device, for the last 30 days. With no sender, a person's text with a
  payment word and a number can be counted too, so the copy says "texts that look like
  payments", not "bank payment texts". Profile › Bank alerts shows it ("3 texts that look
  like payments were ignored in the last 30 days because this account reads bank email")
  with two ways out: delete the automation in Shortcuts, or switch the account to texts.
  Thus a bank that texts some payments and mails none of them does not lose them with no
  trace. While the copy says linked, the action counts from its own reading alone: it does
  not open the account or call the authoring actor, so no secret is made and the ignored
  path never touches the network.
- While the account has a mailbox link (the link copy says linked), the app offers no
  **Paste a bank text**: Review and Profile › Bank alerts hide it, and the paste sheet,
  reached any other way, refuses with "This account reads bank email. Switch to bank texts
  in Profile › Bank alerts to paste a text." Paste is offered when the copy says not linked
  or unknown (a pasted row always waits in Review).
- "Add bank text" checks the account's mailbox link before it authors a row. The link state
  is not in the op log, and the app holds the server's answer only in memory
  (`AccountRuntime.serverLink`, nil until `GET /mailbox/link` answers), while the action may
  run cold in the background with no network. So the device keeps a **copy of the last
  answer** on disk, outside the synced data: linked or not linked, and when it was learned.
  The copy is written on every answer to `GET /mailbox/link` and on this device's own
  connect, disconnect and switch, and deleted on sign-out and account deletion. The runtime
  asks `GET /mailbox/link` after each mailbox lane run while the lane is `unlinked`,
  `other_device` or `reconnect_required`, so the copy follows the server one run after the
  lane loses its link. When this iPhone's own lane holds the link (`scanning` through
  `halted`), the copy is written as linked, as for this device's own connect; thus an email
  user who upgrades has a linked copy at once. A `reconnect_required` from a dead token keeps
  linked, because the server still answers holder. Offline, the last copy stays. One edge
  remains: a link that disappears while the lane is `halted` keeps the copy linked until the
  next retry, `reconnect_required` or answer. The action reads it:
  - **not linked**: the text is read and authored as below;
  - **linked**: the action authors nothing and counts the ignored payment texts as above;
  - **unknown** (no answer yet on this device, for example the first run after an install,
    cold in the background with no network): the action reads the text first, and asks the
    server only for a text that the reading order keeps (a template hit or a payment shape,
    after steps 1 to 4). A text that the reading order drops never starts a request, so a
    person's chat does not show the server that a message arrived. For a kept text, the
    action opens the account and asks within a 6-second budget. When it cannot, it authors
    the text as for "not linked", but always
    with `needs_review: true`, so the row never files itself. Nothing is dropped, and if the
    answer later says linked, the row waits in Review, where the person archives a copy. The
    privacy policy says that this request can follow a payment text on a device that has no
    answer yet.

  A device whose copy is stale (another device connected a mailbox since its last answer)
  can still add texts until it next hears from the server. A payment in that window can then
  show twice, from a text and from mail, and the person archives one. The window ends at that
  device's next answer (each launch, each push). It is listed in
  [Open checks](#open-checks-for-the-beta).
- A disconnect that leaves the account with no mailbox link (Profile › Bank alerts has this
  today) puts the account on texts, as the source of truth says. When this device has a
  last-run time or an ignored count from the last 30 days, and no other mailbox stays, the
  disconnect alert says so: "Your Shortcuts automation is still there. Hasala will add bank
  texts from now on." That disconnect also sets the texts-chosen flag on this iPhone, so
  Bank alerts shows the texts page. A device that never saw the automation run and never
  finished the texts path shows no source until the person picks one.
- **Every mailbox connect on an account that has text rows** runs the overlap check (D10),
  whatever led to it: the switch from texts to email, "Add a mailbox" after a disconnect,
  the setup's connect, or a takeover. The build applies it to every mail that the engine
  authors, not only the first listing of a connect: the scan, the backfill, normal cycles
  and "Add a sender". This matters for a reconnect after a lost link, which resumes from the
  kept watermark and lists only mail since then. The check reads only the synced ledger
  (the engine syncs to the ledger head before each active cycle), so it does not depend on
  which flow or which device made the connect, and an account with no text row skips it.
  The engine reads the text rows at most once per serialized run, and only when that run
  authors mail; if it cannot read them, the run stops as offline before any mail is parsed
  or authored, so no mail is authored unchecked. The overlap is the mail dated from the
  oldest text row in the account minus 24 hours to the newest text row plus 24 hours (by
  its posted time or its internal date), text rows from any device included; the span counts
  archived text rows too, which can only widen it. The check skips no mail. The build plan's
  `MailboxState.floorMs` (skip mail before the switch) was not built.
- In the overlap, a mail that has a **text twin** is authored with `needs_review: true`,
  whatever its gates, and its Review card names the twin ("This may be the same payment as a
  bank text from DIB on 9 October", or "a bank text on …" when the text row has no bank),
  under the review reason "Same payment?" with the buttons **Same payment, archive it** and
  **Keep both, sort it**. The op log has no field that names the twin, so the read model
  finds it again from the live text rows; the line shows on any mail row in Review that has
  a twin, not only on rows that the check held. Twin candidates are live text rows only: a
  mail beside a text row that the person archived is authored as any mail. The twin test is
  loose on purpose, because a bank's mail and its text often differ, and a false twin only
  costs one Review card. A text row is a twin of the mail (which needs parsed fields; an
  unread mail waits in Review anyway) when its `posted_at` is within 24 hours of the mail's,
  its direction is the mail's or the text row is unparsed (an unparsed row has no
  direction), and:
  - its bank is the mail's, or it has no bank (a text row with a bank is no twin of a mail
    with none);
  - its card is the mail's, or either side has no card (a text often names no card where
    the mail names an account ending, and the reverse);
  - its amount and currency are the mail's, or the two currencies differ (one side shows a
    foreign amount and the other the AED amount), or the text row is unparsed and has no
    amount.

  A mail in the overlap with no text twin is authored as any mail, because no text brought
  that payment in: a text that the automation missed, that arrived before the first unlock
  and was not pasted, or that the reading order set aside. When the merchant strings match,
  the fold's probable-copy hold applies too. The twin test does not use the merchant, because
  a bank's mail and its text often spell it differently. A payment can still show twice when
  its mail and its text differ more than this (for example a fee added to one amount); the
  person archives one.

### Reading happens inside Hasala, on the phone

First, the sender is sorted, and nothing is dropped for it yet: a sender on the bundled list
of bank sender IDs is a **bank sender**; a full phone number (8 to 15 digits, with an
optional leading "+" and spaces, dashes, dots or brackets) is a **person's number**; any
other sender is an **unknown sender**; and a text that iOS gives with no sender has **no
sender**. The sender is trimmed and ASCII-lowercased before the lookup. The bank sender list
is the SMS templates' `match.sms_sender` values plus a bundled list of other UAE banks'
sender IDs (`BankTextSenders.knownBankSenders`), so other banks' texts are bank senders too:
they get the lenient shape and their set-aside counts. The set-up test (above) is checked
before step 1. A text longer than 16 KB (`TextGate.maxTextBytes`, far beyond any SMS) is
dropped as no payment shape.

A drop pattern never drops a payment text just because one of its lines matches. Each drop
kind (one-time code, declined, notice, promotion) has two closed, tested lists:

- **Whole-body patterns**: DIB's own wordings of that kind. A whole-body pattern matches
  only when it covers the whole normalized text, with its fields (a code, an amount, a
  merchant, a date) as wildcards, as a template does. A text that one covers is dropped.
- **Markers**: narrow generic signs of that kind, for other banks and changed wordings. A
  one-time-code marker is a code word ("OTP", "code", "passcode", "رمز") directly beside a
  code of 4 to 8 digits ("OTP is 482913", "482913 is your code"; "NNNN is your code" needs
  the "is"); a warning line such as "never share your OTP" has no code and is no marker. A
  code word right after "auth", "approval", "ref", "reference", "transaction", "txn",
  "promo", "voucher", "coupon", "discount", "referral" or "gift" is no marker, so a payment
  text that carries an approval code, or a promotion with a promo code, is not dropped as a
  one-time code. A declined marker is a phrase such as "declined", "was not approved",
  "unsuccessful", "insufficient funds", "incorrect PIN", "تم رفض". A notice marker is a
  phrase such as "card has been blocked", "has been activated", "registration request",
  "registration successful", "service request", "ticket number"; the bare words
  "registration", "registered", "activated" and "deactivated" are not markers, because they
  dropped payment texts such as "spent on your registered card". A promotion marker is a
  line such as "T&C apply", "SMS STOP to", "unsubscribe", "offer valid till", "عرض".

  A marker drops a text only when the text has **no transaction clause**: a closed list of
  phrases that state a completed movement of money (`TextGate.Markers.transactionClause`):
  "debited", "credited", "deducted", "deposited", "withdrawn", "transferred", "refunded",
  "reversed" (not after "will be" or "to be"); "has been / was charged, used, paid, spent,
  sent"; "you paid, spent, sent"; an amount followed by "spent", "charged", "paid", "used",
  "sent" or "received"; "<purchase, transfer, payment, withdrawal, transaction or order> of
  <amount> ... completed, confirmed, successful, approved, processed, complete or done", with
  "will", "once", "pending", "not", "n't" and "to be" shut out; "successful purchase"; and
  "تم خصم", "تم إيداع", "تم تحويل", "تم سداد", "تم إرجاع", "تمت عملية" and their family.
  DIB's bare noun wordings ("مشتريات بمبلغ", "خصم N في") are not clauses; otherwise a one-time
  code for a DIB purchase, worded so that a DIB purchase template would read it, would not
  drop. A text with a marker and a transaction clause goes on to the next step.

  A second, wider list, the **payment statement** (`paymentStatement`), holds only against
  notice and promotion markers (step 3), not against one-time-code and declined markers
  (step 1): a payment stated at the start of a sentence or a line, or after a comma, a colon,
  an Arabic comma or a short lead-in ("your", "dear customer", "thank you for your", "عزيزي
  العميل"), such as "Purchase of AED 89.50 at …", "Paid AED 20.00 …", "AED 50.00 purchase",
  "Purchase: AED 50.00", "مشتريات بمبلغ …", or a payment word near an amount that is not
  promoted ("spend AED 500 and earn …" is not one). Thus a payment text whose wording no
  template reads and that ends with a promotion line still reaches Review. A template-free
  text that states a payment and carries a code line but no completion word is dropped as a
  one-time code (for example "Purchase of AED 50.00 at SAMPLE SHOP. OTP 482913", fixture
  `generic-statement-otp`), counted for a bank sender. A DIB text in a changed wording that
  no template reads, that has a notice or promotion marker and neither a clause nor a
  statement, is dropped and counted under that kind, where the person can see it in Profile ›
  Bank alerts.

Then, in this order:

1. **The never-a-payment patterns** (D11): one-time codes and declined payments, by the two
   lists above. They run before the templates, because a declined purchase, or a one-time
   code for a purchase, can carry the same words, amount and merchant as a purchase, and no
   template may keep it, let alone file it. A text is dropped here only when a whole-body
   pattern covers it, or when it has a marker and no transaction clause. A text that has a
   one-time-code or declined marker and goes on is **marked**: it never files
   (`needs_review: true`), even on a template hit.
2. **The SMS templates.** Templates gain a text channel: `channel: "sms"` (absent means
   mail), `match.sms_sender` in place of `match.sender_domain`, and `date_from: "received"`
   for texts that carry no date. A template is tried on the body whatever the sender;
   `match.sms_sender` sets only `gates.sender` (since 2026-10-29 it does not decide filing). Go
   (`server/internal/tmpl`) and Swift (`HasalaCore/Template/Exec`) agree byte for byte,
   with the conformance sets. A template hit is a payment and is never dropped by a later
   step, whatever the sender, a person's number included: a bank text that a roaming
   network or an international gateway delivers with a numeric sender is still kept, and
   may file. On a template hit, the template-free readers
   check the template's amount, as for mail (`CombinedReader.templateVerdict`). A hit with a
   reader hold (the AED amount not confirmed, the readers disagree, a currency that is not
   ISO, a pending phrase) is **held**: it is kept and never files. A hit with a pending-status
   signal, which mail would set aside, is kept as held too, because a template hit is never
   dropped.
3. **The notice patterns** (D11): card blocked or activated, registrations, promotions and
   service tickets, by the two lists above. They run after the templates, so a payment text
   with a promotion line added is still a template hit and is kept. A text is dropped here
   only when a whole-body pattern covers it, or when it has a marker and neither a
   transaction clause nor a payment statement; a payment text that misses its template and
   carries a promotion line has one of the two and goes on to step 4.
4. **The payment shape.** A text with a payment shape goes to Review: the template-free
   readers (`template-free-reading.md`) prefill it, and they never file a row. When the
   readers do not read a transaction (their outcome is `pending` or `not_transaction`, or no
   amount), the text becomes an unparsed text row in Review, not a drop and not a prefilled
   amount. Apple's on-device model does not read texts in v1 (see [Cut from v1](#cut-from-v1)).
   The shape depends on the sender:
   - from a **bank sender**, or with **no sender**: a payment word (a closed, bundled list,
     `TextGate.Shape.paymentWord`: in English "purchase", "purchased", "debited",
     "credited", "refund", "reversal", "reversed", "transfer", "withdrawal", "deposit",
     "payment", "paid", "spent", "charged", "sent", "received", "used", "transaction",
     "txn" and their forms; in Arabic "شراء", "مشتريات", "بمبلغ", "خصم", "ايداع", "تحويل",
     "سحب", "سداد", "ارجاع", "استرداد", "دفع", "راتب", "حواله", matched after the gate's
     fold (`RuleText.fold`: "أ", "إ" and "آ" to "ا", "ة" to "ه", "ى" to "ي", no diacritics); "credit" and "debit" alone are left out, because DIB card
     notices are full of them; "sent" is needed for "I sent you AED 50" and "used" for "card
     was used for AED …") and any number. No currency word and no card are needed, because most DIB Arabic purchase
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
payment texts. Before the first unlock after a restart, a drop leaves no count either: the
counts live in protected storage, and the action writes only the D6 marker then.

The gate leans to Review: a text from a bank sender, or with no sender, is dropped only when
an explicit drop pattern says it is not a payment, or when it has no payment word or no
number at all. The cost is that a text from a person that looks like a payment ("I sent you
AED 50"), and, with no sender, any text with a payment word and a number ("the transfer is
200"), reaches Review as a synced row with the fields of any text row (see
[The op log](#the-op-log)), such as `merchant_raw`, the amount and `last4`, until the account is
deleted. The app has no delete for a transaction: Review's **Dismiss** and the transaction
sheet's **Archive** author `txn_annotated` with `field: archived`, which **Restore** undoes,
so an archived text row stays sealed on every device and on the server. The privacy policy
says so.

**The merchant on a row that may be a person's text.** A row whose text came from a person's
number, an unknown sender or with no sender, and that no template read, keeps a merchant
only from a reader's merchant label for a card purchase ("at", "merchant", "merchant name",
"لدى", "التاجر", "اسم التاجر", `TextGate.cardPurchaseLabels`), and only its first 4 words, at
most 40 bytes. A merchant read from "to" or "from", the payee or payer
of a transfer, is not kept. Otherwise `merchant_raw` is empty and the person names the payment in Review. Thus a
person's message ("transfer the 200 to Ahmed for dinner tonight") never becomes a synced
merchant made of its words. A template hit keeps the merchant as read; a reader row from a
bank sender keeps the reader's merchant, cut to the readers' usual limit
(`MessageDisposer.readerMerchantLimit`).

**Learned layouts.** The readers learn a sender's layouts as they do for mail
(`template-free-reading.md`), but only from texts that Hasala keeps from a sender on the bank
sender list (key `sms:<sender id>`) or with no sender (key `sms:`, since 2026-10-29), template
hits included. Unlike mail's, text layouts are
**not persisted**: they live only in the memory of the `BankTextAuthor` actor (one for each
account runtime), are lost when the process ends, and never reach disk, because the list in
[What the phone keeps about texts](#what-the-phone-keeps-about-texts) does not name them. To
keep them across launches, that list and the privacy policy must first name them, with
deletion on sign-out and account deletion.

The action reads each text once to choose its path (test, drop, ignore, marker or author),
and the authoring actor reads it again with the same bundled data and its learned layouts;
the actor's reading decides. A text that the first reading keeps and the second drops is
returned as a drop. In practice this does not happen, because the drop steps run before the
readers and do not use the layouts.

Nothing is sent off the phone to read a text. A merchant name read from a text can go to
Clef only under the Cloud suggestions opt-in (`cloud-suggestions.md`), and with the same
limit as mail: only a row read by a card-purchase template whose ID is in
`ModelSuggestionSweep.cloudTemplates`. For texts, only the SMS card-purchase templates (for
DIB, `dib.sms.purchase.v1`) may join that list. The DIB SMS templates
for transfers, salary, credits, refunds, reversals and card payments never do, because the
merchant of a transfer or a salary can be a person's name. The list stays fail-closed: a
text row from the readers, or with `tier: none`, has no template in the list and is never
sent. The text itself, its sender and its other fields never leave the
phone. A Clef answer on a text row keeps the row's own `needs_review`
(`ModelSuggestionSweep.items`), so "Sort automatically" never files a text row that D1 sent
to Review. Apple's on-device stage is not asked about a merchant subject that a text row
in the same sweep's queue carries, and no cached on-device answer is applied to it, queued
mail rows with the same subject included (`ModelSuggestionSweep.mayStayOnDevice`). Only
queued rows count: a text row that is not in the queue (already categorized, a credit, or
with a last pick) does not hold back its subject, so a queued mail row with that subject can
still be asked of Apple's model. Nothing leaves the device, and the text row is not changed.

**Templates tonight: DIB only.** DIB has SMS templates for each payment family in the
owner's DIB export (purchases, debits, credits, salary, refunds, reversals, own transfers
and card payments), in the wordings that export holds: Arabic, and English for reversals.
There is no English template for the other families, because the export has no real
English wording to copy, and a template written from a guess could file wrong rows under
D1. A DIB text in a wording that no template reads, such as an English purchase text, goes
to Review, prefilled when a reader reads it. Texts from other banks go to Review the same
way. Real
texts stay in `salehtl/hasala-fixtures`; this repository has synthetic texts only. On the
owner's private DIB export (aggregate counts only), every payment text is kept by a
template, and the texts dropped are one-time codes, notices, promotions, declined payments
and texts with no payment shape. Until the open check on the sender is answered, the app
says of DIB "Hasala reads them; some wait in Review" and "Hasala reads DIB texts for you,
though some still wait in Review", and of other banks "Hasala learns their wording; the first wait in Review" and
"Texts from your other banks wait in Review until Hasala learns their wording". A text that
looks like a payment, from any sender, is added when Hasala can read it, else it waits in
Review.

### Filing with no review

Amended 2026-10-29 ([filing-without-cards.md](filing-without-cards.md)). A text files with
no review (`needs_review: false`) only when all of these hold:

- the automation handed it (a paste never files);
- its fields were read, and either an SMS template read it with no reader hold (step 2),
  or, with no template, the two template-free readers agree on amount, currency and
  direction, each at 0.8 or more (`ExtractReading.meetsFilingBar`, the rule mail uses;
  `BankTextKept.readerConfident`);
- and nothing else holds it: the text has no one-time-code or declined marker (step 1 of the
  reading order), no text of the other transfer role matches it (see
  [The transfer pair on texts](#the-transfer-pair-on-texts)), and the link state is not
  linked (as the copy says, or as the server answered within the action's budget when there
  was no copy); an unknown state with no answer never files.

There is no sender check and no card check (`BankTextPayload.filesItself`). The Shortcuts
automation passes no sender, so the sender check that this record first decided never
passed, and every text waited in Review. `gates.sender` still records whether the sender
matched the template's `sms_sender`, for display only. New text rows have no `gates.card`.

No edit links a card. Sorting a text row in Review, Add category, marking a transfer or a
refund and a split write only their own ops, and their undo writes back only what they
changed. Older builds wrote `card_linked` and `account_set` for a confirmed text row; the
fold still reads them.

The risk: an alphanumeric sender ID can be faked, and iOS puts a faked "DIB" text in the
real DIB thread. Mail has the DMARC gate for this (`gates.ar: pass`); texts have no equal. A
faked text that a template reads, or that the readers agree on, files a payment, and the
person archives it. Everything else goes to Review, prefilled: a reader row that the readers
do not both confirm, and every pasted text.

### What the phone keeps about texts

On the device, outside the synced data, and never sent:

- whether texts were chosen on this iPhone (a content-free flag: set when the person
  finishes the texts path in setup or switches to texts, and by a disconnect that leaves no
  mailbox link on a device that saw the automation run; `BankTextsFactsData.chosen`, read as
  `OnboardingStep.Facts.textsChosen`);
- the time the automation last ran (one value, overwritten on each run, for every text
  handed to the action while the person is signed in and after the first unlock, because
  the app cannot see the automation any other way);
- for each bank, the time of its last text that Hasala added as a row;
- for each bank sender ID (the sender as iOS gave it, with its bank), a count for each day
  and each kind of texts set aside as not payments (steps 1, 3 and 5; see
  [What a drop leaves](#reading-happens-inside-hasala-on-the-phone)), for the last 30 days
  only; an older day's count is deleted. Profile › Bank alerts shows them in a "Set aside"
  section, one row for each bank sender ("11 texts set aside in the last 30 days" and a list
  by kind), with the footnote "Texts from your banks that aren't payments. Hasala drops them
  at once and keeps only these counts, on this iPhone. If a payment is counted here, paste
  it.";
- the copy of the server's last answer about the account's mailbox link, linked or not, and
  when it was learned (see [One source for each person](#one-source-for-each-person));
- while the account reads bank email, a count for each day of texts that look like
  payments, ignored for that reason (see
  [One source for each person](#one-source-for-each-person)), for the
  last 30 days only;
- the time the last set-up test passed, and, while a test runs, the time its 10-minute
  window opened (cleared by the next read or update of the facts after the window closes,
  `BankTextsFactsData.prune`, so it can stay in the file until the next text or app open);
- the key secret for the text keys (below), in the Keychain, this device only;
- the before-first-unlock marker (D6): a count and the arrival minute of the latest, deleted
  once the person answers the app's notice, once it is added to the ignored count, or when
  the app opens signed out.

The facts are one file (`Application Support/Hasala/texts/facts.json`, protected until the
first unlock); the marker is another (`Application Support/Hasala/texts-locked/marker.json`,
with no data protection, so that it can be written before the first unlock). The learned
layouts (above) are in memory only and are not on this list. Nothing else is kept. While
the person is signed out on the device, the action stores nothing at all, not even the
last-run time.

These facts are deleted when the account is deleted and when the person signs out on that
device (every path that leaves the account: sign-out, sign-out everywhere, the 401 after an
operator freeze, account deletion and device removal, through `LiveAccountService.left()`
and `LocalAccountData.forget`). The files go with the app when it is deleted. The Keychain secret is the exception:
iOS can keep a Keychain item after its app is deleted. The app deletes a secret that it finds
with no account data on its first launch after an install, and makes a new one when it next
needs it. A secret left behind by a deleted app is a random key that holds no data of the
person and opens nothing.

A text that is dropped leaves only the last-run time, which the next text replaces, and,
from a bank sender, one more in that day's count. No text body, sender or field of a dropped
text is kept. A text that is kept, from any sender, is different: a template hit, and a text
with a payment shape from a bank, a person's number, an unknown sender or no sender, becomes
a synced row in Review (or a filed row, under D1) with the fields in [The op log](#the-op-log),
such as `merchant_raw`, the amount and `last4`, until the account is deleted (archiving hides
it; the op log has no delete). Before the first
unlock, such a text adds to the D6 marker instead (only a template hit, or a payment shape
from a bank sender or with no sender). The privacy policy lists each item.

### The key for each text

A text has no message ID. Its `ingest_id` is the hex HMAC-SHA256 of the channel, the sender
(empty when none; trimmed and ASCII-lowercased, so case variants of one bank sender ID share
keys), the normalized text, the arrival minute and a repeat number `n` (each field
length-prefixed), under a
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
then sees that key as taken. The serial is `RuntimeMailboxLedger.textWrites`, which every
`BankTextAuthor` on that ledger shares; the app builds one `RuntimeMailboxLedger` for each
account (`AccountRuntime`). The action runs only in the app's process (no App Intents
extension), so one serial covers every run on the device. Thus a key **never** makes Hasala
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
paste minute (its `received_at` is the paste minute too), and cannot match the automation's
key. The app tells a pasted text with no date from a dated one by reading it a second time
with a later paste time: when the posted time moves with it, the text carries no date, and
the sheet says "This text has no date, so Hasala dates it when you paste it. Change the date
in Review if the payment was earlier." Instead, before it adds a pasted text,
the paste sheet looks for a live row, from a text or from mail, with the same bank (or no
bank on either side), amount, currency and direction, the same card or no card on either
side, and a `posted_at` within
24 hours of the text's date and time, or within the last 7 days when the text carries no
date. The pre-check does not use the merchant, because a bank's mail and its text often
spell it differently, so a pasted text for a payment that a mail row from before a switch
already holds is shown beside that row. When it finds one, it shows that row and asks before
it adds the text; a false match costs only the question. A pasted row never merges by
itself. The support page tells people that the sheet does this.

An **unparsed text row** is a payment-shaped text whose amount no reader could read
(`tier: none`, `unparsed: true`). `CausalDecode.decodeTxnPayload` forbids an amount, a
currency and a direction on it, and a text cannot be fetched again as mail can. So that the
person can still find the payment, it keeps what the decoder allows and what the phone has:
`bank` (from the sender list, absent when unknown), `last4` when a masked card was read,
`merchant_raw` when a reader read one (else empty, with the limits for a person's text),
`posted_at` with `posted_precision: time` (the date and time in the text when the text
gives a time, else the arrival minute), `received_at`, `channel: "sms"`, `gates.template:
none`, `gates.sender: untrusted`, and `gates.card` from the last4 when a masked card was
read (`known`, `not_mine`, `unknown` or `none`). Its Review card says: "Hasala couldn't read
this bank text. Find the text from \<bank\> at \<time\> in Messages, copy it and paste it
here, or add the payment yourself." \<time\> is the text's `received_at`, because Messages
lists texts by arrival, with the date added when it is not today ("at 12:00 on Fri 5 Jun");
with no bank it says "Find the text at …"; while the account reads email (no paste), it
drops "copy it and paste it here". Review lists these rows in a "Bank texts" page
("Hasala couldn't turn these texts into a payment. Paste each one again, add it yourself,
or dismiss one you don't need."), and Home's bell has an item "N bank texts we couldn't
read" with the neutral line "Add each one by hand or dismiss it". The cards and the
transaction sheet show only the parsed fields and this copy, never a text body (Paper's B3
and B4 show one; the record forbids keeping it); the source title is "Bank text from DIB",
and the provenance line is "Received \<time\> · read automatically", from `received_at`.

**When the ledger refuses an op.** If the ledger refuses a text row's op (`invalid_op`,
`op_too_large`, `refused`), the author tries again with the same key as an unparsed row,
then as an unparsed row with no merchant, then with no merchant, bank, card or text time.
Thus a refusal never drops a kept text; at worst it is an unparsed row in Review.
The paste pre-check also matches it: a pasted text from the same bank (and the same card,
when both have one) whose date and time are within ten minutes of the unparsed row's
`posted_at`, or, when the pasted text has no date, any unparsed text row of that bank from
the last 7 days, is shown beside that row, and the sheet asks whether the paste replaces
it. On yes, the pasted row is added and the unparsed row is archived in the same edit. The
op log has no delete op: the archive is a `txn_annotated` with `field: archived`, which
`Keyed03c.annotationAllowedOnUnparsed` allows on an unparsed row, as the unread-mail flow
does today.

### The transfer pair on texts

DIB's mail sends a transfer notice and an account debit alert for one movement, and the fold
pairs them (`DuplicateRules.implicitTransferPair`, only for rows with `gates.ar: pass`). If
DIB texts the same pair, two text rows with different merchants would count the movement
twice with no hold. So the check is made when a text row is authored, not in the fold:

- Each DIB SMS template has a transfer role in the bundled template data, the optional
  top-level key `transfer_role` (`notice` or `alert`; absent means no role):
  `dib.sms.own-transfer.v1` is **notice**, `dib.sms.debit.v1` is **alert**, the others have
  none. `ValidateDefinition` requires every direction entry, and every `on_match` that sets a
  direction, of a template with a role to be `debit`. Swift reads the role with
  `TextTransferRole.of(templateRef:)`.
- When "Add bank text" authors a debit row whose template has a role, it looks for a live
  text row of the other role with the same bank, direction, amount and currency, whose
  `posted_at` is within `DuplicateRules.transferCopyWindowMs` (30 minutes) of the new row's
  (`BankTextTransferPair.partner`). When it finds one, the new row is authored with
  `needs_review: true`, whatever D1 says; only the second row is held, and neither row is
  changed in the fold. The op log has no field that names the partner, so the read model
  finds it again from the live text rows for the Review card ("This may be the same transfer
  as the bank text from DIB at 12:31", with the other row's posted time). The person keeps
  both or archives one. Nothing is merged by itself. Since 2026-10-29 the first row of the
  pair files under D1 when nothing else holds it, so the hold is what keeps the pair from
  counting twice.
- The check does not use the sender or DMARC: texts have no sender check since 2026-10-29.

Whether DIB texts both for one movement is an open check; the check above is built either
way, because a missing hold doubles a payment silently and a needless one costs one Review
card.

### The op log

A row from a text is a v4 `txn_ingested` that today's decoder folds with no anomaly (checked
on `CoreReplay` at commit `fcf0dd54`: no anomaly, a repeat with a new key inside ten
minutes is a held probable copy, the same key again is `duplicate_ingest`). It uses only
existing values in closed enums, and two keys that older clients ignore:

| Field | Value for a text row | Why |
|---|---|---|
| `ingest_id` | the HMAC key above (64 hex digits) | The ledger refuses the same key twice. |
| `entry_method` | `mailbox` | The enum is closed (`mailbox`, `manual`, `import`; `Replay/V4/TxnV4.swift`). With `mailbox`, old and new clients run the probable-copy hold (`Duplicates.swift` needs it) and show a provenance line; new clients show "Bank text from DIB" and "Received <time> · read automatically" for a text row, old clients the mail wording ("Read automatically"). With `import` or none, text rows would lose both. |
| `tier` | `template` on a template hit, `heuristic` when a reader prefilled, `none` with `unparsed: true` when nothing read (see the unparsed text row above for the fields it keeps) | The closed set in `CausalDecode.tierOf`. |
| `bank` | the template's bank, or the bank of the sender list; absent when unknown | |
| `gates.ar` | **absent** | It is a mail-only DMARC verdict. Absent, no client shows "Your mailbox couldn't confirm that this email came from your bank"; `no_ar` would. Thus `verifiedSender` is false for every text row: a text row never wins a certain-copy merge and never forms the fold's implicit DIB transfer pair. The fold does not change for texts, because a fold rule that new builds apply and old builds do not would give two builds different ledgers. The text-side pair is checked when the row is authored instead (see [The transfer pair on texts](#the-transfer-pair-on-texts)). |
| `gates.sender` | `trusted` only when the sender matched the template's `sms_sender`, else `untrusted` | |
| `gates.template` | `<id>@<version>` or `none` | |
| `gates.card` | absent since 2026-10-29; older builds wrote `known`, `not_mine`, `unknown` or `none` | The fold still reads it. |
| `gates.forwarded` | `false` | |
| `gates.kind` | absent | |
| `provenance` | **absent** | With a provider, a grant and a message ID, a client treats the row as mail that it can fetch again. A text cannot be fetched. |
| `dedupe` | **absent** | `dedupe.message_id` merges rows as a certain copy at once (`detectCopy`), and equal texts can be separate payments. |
| `posted_at`, `posted_precision` | the date and time in the text, `time`; with no date in the text, the arrival (or paste) minute, `time`; with a date but no time, a minute inside the text's own local day, taken from the arrival or paste minute, `time`: the arrival minute when it falls on that day, 00:00 of that day when the arrival is earlier, and, when the arrival is later, as far before the day's end as the arrival was after it, wrapping each 24 hours (`BankTextKept.timed`) | Probable-copy detection needs `time`, and the text's date must stay, so that month totals, the D10 window, the paste pre-check, the probable-copy hold and the transfer pair work across midnight (in the owner's DIB export, aggregate counts only, about 3% of DIB date-only payment texts arrive the day after their date). Equal date-only texts that arrive hours apart are not held as probable copies; the fold's `possible_duplicate` notice (same last4, amount, direction, merchant and UTC day) still marks them, as a notice, not a hold, as with mail. |
| `needs_review` | `false` only as in [Filing with no review](#filing-with-no-review) | |
| `channel` | `"sms"` (new, optional) | New clients show "Bank text" (or "Bank text from \<bank\>") as the source and text-specific Review copy. Old clients ignore it. |
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
     its first fixture lands (as built, one generic rule covers every file under a
     `conformance/*sms*/` or `conformance/*text*/` path, nested ones included);
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
   `synthetic-*`, private `corpus-*`). It also extends the corpus-per-seed check, which now
   lives in `TestEverySeedTemplateHasACorpusFixture` (`server/internal/tmpl/seed/lists_test.go`,
   through `corpusFixtureGaps`), because only the seed package can see the text seeds: a
   seed template with `channel: "sms"`
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
   - D1 (amended 2026-10-29): a template hit files with no sender, another sender, a
     numeric sender, any card or none; a text that no template reads files once the two
     readers agree on it at 0.8 or more, and goes to Review before they do; a paste, a
     marked text, a held hit, a transfer partner and an unknown or linked state go to
     Review. No edit in Review writes `card_linked` or `account_set`.
   - D10: the overlap comes from the oldest and newest text rows in the account from any
     device; no listed mail is skipped; a mail in the overlap with a text twin (also with a
     merchant string that differs from the text's, and dated minutes after it) is authored
     with `needs_review: true`; twins also match when the text has no card and the mail
     names one, when the mail has no card and the text names one, when the text shows a
     foreign amount and the mail the AED amount, when the text row has no bank, and when the
     text row is unparsed; a mail with another amount in the same currency, or the other
     direction, is no twin; a mail in the overlap with no twin (a payment that no text
     brought in) is authored as any mail; the check runs on the switch, on "Add a mailbox"
     after a disconnect (with an automation still adding texts in between), and on a
     takeover, and not on an account with no text row; the disconnect alert names the
     automation when this device saw it run.
   - The template runners: a synthetic SMS case in `conformance/templates/sms/` runs in Go
     and in Swift (a case whose expected output is changed by hand makes each runner
     fail); with the private fixtures, an SMS seed template with no private
     `templates/sms/corpus-<id>.json` fails the corpus-per-seed check.
   - One source: "Add bank text" authors nothing while the account has a mailbox link; a
     template hit, or a payment-shaped text from a bank sender or with no sender, then adds
     one to that day's ignored count; a payment-shaped text from a person's number or an
     unknown sender, and a text that is not a payment, do not; Profile › Bank alerts shows
     the count with the advice. With the link copy saying linked, Review and Profile › Bank
     alerts show no paste action and the paste sheet refuses; with it saying not linked or
     unknown, paste is offered.
   - The link copy: with no network, a copy that says linked authors nothing and counts;
     a copy that says not linked authors; with no copy and no network, a payment text is
     authored with `needs_review: true` and never files, also on a template hit; with no copy, a text that the reading order drops
     sends no request to the server, and a kept text does; the copy is written on each
     server answer and on this device's connect, disconnect and switch, and is deleted on
     sign-out.
   - D11: a synthetic fixture for each drop kind (one-time code, declined, card blocked,
     card activated, registration, promotion, service ticket), each dropped, and from the
     DIB sender, counted by kind; a declined DIB purchase and a one-time code for a DIB
     purchase, each worded so that a DIB purchase template would read it, dropped before
     the templates and never filed, also from the DIB sender; a DIB
     template hit with a promotion line added, kept; a text from a person's number with no
     payment shape, dropped with no trace; a DIB template hit from a numeric sender, kept
     (it may file); synthetic payment texts from other banks, in Review; a synthetic Arabic
     DIB payment text with no sender that no template reads and that has no currency word
     and no card, in Review; the same text from the DIB sender, in Review; a text with no
     sender and no payment word, dropped with no trace; a text from a bank sender with no
     payment word, dropped and counted. For the drop lists: a synthetic DIB payment text
     whose wording no template reads, once ending with "never share your OTP" and once with
     a promotion line ("T&C apply"), from the DIB sender and with no sender, each kept in
     Review and not counted as set aside; a generic one-time code for a purchase ("OTP
     482913 for your purchase of USD 20 at a synthetic shop") and a generic declined
     purchase from another bank's sender, each dropped; a text with a one-time-code or
     declined marker and a transaction clause, kept and never filed, also on a template hit; a promotion with a payment word and a number
     and no transaction clause, dropped as a promotion; each DIB whole-body pattern dropping
     its fixture, and not a fixture with one more payment line.
   - Cloud suggestions: a text row read by a DIB SMS purchase template may leave the
     device under the opt-in (`mayLeaveDevice` is true); rows read by the DIB SMS
     transfer, salary, credit, refund, reversal and card-payment templates, rows from the
     readers, and unparsed rows may not.
   - The key: equal texts in the same minute give two rows, the second a held probable
     copy; a double run across a minute boundary, the same; two runs of equal texts at
     the same time (started together, before either op is in the outbox) give `n` 0 and
     1 and two rows, and neither op is refused as `duplicate_ingest`; a key whose op is
     still in the outbox counts as taken; equal texts on different days, two rows with no
     hold; the secret is not in any op; the secret is deleted on sign-out and on account
     deletion, and a secret found with no account data on first launch is replaced.
   - Paste: the pre-check finds a matching row and asks, also a mail row whose merchant
     differs from the text's, and a row with no card when the text names one; a pasted text
     with no date matches a row of the last 7 days and not an older one; a paste never files
     and never merges by itself; a pasted text that matches an unparsed text row (same bank and
     card, within ten minutes) offers to replace it, and on yes the unparsed row is
     archived (`txn_annotated`, `field: archived`) in the same edit, and the fold accepts
     that annotation with no anomaly; a pasted text with no date matches an unparsed text
     row of that bank from the last 7 days, and not one from 8 days ago.
   - The set-up test: a text whose normalized body is "hasala test", inside the 10-minute
     window, from a person's number, an unknown sender, a bank sender and with no sender,
     each marks the test as passed and authors no op, adds to no count and leaves no D6
     marker; the same text outside the window, and before any Test, is dropped with no
     trace and does not mark the test.
   - No text in an op: for every synthetic text in the reading-order fixtures and the D1,
     D10 and paste cases, each op that it authors is scanned after encoding, with every
     string value of its payload: none holds the whole body, any sentence or line of the
     body of 12 bytes or more that is not a field the row keeps (the amount, `merchant_raw`
     as read, the card digits, the date), or the sender. A text from a person's number or
     with no sender that no template reads keeps a merchant only from a card-purchase label,
     at most 4 words and 40 bytes; a transfer's "to" payee is not kept.
   - The transfer pair on texts: a synthetic DIB SMS debit text and a DIB SMS transfer
     notice for the same amount within 30 minutes give a second row with `needs_review:
     true` that names the first, in either order, also when the second would file under D1;
     31 minutes apart, or with other amounts, no hold; the fold's output for both rows is
     what today's decoder gives.
   - The unparsed text row: a payment-shaped bank text with no readable amount gives a
     row with `tier: none`, `unparsed: true`, `bank`, `last4`, `posted_at` (`time`),
     `received_at` and `channel: "sms"`, no amount, currency or direction, that today's
     decoder folds with no anomaly; its Review copy tells the person to paste the text.
   - What the phone keeps: a day's set-aside or ignored count older than 30 days is
     deleted; a set-aside count is kept for each kind; the Test window's open time is deleted when it closes.
   - D6: before the first unlock, nothing is stored but the marker; a template hit, and a
     payment-shaped text from a bank sender or with no sender, each add to the marker, and a
     payment-shaped text from a person's number, a promotion, a one-time code, a declined
     purchase and a text with no payment shape do not; no set-aside count is written then;
     after the unlock with the link copy saying not linked or unknown, the notice shows and
     the marker is removed; with it saying linked, no notice shows, the day's ignored count
     gains the marker's count, and the marker is removed.
   - The op: a v4 canary op of a text row in the canary log (`Replay/Snapshot.swift`) and
     a fold golden `conformance/swift/fold-v4-sms-*.json` that folds it on the current
     decoder, with the probable-copy hold and `duplicate_ingest` cases.

### Cut from v1

- The Live Activity guide for the set-up.
- The "gone quiet" alert for a bank that sends no texts for some days.
- The locked-phone inbox (see D6).
- The Wallet transaction trigger (D7).
- Apple's on-device model for texts. It reads only Latin script, and most DIB texts are
  Arabic. A text that no template reads is prefilled by the template-free readers only, and
  the on-device stage is not asked about a merchant that any text row carries.
- Learned layouts that persist across launches (see
  [Learned layouts](#reading-happens-inside-hasala-on-the-phone)).

## Ruled out

- **A shortcut that sends the text to hasalad, or forwarding to a Hasala address.** The
  server would see plaintext. Shortcuts cannot do Hasala's encryption on the device.
- **An SMS filter extension (`ILMessageFilterExtension`).** It is sandboxed and cannot share
  data with the app. Its only way out is a network request to our server, which is plaintext
  again.
- **Filter words for each bank.** See [One automation that looks for a full stop](#one-automation-that-looks-for-a-full-stop).
- **A catch-all automation with no sender and no phrase.** Shortcuts refuses it.
- **A source for each device.** The mailbox link is account-wide, so a choice on each device
  would let one iPhone read texts while another reads the mailbox, and every payment would
  arrive twice.

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Can a text file with no review? | **Decided (amended 2026-10-29, [filing-without-cards.md](filing-without-cards.md)):** yes, when the automation handed it, the account has no mailbox link, and an SMS template read it or the two template-free readers agree on its amount, currency and direction, each at 0.8 or more, with nothing else holding it (see [Filing with no review](#filing-with-no-review)). There is no sender check and no card check: a sender name can be faked, and a faked text costs one archive. A pasted text always goes to Review, because the person chose the text, not the bank. Apple's on-device model does not read texts in v1. |
| D2 | Can a person use Hasala with texts only, with no mailbox? | **Decided:** yes. Texts are an alternative to the mailbox, thus onboarding asks which one. |
| D3 | One channel, or merge mail and texts? | **Decided (2026-10-26):** one source for each person, for the whole account (see [One source for each person](#one-source-for-each-person)). No merge. |
| D4 | Which banks first? | **Decided:** DIB only, tonight. Other banks' payment texts go to Review. More banks follow as real texts reach `hasala-fixtures`. |
| D5 | Before or after the template-free readers ship in the app? | **Decided:** with them. Texts use templates first and the readers for Review. |
| D6 | What happens to a text before the first unlock after a restart? | **Decided:** no text and no field of it is stored, and there is no locked-phone inbox. The action still runs steps 1 to 4 of the reading order (the drop patterns, the templates and the payment shape), which need only bundled data. Only for a text that would be kept and that may be a bank's (a template hit, or a payment shape from a bank sender or with no sender), it writes a content-free marker (a count and the arrival minute of the latest) to a file with no data protection. Every text that the reading keeps then fails with "Hasala can't save bank texts until you unlock your iPhone. Paste this text later.", a payment-shaped text from a person's number too (it adds no marker, but the failure lets the person paste it), so that no payment is lost without a sign. A text that the reading order drops leaves no marker and succeeds silently. When the app next becomes active after the unlock, it reads the mailbox link copy. When it says not linked or unknown, the app shows a system alert, "Bank texts while locked", with "N texts that look like payments arrived while your iPhone was locked after a restart. Paste them from Messages." and the buttons **Paste a text** (Review's paste sheet) and **OK**; the marker is removed when the alert is answered. (Paper's C5 Home pill shows the cut inbox design.) When the copy says linked, the app shows no notice, adds N to the ignored count of the day of the marker's latest arrival minute (see [One source for each person](#one-source-for-each-person)), so an email account is never told to paste, and removes the marker. When the app opens signed out, it removes the marker and keeps the device facts (an expired session is not a sign-out by the person). Signed out, the action stores nothing: a kept text fails with "Sign in to Hasala to add bank texts." and a dropped text succeeds silently. An install whose fresh-install check has not completed counts as signed out; a Keychain that is locked before the first unlock counts as locked. When the account cannot open for a kept text, the action fails with "Hasala couldn't add this text. Open Hasala, then paste the text from Messages." The privacy policy and the support page use the same words: the marker counts texts that look like payments, which, with no sender, can include a person's text. This replaces the earlier proposal to keep raw text in an inbox until the next unlock. |
| D7 | Build the Wallet transaction trigger (Apple Pay) too? | **Decided:** not in v1. |
| D8 | Add to the 2026-10-11 decisions in CLAUDE.md? | **Decided:** yes. The "Transactions come from Gmail" line gains bank texts through the Shortcuts automation, read on the phone. |
| D9 | Which filter words catch every bank text? | **Decided (revised 2026-10-27):** a single full stop. Shortcuts needs a sender or a phrase, only about 5% of DIB payment texts contain "AED", and every DIB payment text in the owner's export contains "." in its amount. |
| D10 | When a mailbox is connected on an account that has text rows (a switch from texts to email, or a reconnect after a disconnect), what does email import? | **Decided:** all the mail that the connect lists, as for any connect; nothing is skipped by time, because a skip would lose payments that no text brought in. Every such connect runs the overlap check, whatever flow made it (as built, the check applies to every mail the engine authors). The overlap is the listed mail dated from the oldest text row in the account minus 24 hours to the newest plus 24 hours, from any device. A mail in the overlap that has a text twin (within 24 hours; same direction, or an unparsed text row; same bank or none on the text; same card or none on either side; same amount and currency, or different currencies, or an unparsed text row) waits in Review beside the twin and never files itself; the person keeps both or archives it. A mail in the overlap with no twin is authored as any mail. Thus a payment is not lost, and a mail that may repeat a text waits in Review; a payment whose mail and text differ more than the twin test allows can still show twice, and the person archives one (see [One source for each person](#one-source-for-each-person)). The switch alert says so. A switch from email to texts needs no rule: texts start from the switch. |
| D11 | What about texts that are not bank payments? | **Decided:** declined payments and one-time codes are dropped first, before the templates, so a declined purchase or a code for a purchase is never added, even when a purchase template would read it. Then a template hit is kept whatever the sender, a person's number included. Then a text that matches a notice pattern (card blocked or activated, registrations, promotions, service tickets) is dropped. A text with no template hit and no drop match that has a payment shape goes to Review, whatever the sender, and with no sender. From a bank sender, or with no sender, the shape is a payment word and any number; from a person's number or another sender, a payment word and an amount with a currency, or a masked card. Any other text is dropped. Every text dropped is dropped on the phone at once and never stored. A drop pattern is a whole-body pattern (DIB's wordings) or a marker; a marker drops a text only when it has no transaction clause, so a payment text with a code line or a promotion line that no template reads still reaches Review, and a kept text with a one-time-code or declined marker never files. A drop of a bank sender's text, by a pattern or for no payment shape, adds one to that day's count for its kind on the device (after the first unlock); a drop of any other text leaves no trace. The fixtures include each kind. |

## Open checks for the beta

Only real phones and real testers can answer these. Until each is checked, the app's copy
avoids the claim.

- Whether iOS gives the action the sender, or only the text. The support page's steps and
  the app's guide (`BankTextsGuide`) do not map **Sender** to Shortcut Input › Sender, so
  the action gets a sender only if Shortcuts binds the optional parameter by itself. The
  privacy policy and the support page say so: without a sender, no set-aside count is kept.
  Since 2026-10-29 filing does not depend on the sender. Without a sender, step 4 of the
  reading order uses the lenient shape (a
  payment word and any number) for every text, so a person's texts with a payment word and
  a number reach Review more often.
- Whether the automation runs, and the action can write, while the iPhone is locked (after
  the first unlock).
- Whether every UAE bank's payment texts contain a full stop (a decimal amount or a sentence
  end). A bank that does not would need its own phrase.
- Whether iOS shows a banner for each run. With an automation that runs on almost every
  text, a banner would show on each one. The owner's test showed none.
- Whether the action takes the message as its input by default, so the person does not set
  it by hand.
- Whether iOS lists the action before Hasala has been opened once.
- Whether the action can write the D6 marker before the first unlock, and whether Shortcuts
  shows the action's failure then.
- How often a person switches to email on one iPhone while another iPhone still adds texts
  before it syncs, so that a payment shows twice.
- Whether DIB texts both a transfer notice and a debit for one movement, as its mail does
  (see [The transfer pair on texts](#the-transfer-pair-on-texts)), and whether the 30-minute
  window covers the gap between the two texts.
- How often other banks' texts read well enough in Review to justify their templates.

## Legal pages

`docs/legal/privacy.md` says that the automation hands each incoming text to Hasala on the
iPhone, that Hasala keeps only texts that look like payments and drops every other text at once
without storing it, what the phone keeps about texts, that nothing is sent to our server or
anyone else, and how to stop it. `docs/legal/support.md` has the set-up and removal steps
and how to switch between texts and email. `docs/legal/security.md` covers texts beside
bank emails, with the D1 filing rule and its limit.

The pages describe bank texts as they ship, and a merge to `main` deploys hasala.app. Thus
the legal pages merge together with, or after, the last app PR for bank texts. That PR
(#231) is on `main`, so the pages, checked against the code on `main`, are ready to merge.
Do not cut a TestFlight build with bank texts before they merge. This record and the
CLAUDE.md line change nothing on hasala.app.
