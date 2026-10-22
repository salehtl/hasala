# The recovery phrase has no word check

**Status: decided by the owner, 2026-10-15** (v2 rebuild, requirement 3). Built in the iOS app
on branch `ios/v2-paper-rebuild` (Stage F2).

## Context

Signup ends with the 12-word recovery phrase. Until this change the app showed the words,
then asked the person to place four of them ("Check 4 of your words": four slots, eight word
chips, a wrong word marked until it was taken back). Only when the four were right did the
app publish the account's keys (`finishAccount` for a new account, `finishInterruptedSetup`
for the replacement phrase after an interrupted signup). The code's invariant was "nothing
is published before the four words are confirmed".

The Paper design for the rebuild (P2.2, "Recovery phrase") has no such step. Its section
note says "No word quiz.", its row holds four boards (Why it matters, Hidden until tapped,
Revealed, Saved), and the owner removed the step on the canvas. The words are still hidden
until tapped, the screen still says to write them on paper and check each word twice, and
the "Saved" screen says plainly that we can't see, reset or resend them.

## Decision

The phrase is published when the person has revealed the words and taps "I've written them
down". There is no step where the person types back, picks or confirms any word.

## The invariant now

**Nothing is published before the words were shown to the person.** In code:

- `SignupModel.phraseSeen` becomes true the first time `phraseRevealed` does, and only then.
  Hiding the words again ("Hide") keeps it true.
- Shown means drawn. While the screen is recorded or mirrored, the grid draws dots in
  place of the words, so a tap would show the person nothing: `PhraseShowView` reports the
  capture (`SignupModel.phraseMasked`), the words hide, the veil says "Your words stay
  hidden. Stop recording or mirroring your screen to see them." and can't be lifted, and
  the model refuses `phraseRevealed` while masked. Without the word check, nothing else
  would catch a reveal that drew only dots.
- `SignupModel.finish()` starts with `guard phraseSeen, let phrase, replacing || ticket != nil`.
  It is the only call site of `finishAccount` and `finishInterruptedSetup`.
- `PhraseShowView` in create mode keeps "I've written them down" disabled until the words
  were shown (Paper F6Q draws it so), and the model refuses it anyway.
- After publishing, the phrase and both typed passwords leave memory (`phrase = nil`), as
  before.

The privacy rules of the phrase screen do not change: hidden until tapped, hidden again when
the app leaves the foreground and when the screen goes, masked while the screen is
captured, a warning after a screenshot, no copy affordance, `.privacySensitive()`.

## What was removed

- `PhraseConfirmView` and its `FlowChips` and `WrapLayout`; the route `WelcomeRoute.phraseConfirm`.
- On `SignupModel`: `placedChips`, `placed`, `askedPositions`, `choices`, `SlotState`,
  `slotState`, `wrongSlot`, `confirmedCount`, `phraseConfirmed`, `isChipUsed`, `placeChip`,
  `place`, `takeBack`, `showWordsAgain`.
- `RecoveryPhrase.confirmPositions`, `PhraseRules.confirmChoices`, and the confirmation
  positions that `PhraseRules.generate()`, `LiveAccountService.makeRecoveryPhrase()` and
  `MockAccountService` made. HasalaCore's `Phrase.confirmationPositions` and its test stay
  untouched (HasalaCore is not part of the rebuild).
- The accessibility identifiers `phrase.slot.0` to `phrase.slot.3`, `chip.<word>`,
  `phrase.confirm` and `phrase.again`, and the copy "That isn't word N. Check your paper,
  then tap the word to take it back." and "N of 4 done.".
- The runbook step "Confirm the four words the app asks for." (`docs/runbooks/beta-review.md`).

The tests that drove the check now reveal the words and publish: `SignupFlowTests`
(including "`finish()` before the reveal publishes nothing"), the live account tests'
`signUp` helper, `JoinUITests`, `ReleaseSurfaceJoinTests` and `LiveE2ETests.test01_pathB`.

