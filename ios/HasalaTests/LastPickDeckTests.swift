import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Deck: your last pick comes first")
struct LastPickDeckTests {
  static func deck(at card: TxnID, _ state: LedgerState = Scenario.mayaBacklog.state) -> (AppModel, ReviewViewModel) {
    let app = AppModel(store: InMemoryLedger(state: state))
    ReviewEntry.request(app, at: card)
    return (app, ReviewViewModel(app: app))
  }

  @Test func theNextCardIsTheSameMerchantAndUseFilesTheStripsCategory() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    #expect(deck.cards.first?.id == "bl-alnoor-t-2" && deck.position == 1)
    #expect(deck.cards.first?.suggestion == nil)
    let dateOrder = deck.cards.map(\.id)
    #expect(dateOrder.firstIndex(of: "bl-alnoor-t-3")! > 2)
    #expect(deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil))
    let top = try #require(deck.cards.first)
    #expect(top.id == "bl-alnoor-t-3" && deck.position == 2)
    #expect(top.suggestion?.id == "groceries" && top.suggestedBy == "Your last pick")
    #expect(deck.options(for: .need, card: top.id).first?.id == "groceries")
    #expect(deck.useSuggestion(top.id))
    let filed = try #require(app.store.state.txn("bl-alnoor-t-3"))
    #expect(filed.categoryID == top.suggestion?.id && filed.categorySource == .user && !filed.inReview)
    #expect(deck.position == 3)
    #expect(deck.cards.map(\.id) == dateOrder.filter { $0 != "bl-alnoor-t-2" && $0 != "bl-alnoor-t-3" })
  }

  @Test func useOnAnAISuggestionFilesItAndTheNextCardOfTheMerchantShowsItAsYourPick() throws {
    let (app, deck) = Self.deck(at: "bl-mirdif-1")
    let first = try #require(deck.cards.first)
    #expect(first.suggestedBy == "Suggested by Cloudflare AI" && first.suggestion?.id == MayaBacklog.wrongGuess)
    #expect(deck.useSuggestion(first.id))
    #expect(app.store.state.txn("bl-mirdif-1")?.categoryID == MayaBacklog.wrongGuess)
    let next = try #require(deck.cards.first)
    #expect(next.id == "bl-mirdif-2")
    #expect(next.suggestion?.id == MayaBacklog.wrongGuess && next.suggestedBy == "Your last pick")
  }

  @Test func useFilesNothingWhenThePickChangedAfterTheCardShowedIt() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    #expect(deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil))
    let shown = try #require(deck.cards.first)
    #expect(shown.id == "bl-alnoor-t-3" && shown.suggestion?.id == "groceries")
    _ = try app.store.apply(.categorize("bl-alnoor-t-2", "shopping", learnRule: false, project: nil))
    #expect(!deck.useSuggestion(shown.id, shown: "groceries"))
    #expect(app.store.state.txn("bl-alnoor-t-3")?.inReview == true)
    let now = try #require(deck.cards.first)
    #expect(now.id == "bl-alnoor-t-3" && now.suggestion?.id == "shopping")
    #expect(deck.useSuggestion(now.id, shown: "shopping"))
    #expect(app.store.state.txn("bl-alnoor-t-3")?.categoryID == "shopping")
  }

  @Test func aRejectionNeverHidesThePersonsPick() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:al noor trading" {
      s.txns[i].rejectedCategories = ["groceries"]
    }
    let (_, deck) = Self.deck(at: "bl-alnoor-t-2", s)
    deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil)
    #expect(deck.cards.first?.suggestion?.id == "groceries" && deck.cards.first?.suggestedBy == "Your last pick")
  }

  @Test func withNoOtherPaymentOfTheMerchantDateOrderResumes() throws {
    let (_, deck) = Self.deck(at: "bl-saffron")
    let order = deck.cards.map(\.id)
    deck.sort("bl-saffron", into: "shopping", alwaysUse: false, project: nil)
    #expect(deck.cards.map(\.id) == Array(order.dropFirst()))
  }

  @Test func aPaymentOfTheMerchantSortedElsewhereIsNotPulledForward() throws {
    let (app, deck) = Self.deck(at: "bl-alnoor-t-2")
    _ = try app.store.apply(.categorize("bl-alnoor-t-3", "shopping", learnRule: false, project: nil))
    let order = deck.cards.map(\.id)
    deck.sort("bl-alnoor-t-2", into: "groceries", alwaysUse: false, project: nil)
    #expect(deck.cards.map(\.id) == Array(order.dropFirst()))
    #expect(!deck.cards.contains { $0.id == "bl-alnoor-t-3" })
  }

  @Test func followingKeepsTheRestInOrder() {
    let ref = MerchantGroupRef(key: "n:a", direction: .out)
    func t(_ id: TxnID, _ group: String?, _ direction: Direction = .out) -> Txn {
      Txn(id: id, merchant: id, amount: .aed(1_00), direction: direction, postedAt: LocalDateTime(2026, 10, 1, 9, 0), needsReview: true,
          merchantGroup: group)
    }
    let waiting = [t("x", "n:b"), t("a2", "n:a"), t("y", nil), t("a3", "n:a"), t("a4", "n:a", .in)]
    let order = ["a1", "x", "a2", "y", "a3", "a4"]
    #expect(ReviewViewModel.following(order, after: "a1", ref: ref, waiting: waiting) == ["a1", "a2", "a3", "x", "y", "a4"])
    #expect(ReviewViewModel.following(order, after: "x", ref: MerchantGroupRef(key: "n:b", direction: .out), waiting: waiting) == order)
    #expect(ReviewViewModel.following(order, after: "a3", ref: ref, waiting: waiting) == order)
    #expect(ReviewViewModel.following(order, after: "gone", ref: ref, waiting: waiting) == order)
  }

  @Test func theCategoryPageStartsOnTheSuggestionOfAPaymentThatWaits() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaBacklog.state))
    let guessed = try #require(TransactionEngine.detail("bl-bright-9", app.store.state, now: app.store.now))
    #expect(CategoryPickerView.initial(guessed) == MayaBacklog.wrongGuess)
    _ = try app.store.apply(.categorize("bl-bright-10", "healthcare", learnRule: false, project: nil))
    let waiting = try #require(TransactionEngine.detail("bl-bright-9", app.store.state, now: app.store.now))
    #expect(waiting.category?.id == MayaBacklog.wrongGuess && waiting.suggestion?.id == "healthcare")
    #expect(CategoryPickerView.initial(waiting) == "healthcare")
    let sorted = try #require(TransactionEngine.detail("bl-bright-10", app.store.state, now: app.store.now))
    #expect(sorted.suggestion == nil && CategoryPickerView.initial(sorted) == "healthcare")
    let open = try #require(TransactionEngine.detail("bl-alnoor-t-2", app.store.state, now: app.store.now))
    #expect(open.category == nil && open.suggestion == nil && CategoryPickerView.initial(open) == nil)
  }
}
