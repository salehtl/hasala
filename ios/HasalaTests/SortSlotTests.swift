import CoreMailbox
import CoreSync
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Review tab: the sorting card slot")
struct SortSlotTests {
  typealias F = SortSlot.Facts

  static func status(_ phase: CloudSortStatus.Phase, _ change: (inout CloudSortStatus) -> Void = { _ in }) -> CloudSortStatus {
    var s = MockCloudSortController.sample(phase)
    change(&s)
    return s
  }

  static let reading = MailImport(state: .reading, read: 312, total: 900)

  @Test func nothingToShowLeavesTheSlotEmpty() {
    #expect(SortSlot.of(F()) == nil)
    #expect(SortSlot.of(F(status: Self.status(.off))) == nil)
    #expect(SortSlot.of(F(status: Self.status(.idle) { $0.offerDue = false })) == nil)
    #expect(SortSlot.of(F(importing: MailImport(state: .stopped("Reading stopped"), read: 4, total: 9))) == nil)
  }

  @Test func theConsentAskComesFirstAndOnlyWhileSuggestionsAreOff() {
    #expect(SortSlot.of(F(asks: true)) == .ask)
    #expect(SortSlot.of(F(asks: true, status: Self.status(.off), importing: Self.reading)) == .ask)
    #expect(SortSlot.of(F(asks: true, status: Self.status(.running))) == .run(.running))
    #expect(SortSlot.of(F(asks: false, status: Self.status(.off), importing: Self.reading)) == .importing(Self.reading))
  }

  @Test func withSuggestionsOffNothingOffersARun() {
    let off = Self.status(.off) { $0.waitingNames = 40; $0.nextRunNames = 40; $0.remainingToday = 400 }
    #expect(SortSlot.of(F(status: off)) == nil)
    var due = off
    due.offerDue = true
    #expect(SortSlot.of(F(status: due)) == nil)
  }

  @Test func aRunShowsOverTheResultTheOfferAndTheImport() {
    #expect(SortSlot.of(F(status: Self.status(.running), importing: Self.reading)) == .run(.running))
    let paused = Self.status(.paused(.busy(untilMs: 5)))
    #expect(SortSlot.of(F(status: paused, importing: Self.reading)) == .run(.paused(.busy(untilMs: 5))))
    #expect(SortSlot.of(F(status: Self.status(.paused(.runCap)))) == .run(.paused(.runCap)))
  }

  @Test func theResultStaysUntilItsRunIsDismissed() {
    let done = Self.status(.done) { $0.lastRunEndedMs = 1_000 }
    #expect(SortSlot.of(F(status: done)) == .result)
    #expect(SortSlot.of(F(status: done, dismissedRun: 999, importing: Self.reading)) == .result)
    #expect(SortSlot.of(F(status: done, dismissedRun: 1_000)) == nil)
    #expect(SortSlot.of(F(status: done, dismissedRun: 1_000, importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.result.card == .done)
  }

  @Test func theOfferShowsOnlyWhenItIsDue() {
    let idle = Self.status(.idle)
    #expect(idle.offerDue)
    #expect(SortSlot.of(F(status: idle)) == .offer(.ready))
    #expect(SortSlot.of(F(status: idle)).map(\.isOffer) == true)
    let capped = Self.status(.idle) { $0.remainingToday = 0; $0.nextRunNames = 0 }
    #expect(SortSlot.of(F(status: capped)) == .offer(.paused(.dayCap)))
    #expect(SortSlot.of(F(status: capped))?.isOffer == false)
    let after = Self.status(.done) {
      $0.lastRunEndedMs = 7
      $0.waitingNames = 30
      $0.nextRunNames = 30
      $0.remainingToday = 300
    }
    #expect(SortSlot.of(F(status: after, dismissedRun: 7)) == nil)
    var returning = after
    returning.offerDue = true
    #expect(SortSlot.of(F(status: returning, dismissedRun: 7)) == .offer(.ready))
    #expect(SortSlot.of(F(status: Self.status(.idle) { $0.waitingNames = 4 })) == nil)
  }

  @Test func theImportShowsWhenNoCardIsDue() {
    #expect(SortSlot.of(F(importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.of(F(status: Self.status(.idle) { $0.offerDue = false }, importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.importing(Self.reading).card == nil && SortSlot.ask.card == nil)
  }

