import CoreMailbox
import Foundation
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live reading state")
struct LiveReadingTests {
  static let now: Int64 = 1_792_476_000_000
  static let day: Int64 = 86_400_000

  func mail(
    _ phase: MailboxPhase, halt: MailboxHaltCode? = nil, progress: MailboxProgress? = nil, readFrom: Int64? = nil
  ) -> ReadingFacts.Mail {
    LiveReading.mail(
      phase: phase, halt: halt, lastSuccessMs: Self.now - 60_000, connectedMs: Self.now - 30 * Self.day,
      readFromMs: readFrom, provider: .gmail, progress: progress)
  }

  @Test func everyLanePhaseHasAReadingPhase() {
    #expect(LiveReading.lanePhase(.unlinked) == .unlinked)
    #expect(LiveReading.lanePhase(.scanning) == .scanning)
    #expect(LiveReading.lanePhase(.awaitingCards) == .backfill)
    #expect(LiveReading.lanePhase(.authoringBackfill) == .backfill)
    #expect(LiveReading.lanePhase(.active) == .active)
    #expect(LiveReading.lanePhase(.otherDevice) == .otherDevice)
    #expect(LiveReading.lanePhase(.reconnectRequired) == .reconnectRequired)
    #expect(LiveReading.lanePhase(.halted) == .halted)
  }

  @Test func aHaltWithNoBellRowStillStopsReading() {
    for code in [MailboxHaltCode.accountFull, .templatesUnavailable, .quota, .gmail, .stagingFull] {
      let s = ReadingState.derive(ReadingFacts(nowMs: Self.now, mail: mail(.halted, halt: code)))
      #expect(s.stopped, "\(code)")
      #expect(!s.countsAreCurrent)
      #expect(s.needsYou)
    }
  }

  @Test func theHaltCodeIsOnlyReadWhileHalted() {
    #expect(mail(.active, halt: .accountFull).halt == nil)
    #expect(mail(.halted, halt: .noMailbox).halt == .noMailbox)
    #expect(mail(.halted, halt: .notHolder).halt == .signIn)
  }

  @Test func theFirstImportCarriesItsCountAndThisMonthsPass() {
    let early = mail(.scanning, progress: MailboxProgress(stage: .downloading, done: 40, total: 268))
    #expect(early.importRead == 40 && early.importTotal == 268 && !early.thisMonthRead)
    let later = mail(.scanning, progress: MailboxProgress(stage: .downloading, done: 200, total: 268, thisMonthRead: true))
    #expect(later.thisMonthRead)
    #expect(mail(.authoringBackfill).thisMonthRead)
    #expect(mail(.scanning, progress: MailboxProgress(stage: .failed(.offline), done: 0, total: 0)).importOffline)
    #expect(mail(.scanning, progress: MailboxProgress(stage: .failed(.quota), done: 0, total: 0)).importPaused)
  }

  @Test func quietBanksComeFromTheTrustedListAndTheirHealthRows() {
    let health = [
      BankHealthRow(domain: "emiratesnbd.com", lastEmailAtMs: Self.now - 20 * Self.day, month: "2026-10", readThisMonth: 0)
    ]
    let banks = LiveReading.banks(health, trusted: [.enbd, .dib])
    #expect(banks.map(\.name) == ["Emirates NBD", "Dubai Islamic Bank"])
    #expect(banks[1].lastMailMs == nil)
    let s = ReadingState.derive(ReadingFacts(nowMs: Self.now, mail: mail(.active), banks: banks))
    #expect(s.kind == .quiet(banks: ["Emirates NBD", "Dubai Islamic Bank"]))
  }

  @Test func theReadingStartIsTheEarliestBankRow() {
    let read = Provenance(title: "Alert", readAt: "", rawMerchant: "SHOP")
    let txns = [
      Txn(id: "a", merchant: "Shop", amount: .aed(100), postedAt: LocalDateTime(2026, 8, 4, 9), provenance: read),
      Txn(id: "b", merchant: "Cash", amount: .aed(100), postedAt: LocalDateTime(2026, 7, 1, 9)),
      Txn(id: "c", merchant: "Shop", amount: .aed(100), postedAt: LocalDateTime(2026, 9, 2, 9), provenance: read),
    ]
    #expect(LiveReading.earliestBankRow(txns) == LocalDate(2026, 8, 4))
    #expect(LiveReading.earliestBankRow([]) == nil)
  }

  @Test func movedAwayOnlyWhenThisIPhoneWasReading() {
    #expect(LiveReading.movedAway(from: .active, to: .otherDevice))
    #expect(LiveReading.movedAway(from: .halted, to: .otherDevice))
    #expect(!LiveReading.movedAway(from: .unlinked, to: .otherDevice))
    #expect(!LiveReading.movedAway(from: nil, to: .otherDevice))
    #expect(!LiveReading.movedAway(from: .active, to: .active))
  }

  @Test func thePhaseSeenHereSurvivesARelaunchUntilTheAccountLeaves() throws {
    let name = "LiveReadingTests.phaseSeen"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(LocalAccountData.mailboxPhaseSeen(defaults) == nil)
    LocalAccountData.setMailboxPhaseSeen(.active, defaults)
    #expect(LocalAccountData.mailboxPhaseSeen(defaults) == .active)
    LocalAccountData.forget(defaults: defaults)
    #expect(LocalAccountData.mailboxPhaseSeen(defaults) == nil)
  }

  @Test func theMovedAwayNoteIsKeptAndForgotten() throws {
    let defaults = try #require(UserDefaults(suiteName: "LiveReadingTests"))
    defaults.removePersistentDomain(forName: "LiveReadingTests")
    #expect(LocalAccountData.mailboxMovedAway(defaults) == nil)
    LocalAccountData.setMailboxMovedAway(Self.now, defaults)
    #expect(LocalAccountData.mailboxMovedAway(defaults) == Self.now)
    LocalAccountData.setMailboxMovedAway(nil, defaults)
    #expect(LocalAccountData.mailboxMovedAway(defaults) == nil)
    defaults.removePersistentDomain(forName: "LiveReadingTests")
  }
}