## Amendment: the 12 words after the first value (accepted, 2026-10-22)

**Status: accepted by the owner, 2026-10-22,** after a private security review. Built on
branch `onboarding/phrase-on-home` (draft PR, stacked on `onboarding/setup-to-home`). Paper:
page "X4 Exploration · Streamlined onboarding", "Proposal · Step 5".

### What changes

For a passkey signup whose registration returned PRF output and whose passkey is synced
(see "The sync check"), in a build that can show the words again
(`AccountCapabilities.viewPhrase`), signup no longer shows the words:

- After the passkey step, `SignupModel` publishes the account at once
  (`finishAccountWithoutWords`): the PRF wrap, the recovery wrap and the phrase box, as
  before, and `phrase_unseen: true` in the bootstrap body. Nothing else about the keys
  changes. Recovery Intro, Write these down and "Your account is ready" are skipped, and
  setup follows.
- The words are shown later, from Home: "Finish setting up" starts with the amber card
  "Write down your 12 words". It can't be dismissed. It opens the existing "View your 12
  words" path (`LiveAccountService.viewRecoveryPhrase`, step-up `phrase.view`, then
  `PhraseViewer` with all its rules: hidden until tapped, masked while the screen is
  captured, a screenshot warning, no copy). While the words are unseen, the viewer's
  heading asks for paper ("Write these down, in order"), as signup's screen did.
- The card goes after the first successful "View your 12 words", from Home or from
  Sign-in & security (see "When the words count as seen").
- If notifications are allowed, one local reminder fires 24 hours after signup while the
  words are still unseen. It carries no account data.
- While the words are unseen, the passkey whose PRF wrap is the account's only one can't
  be removed, and its wrap can't be deleted. The server refuses both with 409
  `phrase_unseen` (`DELETE /api/v1/auth/passkeys/{id}`, `DELETE /api/v1/keys/wraps`), so an
  older build or an iPhone whose cache is behind can't lose the words. The app also
  stops it first and says "Write down your 12 words first". Another passkey with its own
  PRF wrap, or a password, can still go. Removing a passkey is not in the beta build.
- If the passkey can't show the words while they are unseen (also on Home, when the
  account has no passkey on this iPhone), the words stay unseen and the card stays. The
  copy does not point to a paper copy that doesn't exist: it says the data still opens on
  this iPhone, to keep it, and to talk to us at hasala.app/support. Nothing is reported to
  the server.

Password signups, passkeys without PRF and passkeys that don't sync are unchanged: the
words stay in signup. The interrupted signup (`finishInterruptedSetup`) is also unchanged.

### The sync check

`AccountCreation.registerPasskey` reads the backup flags of the new passkey from the
authenticator data in its attestation object (BE, byte 32 bit 3; BS, bit 4;
`BackupFlags.fromAttestationObject`). Only a passkey that is backup eligible **and** backed
up skips the words. An attestation the app can't read counts as not synced. The server
checks the same flags it stored at registration (`webauthn_credentials.backup_eligible`,
`backup_state`) and refuses `phrase_unseen` (400) for a bootstrap that is not the creating
passkey's, has no PRF wrap, or whose passkey is not synced.

In the Debug mocks the passkey is synced; `-HasalaPasskeyNotSynced` makes it not synced
(as `-HasalaPasskeyNoPRF` takes away its PRF).

### The invariant now

- **For a password account, a passkey without PRF, a passkey that isn't synced, or a build
  without `viewPhrase`:** nothing is published before the words were shown (as above).
- **For a synced passkey account with PRF:** the account is published before the words
  were shown, and the server records "words not yet seen" until they are drawn for the
  person once. The words can be shown again because the phrase box is published at signup
  and the passkey's PRF wrap opens it.

### The server flag

Migration `00028_phrase_seen` adds `account_keys.phrase_seen_at` (a nullable timestamp; no
words and no secret). Accounts created before it count as seen (`phrase_seen_at =
created_at`). A bootstrap or a password signup sets it to the creation time, except a
bootstrap with `phrase_unseen`, which leaves it empty.