  @Test func theImportCopy() {
    #expect(SortSlot.importingTitle(Self.reading) == "Reading your mail · 312 so far")
    #expect(SortSlot.importingTitle(MailImport(state: .reading, read: 0, total: 0)) == "Reading your mail")
    #expect(SortSlot.importingLine(Self.reading) == "You can start on the ones here now. More arrive as Hasala reads.")
    #expect(SortSlot.importingSpoken(Self.reading)
      == "Reading your mail, 312 so far. You can start on the ones here now. More arrive as Hasala reads.")
    #expect(SortSlot.importingLine(MailImport(state: .offline, read: 3, total: 9)).hasPrefix("Paused. No internet connection."))
    #expect(SortSlot.importingLine(MailImport(state: .paused, read: 3, total: 9)) == "Paused for now. Hasala tries again soon.")
  }
}

@Suite("Review tab: when the run offer is due")
struct RunOfferTests {
  typealias O = RunOffer
  typealias M = RunOffer.Memory

  static func facts(
    _ mailbox: RunOffer.Mailbox = .active, caughtUp: Bool = true, waiting: Int = 40, enabled: Bool = true,
    running: Bool = false, started: Int64? = nil
  ) -> RunOffer.Facts {
    RunOffer.Facts(
      enabled: enabled, load: RunOffer.Load(mailbox: mailbox, caughtUp: caughtUp), waitingNames: waiting,
      runActive: running, runStartedMs: started)
  }

  static func step(_ m: M, _ f: RunOffer.Facts) -> (M, Bool) {
    let next = O.observe(m, f)
    return (next, O.due(next, f))
  }

  @Test func theFirstOfferWaitsForAnActiveMailboxAndACaughtUpSync() {
    let m = M()
    #expect(!O.due(m, Self.facts(.importing)))
    #expect(!O.due(m, Self.facts(.active, caughtUp: false)))
    #expect(O.due(m, Self.facts(.active)))
    #expect(!O.due(m, Self.facts(.active, waiting: 0)))
    #expect(!O.due(m, Self.facts(.active, waiting: CloudSortCardState.minimumNames - 1)))
    #expect(!O.due(m, Self.facts(.active, enabled: false)))
    #expect(!O.due(m, Self.facts(.active, running: true)))
  }

  @Test func anotherIPhonesMailboxCountsOnceThisOneIsCaughtUp() {
    #expect(!O.due(M(), Self.facts(.elsewhere, caughtUp: false)))
    #expect(O.due(M(), Self.facts(.elsewhere)))
  }

  @Test func aMailboxStuckWaitingForCardsOffersOnTheSecondReviewOpen() {
    let f = Self.facts(.awaitingCards)
    var m = O.observe(M(), f)
    #expect(!O.due(m, f))
    m = O.opened(m, f)
    #expect(!O.due(m, f))
    m = O.opened(m, f)
    #expect(O.due(m, f))
    #expect(!O.due(m, Self.facts(.awaitingCards, caughtUp: false)))
    let resumed = O.observe(m, Self.facts(.importing))
    #expect(resumed.opens == 0)
    #expect(!O.due(resumed, Self.facts(.awaitingCards)))
  }

  @Test func opensWhileReadingOrActiveDoNotCount() {
    var m = M()
    for _ in 0..<3 { m = O.opened(m, Self.facts(.importing)) }
    #expect(m.opens == 0)
    for _ in 0..<3 { m = O.opened(m, Self.facts(.active, caughtUp: false)) }
    #expect(m.opens == 0)
  }

  @Test func withNoMailboxTheOfferNeedsWaitingRowsAndTwoOpens() {
    var m = M()
    let empty = Self.facts(.none, waiting: 0)
    m = O.opened(O.opened(m, empty), empty)
    #expect(!O.due(m, empty))
    let rows = Self.facts(.none, waiting: 12)
    #expect(O.due(m, rows))
    #expect(!O.due(O.opened(M(), rows), rows))
    #expect(!O.due(m, Self.facts(.none, caughtUp: false, waiting: 12)))
  }

  @Test func theOfferIsStoredOnlyOnceShownAndStaysUntilARunStarts() {
    let f = Self.facts(.active)
    var m = O.observe(M(), f)
    #expect(m.stage == .firstLoad)
    m = O.shown(m, f)
    #expect(m.stage == .open)
    #expect(O.due(m, f))
    #expect(O.due(m, Self.facts(.active, waiting: 6)))
    #expect(!O.due(m, Self.facts(.active, waiting: 4)))
    #expect(!O.due(m, Self.facts(.importing)))
    let notDue = O.shown(M(), Self.facts(.importing))
    #expect(notDue.stage == .firstLoad)
    m = O.observe(m, Self.facts(.active, waiting: 40, running: true, started: 500))
    #expect(m.stage == .spent && m.low == 40 && m.lastRunMs == 500)
    var (after, due) = Self.step(m, Self.facts(.active, waiting: 2, started: 500))
    #expect(!due && after.low == 2)
    (after, due) = Self.step(after, Self.facts(.active, waiting: 21, started: 500))
    #expect(!due)
    (after, due) = Self.step(after, Self.facts(.active, waiting: 22, started: 500))
    #expect(due)
    after = O.shown(after, Self.facts(.active, waiting: 22, started: 500))
    #expect(after.stage == .open)
  }

