import Foundation
import HasalaModels
import Testing

@Suite("Reading state · one answer for every screen")
struct ReadingStateTests {
  static let hour: Int64 = 3_600_000
  static let day: Int64 = 24 * hour

  func ms(_ iso: String) -> Int64 { Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000) }

  var now: Int64 { ms("2026-10-20T06:00:00Z") }

  func mail(_ phase: ReadingFacts.LanePhase, halt: ReadingFacts.Halt? = nil, checkedAgo: Int64? = 5 * 60_000,
            connectedAgo: Int64? = 60 * Self.day) -> ReadingFacts.Mail
  {
    ReadingFacts.Mail(
      provider: .gmail, phase: phase, halt: halt, lastCheckedMs: checkedAgo.map { now - $0 },
      connectedMs: connectedAgo.map { now - $0 })
  }

  func state(_ f: ReadingFacts) -> ReadingState { ReadingState.derive(f) }

  @Test func localDayUsesTheFixedPlusFourClock() {
    #expect(ReadingState.localDay(ms("2026-10-31T19:59:59Z")) == LocalDate(2026, 10, 31))
    #expect(ReadingState.localDay(ms("2026-10-31T20:00:00Z")) == LocalDate(2026, 11, 1))
    #expect(ReadingState.localDay(0) == LocalDate(1970, 1, 1))
  }

  @Test func workingCountsAreCurrentAndHoldNothing() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active)))
    #expect(s.kind == .working)
    #expect(s.source == .mail(.gmail))
    #expect(s.countsAreCurrent)
    #expect(!s.holdsVerdict(YearMonth(2026, 10)))
    #expect(!s.needsYou)
    #expect(!s.holdsLateBills)
  }

  @Test func notKnownYetIsCheckingNotOff() {
    let s = state(ReadingFacts(nowMs: now, known: false))
    #expect(s.kind == .checking)
    #expect(!s.needsYou)
    #expect(!s.countsAreCurrent)
  }

  @Test func noSourceIsOff() {
    let s = state(ReadingFacts(nowMs: now))
    #expect(s.kind == .off)
    #expect(s.source == .none)
    #expect(s.countsAreCurrent)
  }

  @Test func sampleAccountNeverAsksForAMailbox() {
    let s = state(ReadingFacts(nowMs: now, sample: true, mail: mail(.unlinked)))
    #expect(s.kind == .sample)
    #expect(!s.needsYou)
  }

  @Test func aSignInStopHoldsTheVerdictAndSaysUpToWhen() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.reconnectRequired, checkedAgo: 3 * Self.day)))
    #expect(s.kind == .stopped(.signInAgain, since: LocalDate(2026, 10, 17)))
    #expect(s.countedThrough == LocalDate(2026, 10, 17))
    #expect(!s.countsAreCurrent)
    #expect(s.holdsVerdict(YearMonth(2026, 10)))
    #expect(!s.holdsVerdict(YearMonth(2026, 9)))
    #expect(s.needsYou)
    #expect(s.holdsLateBills)
  }

  @Test(arguments: [
    (ReadingFacts.Halt.accountFull, ReadingState.StopReason.accountFull),
    (.templates, .other),
    (.quota, .other),
    (.noMailbox, .noMailbox),
    (.signIn, .signInAgain),
  ])
  func everyHaltIsAStopNotOnlySignIn(halt: ReadingFacts.Halt, reason: ReadingState.StopReason) {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.halted, halt: halt, checkedAgo: Self.day)))
    #expect(s.kind == .stopped(reason, since: LocalDate(2026, 10, 19)))
    #expect(s.needsYou)
    #expect(s.holdsVerdict(YearMonth(2026, 10)))
  }

  @Test func aStopLastMonthHoldsThatMonthAndThisOne() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.halted, halt: .accountFull, checkedAgo: 25 * Self.day)))
    #expect(s.countedThrough == LocalDate(2026, 9, 25))
    #expect(s.holdsVerdict(YearMonth(2026, 9)))
    #expect(s.holdsVerdict(YearMonth(2026, 10)))
    #expect(!s.holdsVerdict(YearMonth(2026, 8)))
    #expect(!s.isComplete(YearMonth(2026, 9)))
    #expect(s.isComplete(YearMonth(2026, 8)))
  }

  @Test func firstImportHoldsThisMonthUntilItsPassIsRead() {
    var m = mail(.scanning)
    m.importRead = 40
    m.importTotal = 268
    let reading = state(ReadingFacts(nowMs: now, mail: m))
    #expect(reading.kind == .importing(read: 40, total: 268, thisMonthRead: false, offline: false, paused: false))
    #expect(reading.holdsVerdict(YearMonth(2026, 10)))
    #expect(reading.holdsLateBills)
    #expect(!reading.needsYou)
    m.thisMonthRead = true
    let older = state(ReadingFacts(nowMs: now, mail: m))
    #expect(!older.holdsVerdict(YearMonth(2026, 10)))
    #expect(!older.holdsLateBills)
    #expect(!older.isComplete(YearMonth(2026, 9)))
  }

  @Test func importCountNeverRunsPastItsTotal() {
    var m = mail(.backfill)
    m.importRead = 300
    m.importTotal = 268
    #expect(state(ReadingFacts(nowMs: now, mail: m)).kind
      == .importing(read: 268, total: 268, thisMonthRead: false, offline: false, paused: false))
  }

  @Test func heldElsewhereOnANewIPhoneIsReadElsewhereNotNotConnected() {
    let s = state(ReadingFacts(
      nowMs: now, mail: mail(.unlinked, checkedAgo: nil), heldElsewhere: .outlook, newestMailRowMs: now - 2 * Self.day))
    #expect(s.kind == .elsewhere(newest: LocalDate(2026, 10, 18), stale: false, canTakeOver: true))
    #expect(s.source == .mail(.outlook))
    #expect(!s.needsYou)
    #expect(s.countsAreCurrent)
  }

  @Test func anOldReaderIsElsewhereAndGoesStaleAfterAWeek() {
    let fresh = state(ReadingFacts(nowMs: now, mail: mail(.otherDevice), newestMailRowMs: now - 6 * Self.day))
    #expect(fresh.kind == .elsewhere(newest: LocalDate(2026, 10, 14), stale: false, canTakeOver: false))
    #expect(!fresh.needsYou)
    let stale = state(ReadingFacts(nowMs: now, mail: mail(.otherDevice), newestMailRowMs: now - 8 * Self.day))
    #expect(stale.elsewhereStale)
    #expect(stale.needsYou)
    #expect(!stale.countsAreCurrent)
    #expect(stale.countedThrough == LocalDate(2026, 10, 12))
    #expect(stale.holdsVerdict(YearMonth(2026, 10)))
  }

  @Test func anOldReaderMayTakeReadingBackWhenTheServerNamesAnotherHolder() {
    let s = state(ReadingFacts(
      nowMs: now, mail: mail(.otherDevice), heldElsewhere: .gmail, newestMailRowMs: now - Self.day))
    #expect(s.kind == .elsewhere(newest: LocalDate(2026, 10, 19), stale: false, canTakeOver: true))
  }

  @Test func elsewhereWithNoRowYetIsStale() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.otherDevice)))
    #expect(s.elsewhereStale)
  }

  @Test func behindWhenNotCheckedForADay() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active, checkedAgo: 2 * Self.day), backgroundRefreshOff: true))
    #expect(s.kind == .behind(since: LocalDate(2026, 10, 18), backgroundRefreshOff: true))
    #expect(!s.needsYou)
  }

  @Test func quietNamesOnlyBanksPastTheLimit() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active), banks: [
      .init(name: "Emirates NBD", lastMailMs: now - 15 * Self.day),
      .init(name: "DIB", lastMailMs: now - Self.day),
      .init(name: "ADCB", lastMailMs: nil),
    ]))
    #expect(s.kind == .quiet(banks: ["Emirates NBD", "ADCB"]))
    #expect(s.needsYou)
    #expect(s.countsAreCurrent)
  }

  @Test func quietNeverShowsBeforeTheMailboxIsOldEnough() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active, connectedAgo: 3 * Self.day), banks: [
      .init(name: "ADCB", lastMailMs: nil)
    ]))
    #expect(s.kind == .working)
  }

  @Test func textsWaitForTheFirstRunThenWork() {
    #expect(state(ReadingFacts(nowMs: now, texts: .init())).kind == .waitingForFirstText)
    let missed = state(ReadingFacts(nowMs: now, texts: .init(testMissed: true)))
    #expect(missed.kind == .textTestMissed)
    #expect(missed.needsYou)
    let s = state(ReadingFacts(nowMs: now, texts: .init(lastRunMs: now - Self.hour)))
    #expect(s.kind == .working)
    #expect(s.source == .texts)
  }

  @Test func aMailboxLinkWinsOverTexts() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active), texts: .init(lastRunMs: now)))
    #expect(s.source == .mail(.gmail))
  }

  @Test func skippedPastEmailGivesTheExactStart() {
    var m = mail(.active)
    m.pastSkippedFromMs = ms("2026-10-04T08:00:00Z")
    let s = state(ReadingFacts(nowMs: now, mail: m, earliestBankRow: LocalDate(2026, 10, 5)))
    #expect(s.readsFrom == LocalDate(2026, 10, 4))
    #expect(s.readsFromExact)
    #expect(s.isPartlyRead(YearMonth(2026, 10)))
    #expect(s.holdsVerdict(YearMonth(2026, 10)))
  }

  @Test func earliestRowIsTheFallbackStartOnEveryDevice() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active), earliestBankRow: LocalDate(2026, 8, 4)))
    #expect(s.readsFrom == LocalDate(2026, 8, 4))
    #expect(!s.readsFromExact)
    #expect(s.isPartlyRead(YearMonth(2026, 8)))
    #expect(!s.isComplete(YearMonth(2026, 8)))
    #expect(s.isComplete(YearMonth(2026, 9)))
    #expect(s.isBeforeReading(YearMonth(2026, 7)))
    #expect(!s.holdsVerdict(YearMonth(2026, 9)))
    #expect(!s.holdsVerdict(YearMonth(2026, 10)))
  }

  @Test func aMonthReadFromTheFirstIsWhole() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.active), earliestBankRow: LocalDate(2026, 8, 1)))
    #expect(!s.isPartlyRead(YearMonth(2026, 8)))
    #expect(s.isComplete(YearMonth(2026, 8)))
  }

  @Test func noSourceHasNoReadingStart() {
    let s = state(ReadingFacts(nowMs: now, earliestBankRow: LocalDate(2026, 8, 4)))
    #expect(s.readsFrom == nil)
  }

  @Test func theCurrentMonthIsNeverComplete() {
    #expect(!state(ReadingFacts(nowMs: now, mail: mail(.active))).isComplete(YearMonth(2026, 10)))
  }

  @Test func movedAwayIsCarried() {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.otherDevice), newestMailRowMs: now, movedAwayMs: now - Self.hour))
    #expect(s.movedAway)
  }

  @Test func roundTripsThroughCodable() throws {
    let s = state(ReadingFacts(nowMs: now, mail: mail(.halted, halt: .accountFull)))
    let back = try JSONDecoder().decode(ReadingState.self, from: JSONEncoder().encode(s))
    #expect(back == s)
  }
}

@Suite("Reading state · carried by the ledger state")
struct LedgerStateReadingTests {
  @Test func theLedgerStateCarriesTheReadingStateAndDefaultsToNone() {
    let plan = PlanState(income: .aed(0), payday: 28, startingSplit: [50, 30, 20], budgets: [:])
    let profile = ProfileInfo(displayName: "Test", email: "test@example.com")
    let none = LedgerState(
      categories: [], accounts: [], txns: [], plan: plan, profile: profile,
      mailbox: MailboxHealth(status: .working, lastEmail: "", banks: ""))
    #expect(none.reading == nil)
    let stopped = ReadingState.derive(ReadingFacts(
      nowMs: 1_792_476_000_000, mail: .init(provider: .gmail, phase: .reconnectRequired, lastCheckedMs: 1_792_400_000_000)))
    var s = none
    s.reading = stopped
    #expect(s.reading?.stopped == true)
  }
}
