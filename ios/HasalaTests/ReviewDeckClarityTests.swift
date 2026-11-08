import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Review: the deck says what each answer does")
struct ReviewDeckClarityTests {
  static func deck(at card: TxnID, _ state: LedgerState) -> (AppModel, ReviewViewModel) {
    let app = AppModel(store: InMemoryLedger(state: state))
    ReviewEntry.request(app, at: card)
    return (app, ReviewViewModel(app: app))
  }

  @Test func sortingACopyCardSaysItKeptBoth() throws {
    let (app, deck) = Self.deck(at: "starbucks-copy", Scenario.mayaCopy.state)
    #expect(deck.cards.first?.id == "starbucks-copy")
    #expect(deck.sort("starbucks-copy", into: "dining", alwaysUse: false, project: nil))
    let name = try #require(app.store.state.category("dining")?.name)
    #expect(app.toast?.title == "Kept both, sorted into \(name)")
  }

  @Test func sortingAnUnansweredRepeatSaysItKeptBoth() throws {
    let (app, deck) = Self.deck(at: "mail-twin", Scenario.mayaTexts.state)
    #expect(deck.repeatAnswers.asks(try #require(deck.cards.first)))
    #expect(deck.sort("mail-twin", into: "groceries", alwaysUse: false, project: nil))
    let name = try #require(app.store.state.category("groceries")?.name)
    #expect(app.toast?.title == "Kept both, sorted into \(name)")
  }

  @Test func aKeptRepeatStaysAnsweredWhenTheDeckOpensAgain() throws {
    let (app, deck) = Self.deck(at: "mail-twin", Scenario.mayaTexts.state)
    let card = try #require(deck.cards.first)
    deck.keepText(card.id)
    #expect(!deck.repeatAnswers.asks(card))
    ReviewEntry.request(app, at: card.id)
    let reopened = ReviewViewModel(app: app)
    #expect(reopened.cards.first?.id == card.id)
    #expect(!reopened.repeatAnswers.asks(card) && reopened.repeatAnswers.allowsUse(card))
  }

  @Test func keepBothOnTheTransactionPageAnswersTheCard() throws {
    let (app, deck) = Self.deck(at: "mail-twin", Scenario.mayaTexts.state)
    let card = try #require(deck.cards.first)
    #expect(deck.repeatAnswers.asks(card))
    app.router.transaction = [.reviewReason(.mayRepeat)]
    TransactionViewModel(app: app, id: card.id).resolve(.mayRepeat, merge: false)
    #expect(app.router.transaction.isEmpty)
    #expect(!deck.repeatAnswers.asks(card) && !deck.repeatAnswers.holdsPills(card) && deck.repeatAnswers.allowsUse(card))
  }

