// The Lane A scenarios against FakeServer (their live twins run against a
// local hasalad in LiveScenarioTests).
import CoreDomain
import CoreSync
import CoreTestSupport
import CoreTime
import Foundation
import Testing

@Suite("Scenarios (FakeServer)")
struct ScenarioTests {
  @Test("sample data loaded on A reaches B: Maya's month, bills, review, trip and card")
  func sample() async throws {
    let w = World()
    w.clock.advance(ms: Scenarios.anchor - w.clock.nowMs())
    let (_, a, b) = try await twoRuntimes(w)
    try await Scenarios.sampleOnSecondDevice(a, b) { review in
      w.server.setReviewAccount(user: a.context.userID, review)  // `account review <uuid> on|off`
      return try await a.context.client.account(bearer: try #require(try a.context.secrets.session()).token)
    }
  }

  @Test("a review account that already has a transaction is refused, nothing authored (AT-34)")
  func sampleRefusedWithTransactions() async throws {
    let w = World()
    w.clock.advance(ms: Scenarios.anchor - w.clock.nowMs())
    let (_, a, _) = try await twoRuntimes(w)
    try await a.bootstrap()
    try await a.author { x in
      _ = try x.manualEntry(
        amountMinor: 1_500, currency: "AED", direction: "debit", localWallMs: Scenarios.anchor + LocalClock.offsetMs,
        merchant: "Corner Shop", category: "dining")
    }
    w.server.setReviewAccount(user: a.context.userID, true)
    let pending = try a.context.store.pendingCount()
    // Pending (not yet uploaded) counts: the outbox is part of the ledger.
    await #expect(throws: SampleLoadError.seed(.refused(.hasTransactions))) { _ = try await a.loadSample() }
    #expect(await a.run(.authored).stop == nil)
    await #expect(throws: SampleLoadError.seed(.refused(.hasTransactions))) { _ = try await a.loadSample() }
    #expect(try a.context.store.pendingCount() == 0 && pending > 0)
  }

  @Test("Gmail alerts read on A (real MailboxEngine) upload, and B folds and projects them")
  func gmailToReplay() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await Scenarios.gmailToReplay(a, b, clock: w.clock)
  }
}
