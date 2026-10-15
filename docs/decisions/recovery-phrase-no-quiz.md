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
