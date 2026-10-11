// The Lane A scenarios against FakeServer (their live twins run against a
// local hasalad in LiveScenarioTests).
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Scenarios (FakeServer)")
struct ScenarioTests {
  @Test("sample data loaded on A reaches B: Maya's month, bills, review, trip and card")
  func sample() async throws {
    let w = World()
    w.clock.advance(ms: Scenarios.anchor - w.clock.nowMs())
    let (_, a, b) = try await twoRuntimes(w)
    try await Scenarios.sampleOnSecondDevice(a, b)
  }

  @Test("Gmail alerts read on A (real MailboxEngine) upload, and B folds and projects them")
  func gmailToReplay() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await Scenarios.gmailToReplay(a, b, clock: w.clock)
  }
}
