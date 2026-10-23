import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Deck while Cloudflare sorts")
struct CloudSortDeckTests {
  @Test func waitingRowsGoLastInTheirOrder() {
    let cards = ReviewEngine.cards(Scenario.maya.state)
    #expect(cards.count >= 3)
    let ids = cards.map(\.id)
    let held = ReviewViewModel.holdingBack(cards, waiting: [ids[0], ids[1]]).map(\.id)
    #expect(held == Array(ids.dropFirst(2)) + [ids[0], ids[1]])
    #expect(ReviewViewModel.holdingBack(cards, waiting: []).map(\.id) == ids)
  }

  @Test func theDeckHoldsBackRowsWhileARunIsActive() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.maya.state))
    let first = ReviewViewModel(app: app).cards.map(\.id)
    let sort = MockCloudSortController(MockCloudSortController.sample(.running))
    sort.status.pendingTxnIDs = [first[0], "not-in-review"]
    app.cloudSort = sort
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.map(\.id) == Array(first.dropFirst()) + [first[0]])
    #expect(deck.waitingForCloud == 1)
    #expect(deck.total == first.count)
    sort.status.phase = .paused(.offline)
    #expect(deck.cards.last?.id == first[0])
    sort.status.phase = .done
    #expect(deck.cards.map(\.id) == first && deck.waitingForCloud == 0)
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
    #expect(running?.status.phase == .running && running?.status.pendingTxnIDs == ["apple", "steam"])
    #expect(MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "done"])?.status.cloudSortedCount == 104)
  }
}