  @Test func twentyNewGroupsCountFromTheLowestPointSinceTheRun() {
    var m = O.observe(M(), Self.facts(.active, waiting: 50, running: true, started: 10))
    var due = false
    for w in [30, 12, 5, 9, 24] {
      (m, due) = Self.step(m, Self.facts(.active, waiting: w, started: 10))
      #expect(!due)
    }
    (m, due) = Self.step(m, Self.facts(.active, waiting: 25, started: 10))
    #expect(due && m.low == 5)
    #expect(!O.due(m, Self.facts(.active, waiting: 25, enabled: false, started: 10)))
  }

  @Test func aNewMailboxFinishingItsImportBringsTheOfferBack() {
    var m = O.observe(M(), Self.facts(.active, waiting: 8, running: true, started: 10))
    var due = false
    (m, due) = Self.step(m, Self.facts(.active, waiting: 6, started: 10))
    #expect(!due)
    (m, due) = Self.step(m, Self.facts(.importing, waiting: 9, started: 10))
    #expect(!due && m.importSeen)
    (m, due) = Self.step(m, Self.facts(.active, caughtUp: false, waiting: 9, started: 10))
    #expect(!due)
    (m, due) = Self.step(m, Self.facts(.active, waiting: 9, started: 10))
    #expect(due)
    m = O.shown(m, Self.facts(.active, waiting: 9, started: 10))
    #expect(m.stage == .open && !m.importSeen)
  }

  @Test func aRunStartedDuringTheFirstImportIsNotOfferedAgainWhenItEnds() {
    var m = O.observe(M(), Self.facts(.importing, waiting: 30, running: true, started: 10))
    #expect(m.stage == .spent && !m.importSeen)
    var due = false
    (m, due) = Self.step(m, Self.facts(.importing, waiting: 0, running: true, started: 10))
    (m, due) = Self.step(m, Self.facts(.active, waiting: 6, started: 10))
    #expect(!due && !m.importSeen)
  }

  @Test func anEarlierRunFromAnOlderBuildSkipsTheFirstOffer() {
    let (m, due) = Self.step(M(), Self.facts(.active, waiting: 15, started: 99))
    #expect(m.stage == .spent && !due)
  }

  @Test func theMemoryRoundTripsAndIsForgottenWithTheAccount() throws {
    let name = "test.runOffer.\(UUID().uuidString)"
    let d = try #require(UserDefaults(suiteName: name))
    d.removePersistentDomain(forName: name)
    let store = RunOffer.Store.live(name)
    #expect(store.load() == M())
    var m = M()
    m.stage = .open
    m.low = 3
    m.opens = 1
    m.lastRunMs = 77
    store.save(m)
    #expect(store.load() == m)
    d.set(5, forKey: CloudSortDismissal.key)
    MainActor.assumeIsolated { LocalAccountData.forget(defaults: d) }
    #expect(d.object(forKey: RunOffer.Store.key) == nil)
    #expect(d.object(forKey: CloudSortDismissal.key) == nil)
    #expect(store.load() == M())
  }

  @Test func theStoredMemoryHoldsOnlyNumbers() throws {
    var m = M()
    m.stage = .spent
    m.low = 12
    m.importSeen = true
    m.lastRunMs = 1_792_000_000_000
    let json = try #require(String(data: JSONEncoder().encode(m), encoding: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["stage", "low", "importSeen", "wasImporting", "opens", "lastRunMs"])
    #expect(object.values.allSatisfy { $0 is NSNumber })
  }
}

@MainActor
@Suite("Cloud sort: the first-load signal")
struct CloudSortFirstLoadTests {
  typealias C = LiveCloudSortController