- `GET /api/v1/account` reports `phrase_unseen_since` (the keys' creation time while the
  flag is empty, else null).
- `POST /api/v1/keys/phrase/view` sets it, in the same transaction that releases the
  phrase box, records `phrase_viewed` and queues its security email, the first time it
  succeeds. A later view changes nothing. There is no other way to set it: no endpoint
  takes a "seen" report.
- On the app, `StoredUnseenPhrase` is a cache of the server value. When the runtime reads
  `GET /account` (at each launch, after a sign-in, and after the security wake that every
  view sends to the other iPhones), the server value wins. So the card and the reminder
  come back after a sign-out, a session the server ended, a reinstall or on another
  iPhone, and go everywhere after the first view.
- An older server answers 400 to `phrase_unseen` (it does not know the field). The app
  then shows the words in signup for that signup, with the same passkey, ticket and keys,
  and publishes without the field. Deploy the server first anyway.

### When the words count as seen

Decided 2026-10-22: **the server marks the words seen on the first successful view.** The
view needs a fresh passkey step-up (Face ID) and emails the holder, so it is already a
deliberate act that the holder hears about. The app's own cache drops the card only after
the grid was drawn (a reveal while the screen is captured does not count), so on this
iPhone the card stays until the person saw the words or the next `GET /account`.

The consequence: a view that was opened but closed before the words were drawn counts as
seen on the server, and the card goes at the next account read. The words are not lost:
they can be shown again from Sign-in & security at any time while the passkey works. The
other choice (a separate "seen" report from the app after the grid was drawn) needed an
endpoint that only a session protects, with no step-up and no email, and an offline queue
for the report. A leaked session could have cleared the reminder on every iPhone. That is
worse than a card that goes after a view the person chose not to finish.

A restore must not show the card again to someone who already wrote the words down. The
first view is recorded in the restore ledger (kind `phrase-seen`: the account id and the
time only), and `hasala-purge-replay` sets the flag again (only when it is still empty and
the keys existed by then). A `hasalad` from before this kind skips the line with a log
line, if it is a build that skips unknown kinds; an older one fails (see the restore
runbook).

### The window of exposure

Until the words are written down, the passkey is the only way to open the data on a new
device. If the person loses the passkey (iCloud Keychain off, Apple Account lost) before
writing the words, the data can't be opened anywhere else. This iPhone still opens it while
its keys are here. In the first days most of the data can be read again from the mailbox
(the import window), except manual edits, rules and the plan.

The words themselves are behind the same passkey. The account keys leave this iPhone's
memory at signup; this iPhone keeps only the keys that read and write the data. The phrase
box opens only with the key that the passkey's PRF wrap gives back. Thus:

- If the passkey is lost or deleted before the words were drawn, the words are lost too,
  also on this iPhone. This iPhone still reads the data, but no other iPhone can open it,
  ever.
- Nothing checks at signup that the passkey's PRF output at sign-in opens the wrap made
  with its output at creation (device spike V15 is open). If it does not, "View your 12
  words" fails and the words can't be shown at all. Before this flow, the words on paper
  were the fallback for exactly this failure. **The owner accepted this risk on
  2026-10-22:** the owner and every beta tester sign in with passkeys, and those passkeys
  work. There is no round-trip PRF check at signup.
- The sync flags come from the passkey provider. A provider that reports a passkey as
  synced when it is not would skip the words for a passkey that lives on one iPhone.

What limits the window: the card is first on Home, on every iPhone of the account, and
can't be dismissed; the reminder after 24 hours; the words can be shown from Profile while
the passkey works.

Not decided, for the owner: whether the card becomes blocking after N days or before the
first manual edit or rule, and whether the first view should skip the "you viewed your
words" security email (it still sends today: `phrase_viewed`; changing it needs a server
rule).
