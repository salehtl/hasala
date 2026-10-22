import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Cloud sort card")
struct CloudSortCardTests {
  typealias S = CloudSortCardState
  static let utc = TimeZone(identifier: "UTC")!

  static func status(_ phase: CloudSortStatus.Phase, _ change: (inout CloudSortStatus) -> Void = { _ in }) -> CloudSortStatus {
    var s = MockCloudSortController.sample(phase)
    change(&s)
    return s
  }

  @Test func thePhaseDecidesTheCard() {
    #expect(S.of(Self.status(.off), dismissedRun: nil) == nil)
    #expect(S.of(Self.status(.idle), dismissedRun: nil) == .ready)
    #expect(S.of(Self.status(.idle) { $0.waitingNames = 4 }, dismissedRun: nil) == nil)
    #expect(S.of(Self.status(.idle) { $0.waitingNames = 5 }, dismissedRun: nil) == .ready)
    #expect(S.of(Self.status(.idle) { $0.remainingToday = 0; $0.nextRunNames = 0 }, dismissedRun: nil) == .paused(.dayCap))
    #expect(S.of(Self.status(.running), dismissedRun: nil) == .running)
    for pause: CloudSortStatus.Pause in [.offline, .background, .busy(untilMs: 1), .rateLimited(untilMs: 2), .runCap, .dayCap] {
      #expect(S.of(Self.status(.paused(pause)), dismissedRun: nil) == .paused(pause))
    }
  }

  @Test func theDoneCardStaysUntilItsRunIsDismissed() {
    let done = Self.status(.done) { $0.lastRunEndedMs = 1_000 }
    #expect(S.of(done, dismissedRun: nil) == .done)
    #expect(S.of(done, dismissedRun: 999) == .done)
    #expect(S.of(done, dismissedRun: 1_000) == nil)
    let more = Self.status(.done) {
      $0.lastRunEndedMs = 1_000
      $0.waitingNames = 12
      $0.remainingToday = 100
      $0.nextRunNames = 12
    }
    #expect(S.of(more, dismissedRun: 1_000) == .ready)
    #expect(S.done.offersCheckSuggestions && !S.ready.offersCheckSuggestions && !S.running.offersCheckSuggestions)
  }

  @Test func theTimeLeftIsTheNamesLeftAt24AMinuteRoundedUp() {
    func eta(_ asked: Int, of total: Int) -> Int {
      S.minutesLeft(Self.status(.running) {
        $0.askedNames = asked
        $0.totalNames = total
      })
    }
    #expect(eta(83, of: 147) == 3)
    #expect(eta(0, of: 24) == 1)
    #expect(eta(0, of: 25) == 2)
    #expect(eta(147, of: 147) == 1)
    #expect(eta(0, of: 250) == 11)
    #expect(S.eta(Self.status(.running)) == "About 3 minutes. Keep Hasala open.")
    #expect(S.eta(Self.status(.running) { $0.askedNames = 140 }) == "About a minute. Keep Hasala open.")
  }

