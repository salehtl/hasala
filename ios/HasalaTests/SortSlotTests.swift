import CoreMailbox
import CoreSync
import Foundation
import Observation
import SwiftUI
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

  @Test func aRunningRunShowsOverTheImportAndAPausedOneUnderIt() {
    #expect(SortSlot.of(F(status: Self.status(.running), importing: Self.reading)) == .run(.running))
    let paused = Self.status(.paused(.busy(untilMs: 5)))
    #expect(SortSlot.of(F(status: paused, importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.of(F(status: paused)) == .run(.paused(.busy(untilMs: 5))))
    #expect(SortSlot.of(F(status: Self.status(.paused(.runCap)))) == .run(.paused(.runCap)))
    #expect(SortSlot.of(F(status: Self.status(.paused(.dayCap)), importing: Self.reading)) == .importing(Self.reading))
  }

  @Test func theResultStaysUntilItsRunIsDismissed() {
    let done = Self.status(.done) { $0.lastRunEndedMs = 1_000 }
    #expect(SortSlot.of(F(status: done)) == .result)
    #expect(SortSlot.of(F(status: done, dismissedRun: 999)) == .result)
    #expect(SortSlot.of(F(status: done, dismissedRun: 999, importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.of(F(status: done, dismissedRun: 1_000)) == nil)
    #expect(SortSlot.of(F(status: done, dismissedRun: 1_000, importing: Self.reading)) == .importing(Self.reading))
    #expect(SortSlot.result.card == .done)
  }

  @Test func aDueReturnOfferReplacesAnOldResult() {
    let old = Self.status(.done) {
      $0.lastRunEndedMs = 7
      $0.waitingNames = 30
      $0.nextRunNames = 30
      $0.remainingToday = 300
      $0.offerDue = false
    }
    #expect(SortSlot.of(F(status: old)) == .result)
    var returning = old
    returning.offerDue = true
    #expect(SortSlot.of(F(status: returning)) == .offer(.ready))
    #expect(SortSlot.of(F(status: returning))?.isOffer == true)
    var capped = returning
    capped.remainingToday = 0
    capped.nextRunNames = 0
    #expect(SortSlot.of(F(status: capped)) == .result)
    #expect(SortSlot.of(F(status: capped, dismissedRun: 7)) == .offer(.paused(.dayCap)))
  }

  @Test func theResultStaysAheadOfAReturnOfferWhileItsSuggestionsWait() {
    let returning = Self.status(.done) {
      $0.lastRunEndedMs = 7
      $0.waitingNames = 30
      $0.nextRunNames = 30
      $0.remainingToday = 300
      $0.offerDue = true
    }
    #expect(SortSlot.of(F(status: returning, suggestions: 3)) == .result)
    #expect(SortSlot.of(F(status: returning, importing: Self.reading, suggestions: 3)) == .importing(Self.reading))
    #expect(SortSlot.of(F(status: returning, dismissedRun: 7, suggestions: 3)) == .offer(.ready))
    #expect(SortSlot.of(F(status: returning, suggestions: 0)) == .offer(.ready))
    #expect(SortSlot.of(F(status: Self.status(.idle), suggestions: 3)) == .offer(.ready))
  }

  @Test func aDueOfferShowsOverAMailboxStuckWaitingForCards() {
    let stuck = LiveMailboxConnecting.importing(phase: .awaitingCards, seen: true, progress: nil)
    #expect(stuck == MailImport(state: .reading, read: 0, total: 0))
    let f = RunOfferTests.facts(.awaitingCards, waiting: 147)
    var m = RunOffer.opened(RunOffer.opened(RunOffer.observe(RunOffer.Memory(), f), f), f)
    #expect(RunOffer.due(m, f))
    let idle = Self.status(.idle) { $0.offerDue = RunOffer.due(m, f) }
    let slot = SortSlot.of(F(status: idle, importing: stuck))
    #expect(slot == .offer(.ready))
    #expect(SortSlot.offerSeen(slot, onReview: true, phase: .active, covered: false))
    m = RunOffer.shown(m, f)
    #expect(m.stage == .open)
    let scanning = LiveMailboxConnecting.importing(phase: .scanning, seen: true, progress: nil)
    #expect(!RunOffer.due(m, RunOfferTests.facts(.importing, waiting: 147)))
    #expect(SortSlot.of(F(status: Self.status(.idle) { $0.offerDue = false }, importing: scanning)) == scanning.map(SortSlot.importing))
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
    #expect(SortSlot.importingLine(MailImport(state: .offline, read: 3, total: 9))
      == "Paused. No internet connection. It continues when you're back online.")
    #expect(SortSlot.importingLine(MailImport(state: .paused, read: 3, total: 9)) == "Paused for now. Hasala tries again soon.")
  }

  @Test func withNothingToSortTheImportDoesNotInviteAStart() {
    let line = SortSlot.importingLine(Self.reading, queued: false)
    #expect(line == "Hasala is reading your bank alerts. Payments to sort show up here.")
    #expect(!line.contains("start"))
    #expect(SortSlot.importingSpoken(Self.reading, queued: false)
      == "Reading your mail, 312 so far. Hasala is reading your bank alerts. Payments to sort show up here.")
    let offline = MailImport(state: .offline, read: 3, total: 9)
    #expect(SortSlot.importingLine(offline, queued: false) == SortSlot.importingLine(offline))
  }

  @Test func theOfferCountsAsShownOnlyOnTheVisibleReviewTab() {
    let offer = SortSlot.of(F(status: Self.status(.idle)))
    #expect(SortSlot.offerSeen(offer, onReview: true, phase: .active, covered: false))
    #expect(!SortSlot.offerSeen(offer, onReview: false, phase: .active, covered: false))
    #expect(!SortSlot.offerSeen(offer, onReview: true, phase: .inactive, covered: false))
    #expect(!SortSlot.offerSeen(offer, onReview: true, phase: .background, covered: false))
    #expect(!SortSlot.offerSeen(offer, onReview: true, phase: .active, covered: true))
    #expect(!SortSlot.offerSeen(.run(.running), onReview: true, phase: .active, covered: false))
    #expect(!SortSlot.offerSeen(nil, onReview: true, phase: .active, covered: false))
  }

  @Test func onlyAReturnFromTheBackgroundCountsAsAnOpen() {
    var f = SortSlot.Foregrounds()
    let phases: [ScenePhase] = [.inactive, .active, .inactive, .active, .inactive, .background, .inactive, .active, .inactive, .active]
    let opens = phases.map { f.note($0) }
    #expect(opens == [false, false, false, false, false, false, false, true, false, false])
  }

  @Test func dismissingTheResultSaysCheckSuggestionsGoesWithIt() {
    #expect(CloudSortCardState.dismissHint(suggestions: 0).isEmpty)
    #expect(CloudSortCardState.dismissHint(suggestions: 3).hasPrefix("Check suggestions is no longer offered."))
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

  @Test func theImportEdgeIsNotedFromThePhaseAlone() {
    var m = M(stage: .spent, low: 12, lastRunMs: 10)
    m = O.noted(m, .active)
    #expect(!m.importSeen)
    m = O.noted(m, .importing)
    #expect(m.importSeen && m.wasImporting)
    m = O.noted(m, .active)
    #expect(m.importSeen && !m.wasImporting)
    #expect(O.due(m, Self.facts(.active, waiting: 12, started: 10)))
    let first = O.noted(M(), .importing)
    #expect(!first.importSeen)
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

  static func sorter(enabled: Bool = true) -> BacklogSorter {
    let saved = BacklogSorterTests.Saved()
    return BacklogSorter(
      pass: { _, _ in nil }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { enabled }, network: BacklogSorterTests.Net(), sleep: { _ in })
  }

  static func controller(
    load: RunOffer.Load, waiting: Int = 12, enabled: Bool = true, offers: RunOffer.Store
  ) -> (C, BacklogSorter) {
    let sorter = Self.sorter(enabled: enabled)
    let c = LiveCloudSortController(
      sorter: sorter, view: { _ in CloudSortStatusTests.view(waiting) }, undo: { 0 }, sendBack: { 0 }, enabled: { enabled },
      nowMs: { BacklogSorterTests.start }, load: { load }, offers: offers)
    return (c, sorter)
  }

  nonisolated final class Gate: Sendable {
    let calls = Mutex(0)
    let open = Mutex(false)

    func view(slow: Int, fast: Int) -> @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView? {
      { _ in
        let n = self.calls.withLock { c in
          c += 1
          return c
        }
        guard n == 1 else { return CloudSortStatusTests.view(fast) }
        while !self.open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        return CloudSortStatusTests.view(slow)
      }
    }
  }

  @Test func anOlderCountCannotOverwriteANewerOne() async throws {
    let gate = Gate()
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: gate.view(slow: 5, fast: 40), undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start }, load: { RunOffer.Load(mailbox: .active, caughtUp: true) }, offers: .inMemory())
    let first = Task { await c.refresh() }
    try await LiveLedgerMapperTests.eventually { gate.calls.withLock { $0 } == 1 }
    await c.refresh()
    #expect(c.status.waitingNames == 40)
    gate.open.withLock { $0 = true }
    await first.value
    #expect(c.status.waitingNames == 40)
  }

  @Test func countChangesAreCoalesced() async throws {
    let gate = Gate()
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: gate.view(slow: 5, fast: 40), undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start }, load: { RunOffer.Load(mailbox: .active, caughtUp: true) }, offers: .inMemory())
    c.countsChanged()
    try await LiveLedgerMapperTests.eventually { gate.calls.withLock { $0 } == 1 }
    for _ in 0..<30 { c.countsChanged() }
    gate.open.withLock { $0 = true }
    try await LiveLedgerMapperTests.eventually { c.status.waitingNames == 40 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(gate.calls.withLock { $0 } == 2)
    #expect(c.status.waitingNames == 40)
  }

  @MainActor @Observable final class Phase {
    var mailbox: RunOffer.Mailbox = .active
  }

  @Test func theControllerSeesANewMailboxImportWithoutTheReviewTab() async throws {
    let phase = Phase()
    let offers = RunOffer.Store.inMemory(RunOffer.Memory(stage: .spent, low: 12, lastRunMs: 1))
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: { _ in CloudSortStatusTests.view(12) }, undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start }, load: { RunOffer.Load(mailbox: phase.mailbox, caughtUp: true) }, offers: offers,
      watch: { phase.mailbox })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!c.status.offerDue && !offers.load().importSeen)
    phase.mailbox = .importing
    try await LiveLedgerMapperTests.eventually { offers.load().wasImporting }
    #expect(offers.load().importSeen && !c.status.offerDue)
    phase.mailbox = .awaitingCards
    try await Task.sleep(for: .milliseconds(50))
    phase.mailbox = .active
    try await LiveLedgerMapperTests.eventually { c.status.offerDue }
    #expect(c.status.offerDue && offers.load().importSeen && !offers.load().wasImporting)
    c.offerShown()
    #expect(offers.load().stage == .open && !offers.load().importSeen)
  }

  @MainActor @Observable final class Sync {
    var revision = 0
    var caughtUp = false
    var loads = 0
  }

  @Test func theFirstOfferShowsOnceASyncThatWasRunningEnds() async throws {
    let sync = Sync()
    let offers = RunOffer.Store.inMemory()
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: { _ in CloudSortStatusTests.view(12) }, undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start },
      load: {
        sync.loads += 1
        return RunOffer.Load(mailbox: .active, caughtUp: sync.caughtUp)
      }, offers: offers, watch: { .active }, settled: { sync.revision })
    await c.refresh()
    #expect(!c.status.offerDue && offers.load().stage == .firstLoad)
    sync.caughtUp = true
    sync.revision += 1
    try await LiveLedgerMapperTests.eventually { c.status.offerDue }
    c.offerShown()
    #expect(offers.load().stage == .open)
    let loads = sync.loads
    for _ in 0..<5 {
      sync.revision += 1
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sync.loads == loads)
  }

  @Test func aSyncEndingDoesNotRereadWhileTheOfferWaitsOnNothingElse() async throws {
    let sync = Sync()
    let offers = RunOffer.Store.inMemory(RunOffer.Memory(stage: .spent, low: 12, lastRunMs: 1))
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: { _ in CloudSortStatusTests.view(12) }, undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start },
      load: {
        sync.loads += 1
        return RunOffer.Load(mailbox: .active, caughtUp: sync.caughtUp)
      }, offers: offers, watch: { .active }, settled: { sync.revision })
    await c.refresh()
    try await Task.sleep(for: .milliseconds(50))
    let loads = sync.loads
    sync.caughtUp = true
    for _ in 0..<5 {
      sync.revision += 1
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sync.loads == loads && !c.status.offerDue)
  }

  @Test func theImportReturnOfferShowsOnceASyncThatWasRunningEnds() async throws {
    let sync = Sync()
    let offers = RunOffer.Store.inMemory(
      RunOffer.Memory(stage: .spent, low: 12, importSeen: true, lastRunMs: 1))
    let c = LiveCloudSortController(
      sorter: Self.sorter(), view: { _ in CloudSortStatusTests.view(12) }, undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start },
      load: { RunOffer.Load(mailbox: .active, caughtUp: sync.caughtUp) }, offers: offers, watch: { .active },
      settled: { sync.revision })
    await c.refresh()
    #expect(!c.status.offerDue)
    sync.caughtUp = true
    sync.revision += 1
    try await LiveLedgerMapperTests.eventually { c.status.offerDue }
  }

  nonisolated final class Hold: Sendable {
    let held = Mutex(false)
    let calls = Mutex(0)

    func view(_ waiting: Int) -> @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView? {
      { _ in
        self.calls.withLock { $0 += 1 }
        while self.held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        return CloudSortStatusTests.view(waiting)
      }
    }
  }

  @Test func aStaleCountDoesNotTurnTheEndOfTheFirstImportIntoANewOne() async throws {
    let phase = Phase()
    phase.mailbox = .importing
    let hold = Hold()
    let offers = RunOffer.Store.inMemory()
    let sorter = Self.sorter()
    let c = LiveCloudSortController(
      sorter: sorter, view: hold.view(12), undo: { 0 }, sendBack: { 0 }, enabled: { true },
      nowMs: { BacklogSorterTests.start }, load: { RunOffer.Load(mailbox: phase.mailbox, caughtUp: true) }, offers: offers,
      watch: { phase.mailbox })
    await c.refresh()
    await sorter.start()
    await sorter.finished()
    try await LiveLedgerMapperTests.eventually { offers.load().stage == .spent && c.status.phase == .done }
    try await Task.sleep(for: .milliseconds(100))
    #expect(offers.load().wasImporting && !offers.load().importSeen)
    let before = hold.calls.withLock { $0 }
    hold.held.withLock { $0 = true }
    phase.mailbox = .active
    try await LiveLedgerMapperTests.eventually { hold.calls.withLock { $0 } > before }
    #expect(!offers.load().wasImporting)
    await sorter.spent(1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!offers.load().importSeen)
    hold.held.withLock { $0 = false }
    await c.refresh()
    #expect(c.status.phase == .done && !c.status.offerDue && !offers.load().importSeen)
  }

  @Test func anOfferDueWhileAnotherTabIsOpenStaysUnshown() async {
    let offers = RunOffer.Store.inMemory()
    let (c, _) = Self.controller(load: RunOffer.Load(mailbox: .active, caughtUp: true), offers: offers)
    await c.refresh()
    #expect(c.status.offerDue)
    let slot = SortSlot.of(SortSlot.Facts(status: c.status))
    if SortSlot.offerSeen(slot, onReview: false, phase: .active, covered: false) { c.offerShown() }
    #expect(offers.load().stage == .firstLoad)
    if SortSlot.offerSeen(slot, onReview: true, phase: .active, covered: false) { c.offerShown() }
    #expect(offers.load().stage == .open)
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
