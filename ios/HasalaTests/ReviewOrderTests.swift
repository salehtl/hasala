import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Review order")
struct ReviewOrderTests {
  static let oldest: [TxnID] = ["atm", "transfer-in", "apple", "lulu", "dubai-taxi", "steam"]

  @Test func theListAndTheDeckRunNewestFirstByDefault() {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.reviewOrder == .newestFirst)
    #expect(app.reviewCards.map(\.id) == Self.oldest.reversed())
    #expect(ReviewViewModel(app: app).cards.map(\.id) == Self.oldest.reversed())
  }

  @Test func oldestFirstTurnsTheListAndTheDeckAround() {
    let app = AppModel(store: InMemoryLedger())
    let revision = app.store.revision
    app.reviewOrder = .oldestFirst
    #expect(app.store.revision == revision)
    #expect(app.reviewCards.map(\.id) == Self.oldest)
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.map(\.id) == Self.oldest)
    #expect(deck.position == 1 && deck.total == 6)
    app.reviewOrder = .newestFirst
    #expect(app.reviewCards.map(\.id) == Self.oldest.reversed())
  }

  @Test func aRowStartsTheDeckAtItsCardAndReadsOnInTheChosenOrder() {
    let app = AppModel(store: InMemoryLedger())
    ReviewEntry.open(app, at: "lulu")
    #expect(ReviewViewModel(app: app).cards.map(\.id) == ["lulu", "apple", "transfer-in", "atm", "steam", "dubai-taxi"])
    app.reviewOrder = .oldestFirst
    ReviewEntry.open(app, at: "lulu")
    #expect(ReviewViewModel(app: app).cards.map(\.id) == ["lulu", "dubai-taxi", "steam", "atm", "transfer-in", "apple"])
  }

  @Test func theChoiceStaysOnThisIPhoneAcrossLaunches() throws {
    let suite = "test.review.order.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = AppModel(store: InMemoryLedger(), reviewOrderDefaults: defaults)
    #expect(first.reviewOrder == .newestFirst)
    first.reviewOrder = .oldestFirst
    #expect(defaults.string(forKey: ReviewOrderSetting.key) == "oldest")
    let again = AppModel(store: InMemoryLedger(), reviewOrderDefaults: defaults)
    #expect(again.reviewOrder == .oldestFirst)
    #expect(again.reviewCards.first?.id == "atm")
    defaults.set("sideways", forKey: ReviewOrderSetting.key)
    #expect(AppModel(store: InMemoryLedger(), reviewOrderDefaults: defaults).reviewOrder == .newestFirst)
  }

  @Test func withoutDefaultsNothingIsStored() {
    let app = AppModel(store: InMemoryLedger())
    app.reviewOrder = .oldestFirst
    #expect(ReviewOrderSetting.load(nil) == .newestFirst)
  }
}
