import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Review tab: the slot above the queue")
struct SortSlotTests {
  typealias F = SortSlot.Facts

  static func status(_ phase: CloudSortStatus.Phase) -> CloudSortStatus {
    MockCloudSortController.sample(phase)
  }

  static let reading = MailImport(state: .reading, read: 312, total: 900)

  @Test func nothingToShowLeavesTheSlotEmpty() {
    #expect(SortSlot.of(F()) == nil)
    #expect(SortSlot.of(F(status: Self.status(.off))) == nil)
    #expect(SortSlot.of(F(importing: MailImport(state: .stopped("Reading stopped"), read: 4, total: 9))) == nil)
  }

  @Test func noRunOfferOrResultEverTakesTheSlot() {
    let phases: [CloudSortStatus.Phase] = [
      .idle, .running, .done, .paused(.offline), .paused(.background), .paused(.busy(untilMs: 5)), .paused(.rateLimited(untilMs: 5)),
      .paused(.dayCap),
    ]
    for phase in phases {
      #expect(SortSlot.of(F(status: Self.status(phase))) == nil)
      #expect(SortSlot.of(F(status: Self.status(phase), importing: Self.reading)) == .importing(Self.reading))
    }
  }

  @Test func theConsentAskComesFirstAndOnlyWhileSuggestionsAreOff() {
    #expect(SortSlot.of(F(asks: true)) == .ask)
    #expect(SortSlot.of(F(asks: true, status: Self.status(.off), importing: Self.reading)) == .ask)
    #expect(SortSlot.of(F(asks: true, status: Self.status(.running))) == nil)
    #expect(SortSlot.of(F(asks: false, status: Self.status(.off), importing: Self.reading)) == .importing(Self.reading))
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
}
