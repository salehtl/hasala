import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Deck while Cloudflare sorts in the background")
struct CloudSortDeckTests {
  static func file(_ app: AppModel, _ id: TxnID, _ category: CategoryID = "shopping") throws {
    _ = try app.store.apply(.categorize(id, category, learnRule: false, project: nil))
  }

  @Test func aCardFiledElsewhereIsSkippedWhenItsTurnComes() throws {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.map(\.id) == ["atm", "transfer-in", "apple", "lulu", "dubai-taxi", "steam"])
    try Self.file(app, "lulu", "groceries")
    #expect(deck.cards.first?.id == "atm" && deck.position == 1 && deck.total == 6)
    #expect(!deck.cards.contains { $0.id == "lulu" })
    deck.sort("atm", into: "transfer", alwaysUse: false, project: nil)
    deck.sort("transfer-in", into: "salary", alwaysUse: false, project: nil)
    #expect(deck.cards.first?.id == "apple" && deck.position == 3)
    deck.useSuggestion("apple")
    #expect(deck.cards.first?.id == "dubai-taxi" && deck.position == 5 && deck.total == 6)
    #expect(deck.filedAnnouncement("Want") == "Filed as Want. 5 of 6.")
  }

  @Test func theTopCardStaysUntilThePersonMovesOn() throws {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.first?.id == "atm")
    try Self.file(app, "atm", "transfer")
    #expect(deck.cards.first?.id == "atm" && deck.position == 1 && deck.cards.count == 6)
    deck.skip("atm")
    #expect(deck.cards.first?.id == "transfer-in" && deck.position == 2 && deck.cards.count == 5)
  }

  @Test func theTopCardStaysWhileItIsTouchedOrItsPickSheetIsUp() throws {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    deck.holding = "atm"
    try Self.file(app, "atm", "transfer")
    #expect(deck.cards.first?.id == "atm" && deck.position == 1)
    deck.holding = nil
    #expect(deck.cards.first?.id == "atm" && deck.position == 1)
    #expect(deck.sort("atm", into: "transfer", alwaysUse: false, project: nil))
    #expect(deck.cards.first?.id == "transfer-in" && deck.position == 2)

    deck.pick("transfer-in", .transfer)
    try Self.file(app, "transfer-in", "salary")
    #expect(deck.cards.first?.id == "transfer-in" && deck.position == 2)
    #expect(deck.sort("transfer-in", into: "freelance", alwaysUse: false, project: nil))
    #expect(app.store.state.txn("transfer-in")?.categoryID == "freelance")
    deck.picking = nil
    #expect(deck.cards.first?.id == "apple" && deck.position == 3)
  }

  @Test func aCardThatArrivesMidSessionWaitsForTheNextSession() throws {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    _ = try app.store.apply(.addTransaction(ManualEntryDraft(
      amount: .aed(12_50), merchant: "Corner Shop", categoryID: nil, postedAt: LocalDateTime(2026, 10, 9, 18, 0))))
    #expect(deck.total == 6 && deck.cards.count == 6)
    #expect(!deck.cards.contains { $0.merchant == "Corner Shop" })
    #expect(ReviewViewModel(app: app).cards.contains { $0.merchant == "Corner Shop" })
  }

  @Test func undoBringsTheCardBackToItsPlace() throws {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    deck.sort("atm", into: "transfer", alwaysUse: false, project: nil)
    #expect(deck.cards.first?.id == "transfer-in" && deck.position == 2)
    app.toastAction()
    #expect(deck.cards.first?.id == "atm" && deck.position == 1)
    try Self.file(app, "atm", "transfer")
    #expect(deck.cards.first?.id == "atm" && deck.position == 1)
    try Self.file(app, "transfer-in", "salary")
    #expect(deck.cards.map(\.id) == ["atm", "apple", "lulu", "dubai-taxi", "steam"])
  }

  @Test func aRunningCloudSortHoldsNothingBack() {
    let app = AppModel(store: InMemoryLedger())
    let first = ReviewViewModel(app: app).cards.map(\.id)
    app.cloudSort = MockCloudSortController(MockCloudSortController.sample(.running))
    #expect(ReviewViewModel(app: app).cards.map(\.id) == first)
  }
}

@MainActor
@Suite("Profile: sending Cloudflare's sorting back")
struct CloudSendBackTests {
  @Test func theCopy() {
    #expect(CloudSendBack.title(104) == "Send 104 payments back to Review?")
    #expect(CloudSendBack.title(1) == "Send 1 payment back to Review?")
    #expect(CloudSendBack.done(104) == "Sent 104 payments back to Review")
    #expect(CloudSendBack.done(1) == "Sent 1 payment back to Review")
    #expect(CloudSendBack.done(0) == "Nothing to send back")
  }

  @Test func theMockSendsEverythingBackOnce() async {
    let m = MockCloudSortController(MockCloudSortController.sample(.done))
    #expect(m.status.cloudSortedCount == 104)
    #expect(await m.sendAllBack() == 104)
    #expect(m.status.cloudSortedCount == 0 && m.sentBack == 1)
    #expect(await m.sendAllBack() == 0)
  }

  @Test func theMockTakesAPhaseFromItsLaunchArgument() {
    #expect(MockCloudSortController.fromLaunchArguments([]) == nil)
    #expect(MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "runCap"]) == nil)
    let running = MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "running"])
    #expect(running?.status.phase == .running)
    #expect(MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "done"])?.status.cloudSortedCount == 104)
  }
}
