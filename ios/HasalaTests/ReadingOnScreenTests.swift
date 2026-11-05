import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Reading state on the money screens")
struct ReadingOnScreenTests {
  let today = LocalDate(2026, 10, 10)
  var october: YearMonth { YearMonth(2026, 10) }

  func state(_ kind: ReadingState.Kind, readsFrom: LocalDate? = nil) -> ReadingState {
    ReadingState(source: .mail(.gmail), kind: kind, readsFrom: readsFrom, today: today)
  }

  @Test func aStoppedLaneHoldsTheVerdictAndSaysWhy() throws {
    let hold = try #require(ReadingOnScreen.hold(state(.stopped(.signInAgain, since: LocalDate(2026, 10, 7))),
                                                 month: october))
    #expect(hold.caption == "spent up to Wed 7 Oct")
    #expect(hold.line == "Hasala stopped reading on Wed. Newer payments aren't counted.")
    #expect(hold.link == .signIn && hold.warns && hold.showsBar)
    let halted = try #require(ReadingOnScreen.hold(state(.stopped(.accountFull, since: LocalDate(2026, 9, 20))),
                                                   month: october))
    #expect(halted.link == .seeWhy)
    #expect(halted.line == "Hasala stopped reading on 20 Sep. Newer payments aren't counted.")
  }

  @Test func theFirstImportHoldsOnlyUntilThisMonthIsRead() throws {
    let reading = try #require(ReadingOnScreen.hold(
      state(.importing(read: 40, total: 268, thisMonthRead: false, offline: false, paused: false)), month: october))
    #expect(reading.caption == "spent so far · still reading this month")
    #expect(reading.line == nil && !reading.warns)
    #expect(ReadingOnScreen.hold(
      state(.importing(read: 40, total: 268, thisMonthRead: true, offline: false, paused: false)), month: october) == nil)
  }

  @Test func aPartlyReadMonthSaysWhereCountingStarts() throws {
    let hold = try #require(ReadingOnScreen.hold(state(.working, readsFrom: LocalDate(2026, 10, 4)), month: october))
    #expect(hold.caption == "spent since you connected")
    #expect(hold.overlineSuffix == "counting from 4 Oct")
    #expect(hold.line == "Earlier October isn't counted")
    #expect(hold.link == .importPast && !hold.showsBar)
    let august = try #require(ReadingOnScreen.hold(state(.working, readsFrom: LocalDate(2026, 8, 4)),
                                                   month: YearMonth(2026, 8)))
    #expect(august.caption == "spent since 4 Aug" && august.overlineSuffix == nil)
  }

  @Test func aCurrentReadHoldsNothing() {
    #expect(ReadingOnScreen.hold(state(.working), month: october) == nil)
    #expect(ReadingOnScreen.hold(nil, month: october) == nil)
    #expect(ReadingOnScreen.hold(state(.quiet(banks: ["DIB"])), month: october) == nil)
  }

  @Test func aStaleOtherIPhoneHoldsTheVerdict() throws {
    let hold = try #require(ReadingOnScreen.hold(
      state(.elsewhere(newest: LocalDate(2026, 10, 1), stale: true, canTakeOver: true)), month: october))
    #expect(hold.warns && hold.caption == "spent up to Thu 1 Oct")
    #expect(ReadingOnScreen.hold(state(.elsewhere(newest: today, stale: false, canTakeOver: true)), month: october) == nil)
  }

  @Test func homeHoldsOnlyAMonthView() {
    let app = AppModel(store: InMemoryLedger())
    let stopped = state(.stopped(.signInAgain, since: LocalDate(2026, 10, 7)))
    #expect(HomeViewModel.hold(app.snapshot.hero, reading: stopped, period: .month(october)) != nil)
    #expect(HomeViewModel.hold(app.snapshot.hero, reading: stopped,
                               period: Period(YearMonth(2026, 8), october)) == nil)
  }

  @Test func insightsSaysHowFarTheImportHasRead() {
    #expect(InsightsModel.importLine(state(.importing(read: 40, total: 268, thisMonthRead: true, offline: false,
                                                      paused: false)))
      == "Reading your alerts · 40 of 268. Older months will change.")
    #expect(InsightsModel.importLine(state(.importing(read: 0, total: 0, thisMonthRead: false, offline: false,
                                                      paused: false)))
      == "Reading your alerts. Older months will change.")
    #expect(InsightsModel.importLine(state(.working)) == nil)
  }

  @Test func lateBillsWaitWhileReadingIsHeld() {
    let snap = BillsViewModel(app: AppModel(store: InMemoryLedger())).snapshot
    #expect(snap.needsALook.contains { if case .late = $0.kind { true } else { false } })
    let held = BillsViewModel.held(snap, holdsLate: true)
    #expect(!held.needsALook.contains { if case .late = $0.kind { true } else { false } })
    #expect(held.needsALook.count == snap.needsALook.count - 1)
    #expect(BillsViewModel.held(snap, holdsLate: false) == snap)
  }

  @Test func bucketsUseTheChartColours() {
    #expect(Bucket.needs.splitColor == HColor.chartNeeds)
    #expect(Bucket.wants.splitColor == HColor.chartWants)
    #expect(Bucket.savings.splitColor == HColor.chartSavings)
    #expect(InsightsInk.bar(.needs) == HColor.chartNeeds)
    #expect(Bucket.wants.chartPattern == .dots && Bucket.savings.chartPattern == .hatch)
  }
}