  @Test func theCopy() {
    let ready = Self.status(.idle)
    #expect(S.readyLead(ready).hasPrefix("147 merchants in Review aren't on Hasala's list. Cloudflare's AI can sort"))
    #expect(S.startLabel(ready) == "Sort 147 merchants")
    #expect(S.progressLine(Self.status(.running)) == "83 of 147 merchants · 41 payments sorted so far")
    #expect(S.doneLine(Self.status(.done)) == "104 payments sorted, 33 suggestions to check, 25 for you to sort.")
    let at1840: Int64 = 1_792_003_200_000
    #expect(S.clock(at1840, timeZone: Self.utc) == "18:40")
    #expect(S.pauseLine(.busy(untilMs: at1840), status: ready, timeZone: Self.utc)
      == "Cloudflare's AI is busy. Hasala will try again at 18:40.")
    #expect(S.pauseLine(.offline, status: ready) == "Paused. No internet connection. It continues when you're back online.")
    let cap = Self.status(.paused(.runCap))
    #expect(S.pauseLine(.runCap, status: cap) == "Paused after 250 merchants, today's limit for one run.")
    #expect(S.nextLabel(cap) == "Sort the next 147")
    #expect(S.pauseLine(.dayCap, status: cap) == "That's today's limit on this iPhone. You can sort the rest tomorrow.")
    #expect(S.sendBackTitle(104) == "Send 104 payments back to Review?")
    #expect(S.sendBackTitle(1) == "Send 1 payment back to Review?")
    #expect(S.sentBack(104) == "Sent 104 payments back to Review")
    #expect(S.sentBack(0) == "Nothing to send back")
  }

  @Test func theMockStartsAndStopsARun() {
    let m = MockCloudSortController(MockCloudSortController.sample(.idle))
    m.start()
    #expect(m.status.phase == .running && m.status.totalNames == 147 && m.starts == 1)
    m.stop()
    #expect(m.status.phase == .done && m.status.canUndoLastRun)
  }
}

@MainActor
@Suite("Deck while a run sorts")
struct CloudSortDeckTests {
  static func card(_ id: String) -> ReviewCardModel? {
    ReviewEngine.cards(Scenario.maya.state).first { $0.id == id }
  }

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
@Suite("Profile cloud sort")
struct CloudSortOfferTests {
  typealias S = CloudSortCardTests

  @Test func theOfferNeedsFiveNamesAndNoRun() {
    #expect(CloudSortOffer.shouldOffer(S.status(.idle)))
    #expect(!CloudSortOffer.shouldOffer(S.status(.idle) { $0.waitingNames = 4 }))
    #expect(!CloudSortOffer.shouldOffer(S.status(.idle) { $0.nextRunNames = 0 }))
    #expect(!CloudSortOffer.shouldOffer(S.status(.off) { $0.waitingNames = 40; $0.nextRunNames = 40 }))
    #expect(!CloudSortOffer.shouldOffer(S.status(.running)))
    #expect(!CloudSortOffer.shouldOffer(S.status(.paused(.runCap))))
    #expect(CloudSortOffer.shouldOffer(S.status(.done) { $0.waitingNames = 9; $0.nextRunNames = 9 }))
    #expect(CloudSortOffer.title(S.status(.idle)) == "Sort the 162 payments waiting in Review?")
    #expect(CloudSortOffer.message(S.status(.idle))
      == "Hasala can ask about the 147 merchant names now, a few at a time, while the app is open.")
  }

  @Test func theLastSortReadout() {
    let ended: Int64 = 1_792_002_120_000
    let done = S.status(.done) { $0.lastRunEndedMs = ended }
    #expect(CloudSortOffer.lastSort(done, nowMs: ended + 60_000, timeZone: S.utc)
      == "Last sort, today 18:22: asked about 147 merchants, sorted 104 payments, 33 suggestions. 18 payments are transfers or account alerts, which stay on this iPhone.")
    let one = S.status(.done) {
      $0.lastRunEndedMs = ended
      $0.staysOnDevice = 1
    }
    #expect(CloudSortOffer.lastSort(one, nowMs: ended + 86_400_000, timeZone: S.utc)?
      .hasSuffix("yesterday 18:22: asked about 147 merchants, sorted 104 payments, 33 suggestions. 1 payment is a transfer or account alert, which stays on this iPhone.") == true)
    let none = S.status(.done) {
      $0.lastRunEndedMs = ended
      $0.staysOnDevice = 0
    }
    #expect(CloudSortOffer.lastSort(none, nowMs: ended + 3 * 86_400_000, timeZone: S.utc)?.hasSuffix("33 suggestions.") == true)
    #expect(CloudSortOffer.lastSort(S.status(.idle), nowMs: ended) == nil)
  }
}