  @Test func sortingAPlainCardKeepsItsUsualToast() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2", Scenario.mayaBacklog.state)
    #expect(deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil))
    #expect(app.toast?.title.hasPrefix("Kept both") == false)
  }

  @Test func moneyInNamesIncome() {
    #expect(ReviewChoice.transfer.label(isIncome: true) == "Income or transfer")
    #expect(ReviewChoice.transfer.label(isIncome: false) == "Transfer")
    #expect(ReviewChoice.need.label(isIncome: true) == "Need")
    #expect(ReviewChoice.transfer.sheetTitle(isIncome: true) == "Money in · which one?")
    #expect(ReviewChoice.transfer.sheetTitle(isIncome: false) == "Transfer · which one?")
    #expect(ReviewChoice.want.sheetTitle(isIncome: false) == "Want · which one?")
  }

  @Test func theSuggestedChipNamesItsSource() {
    #expect(SuggestionSource.chip("Suggested by Cloudflare AI") == "Cloudflare AI")
    #expect(SuggestionSource.chip("Suggested on this iPhone") == "On this iPhone")
    #expect(SuggestionSource.chip(CategorySource.lastPickLabel) == "Your last pick")
    #expect(SuggestionSource.chip(nil) == "Suggested")
    #expect(SuggestionSource.chip("Suggested") == "Suggested")
    #expect(SuggestionSource.spoken("Groceries", nil) == "Groceries, suggested")
    #expect(SuggestionSource.spoken("Groceries", "Your last pick") == "Groceries, suggested, Your last pick")
  }

  @Test func theAlertSheetGivesOnePlainLineNotSteps() {
    #expect(ReviewReasonInfo.guidance(.mayRepeat) == "Not sure? Check your bank app.")
    #expect(ReviewReasonInfo.guidance(.probableCopy) == nil)
    #expect(ReviewReasonInfo.guidance(.samePurchase) == nil)
  }

  @Test func alwaysUseShowsHowFarItReachesAndDoneCountsIt() throws {
    let (_, deck) = Self.deck(at: "bl-alnoor-t-2", Scenario.mayaBacklog.state)
    let reach = deck.reach("bl-alnoor-t-2")
    #expect(reach > 0)
    #expect(ReviewDone.reachNote(reach) == "Also applies to \(reach) other transaction\(reach == 1 ? "" : "s"), in every month.")
    #expect(ReviewDone.reachNote(0) == nil)
    #expect(deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: true, project: nil))
    #expect(deck.reached > 0 && deck.reached <= reach)
    #expect(ReviewDone.reachLine(5) == "New rules also sorted 5 other transactions.")
    #expect(ReviewDone.reachLine(0) == nil)
  }

  @Test func skipsAreCountedAndTheEndSaysDoneForNow() throws {
    let (_, deck) = Self.deck(at: "bl-alnoor-t-2", Scenario.mayaBacklog.state)
    #expect(deck.skipped == 0)
    deck.skip("bl-alnoor-t-2")
    #expect(deck.skipped == 1)
    #expect(ReviewDone.title(skipped: 1) == "Done for now")
    #expect(ReviewDone.title(skipped: 0) == "All caught up")
    #expect(ReviewDone.skippedLine(2) == "2 skipped, back tomorrow")
    #expect(ReviewDone.skippedLine(0) == nil)
  }

  @Test func undoLastSortBringsTheCardBackAfterTheToastIsGone() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2", Scenario.mayaBacklog.state)
    #expect(!deck.canUndoLast)
    #expect(deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil))
    app.dismissToast()
    #expect(deck.canUndoLast)
    deck.undoLast()
    #expect(app.store.state.txn("bl-alnoor-t-2")?.inReview == true)
    #expect(!deck.canUndoLast)
    #expect(deck.sorted.isEmpty)
  }

  @Test func theCardFitsOrTheDeckScrolls() {
    let roomy = ReviewDeckView.deckOverhead + ReviewDeckView.cardHeight
    #expect(ReviewDeckView.fit(height: roomy, regular: 388, compact: 330, accessibility: false) == .regular)
    #expect(ReviewDeckView.fit(height: roomy, regular: 388, compact: 330, accessibility: true) == .scroll)
    let small = ReviewDeckView.deckOverhead + 291
    #expect(ReviewDeckView.fit(height: small, regular: 334, compact: 280, accessibility: false) == .compact)
    #expect(ReviewDeckView.fit(height: small, regular: 388, compact: 330, accessibility: false) == .scroll)
    #expect(ReviewDeckView.fit(height: roomy, regular: 470, compact: 420, accessibility: false) == .compact)
    #expect(ReviewDeckView.fit(height: roomy, regular: 520, compact: 470, accessibility: false) == .scroll)
    #expect(ReviewDeckView.fit(height: 0, regular: 0, compact: 0, accessibility: false) == .regular)
  }

  @Test func pillsWaitWhileADuplicateQuestionIsOpen() {
    #expect(ReviewDeckView.hidesPill(asking: true, leaning: false))
    #expect(!ReviewDeckView.hidesPill(asking: true, leaning: true))
    #expect(!ReviewDeckView.hidesPill(asking: false, leaning: false))
  }
}