  @Test func theMailboxPhaseAndTheSyncMapOntoTheLoad() {
    var sync = CoreSync.SyncStatus()
    sync.lastSuccessAt = 1
    #expect(C.load(phase: .active, sync: sync) == RunOffer.Load(mailbox: .active, caughtUp: true))
    #expect(C.load(phase: .otherDevice, sync: sync).mailbox == .elsewhere)
    #expect(C.load(phase: .scanning, sync: sync).mailbox == .importing)
    #expect(C.load(phase: .authoringBackfill, sync: sync).mailbox == .importing)
    #expect(C.load(phase: .awaitingCards, sync: sync).mailbox == .awaitingCards)
    for phase: MailboxPhase? in [.unlinked, .halted, .reconnectRequired, nil] {
      #expect(C.load(phase: phase, sync: sync).mailbox == RunOffer.Mailbox.none)
    }
    #expect(!C.load(phase: .active, sync: CoreSync.SyncStatus()).caughtUp)
    var pulling = sync
    pulling.phase = .pulling
    #expect(!C.load(phase: .active, sync: pulling).caughtUp)
    var offline = sync
    offline.phase = .offline(sinceMs: 3)
    #expect(!C.load(phase: .active, sync: offline).caughtUp)
  }

  @Test func theFactsFollowTheStatus() {
    var s = MockCloudSortController.sample(.running)
    let load = RunOffer.Load(mailbox: .active, caughtUp: true)
    let run = BacklogRunRecord.Run(id: "r", startedMs: 44)
    var f = C.facts(s, run: run, load: load)
    #expect(f.enabled && f.runActive && f.runStartedMs == 44 && f.waitingNames == s.waitingNames && f.load == load)
    s.phase = .paused(.offline)
    #expect(C.facts(s, run: run, load: load).runActive)
    s.phase = .done
    #expect(!C.facts(s, run: nil, load: load).runActive)
    s.phase = .off
    f = C.facts(s, run: nil, load: load)
    #expect(!f.enabled && f.runStartedMs == nil)
  }

  static func controller(
    load: RunOffer.Load, waiting: Int = 12, enabled: Bool = true, offers: RunOffer.Store
  ) -> (C, BacklogSorter) {
    let saved = BacklogSorterTests.Saved()
    let sorter = BacklogSorter(
      pass: { _, _ in nil }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { enabled }, network: BacklogSorterTests.Net(), sleep: { _ in })
    let c = LiveCloudSortController(
      sorter: sorter, view: { _ in CloudSortStatusTests.view(waiting) }, undo: { 0 }, sendBack: { 0 }, enabled: { enabled },
      nowMs: { BacklogSorterTests.start }, load: { load }, offers: offers)
    return (c, sorter)
  }

  @Test func theControllerOffersOnceTheFirstLoadIsDoneAndRemembersItWasShown() async {
    let offers = RunOffer.Store.inMemory()
    let (c, _) = Self.controller(load: RunOffer.Load(mailbox: .active, caughtUp: true), offers: offers)
    await c.refresh()
    #expect(c.status.phase == .idle && c.status.offerDue)
    #expect(offers.load().stage == .firstLoad)
    c.offerShown()
    #expect(offers.load().stage == .open)
  }

  @Test func theControllerHoldsTheOfferWhileTheMailIsRead() async {
    let (c, _) = Self.controller(load: RunOffer.Load(mailbox: .importing, caughtUp: true), offers: .inMemory())
    await c.refresh()
    #expect(!c.status.offerDue)
    c.offerShown()
    #expect(!c.status.offerDue)
  }

  @Test func theControllerCountsReviewOpensForAStuckMailbox() async {
    let offers = RunOffer.Store.inMemory()
    let (c, _) = Self.controller(load: RunOffer.Load(mailbox: .awaitingCards, caughtUp: true), offers: offers)
    c.reviewOpened()
    await c.refresh()
    #expect(!c.status.offerDue && offers.load().opens == 1)
    c.reviewOpened()
    await c.refresh()
    #expect(c.status.offerDue && offers.load().opens == 2)
  }

  @Test func theControllerNeverOffersWithSuggestionsOff() async {
    let (c, _) = Self.controller(load: RunOffer.Load(mailbox: .active, caughtUp: true), enabled: false, offers: .inMemory())
    await c.refresh()
    #expect(c.status.phase == .off && !c.status.offerDue)
  }

  @Test func aStartedRunSpendsTheOffer() async {
    let offers = RunOffer.Store.inMemory()
    let (c, sorter) = Self.controller(load: RunOffer.Load(mailbox: .active, caughtUp: true), offers: offers)
    await c.refresh()
    c.offerShown()
    await sorter.start()
    await sorter.finished()
    await c.refresh()
    #expect(offers.load().stage == .spent && offers.load().lastRunMs == BacklogSorterTests.start)
    #expect(!c.status.offerDue)
  }
}
