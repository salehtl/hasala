import CoreMailbox
import Foundation
import Synchronization
import Testing

@testable import Hasala

@Suite("Mailbox lane work")
struct MailboxLaneWorkTests {
  @Test func closingCancelsAndAwaitsEveryTaskAndRefusesNewOnes() async {
    let work = LaneWork()
    let sawCancel = Mutex(false)
    #expect(work.start {
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
      sawCancel.withLock { $0 = true }
    })
    #expect(work.running == 1)
    work.close()
    await work.cancelAll()
    #expect(sawCancel.withLock { $0 })
    #expect(work.running == 0)
    let ran = Mutex(false)
    #expect(!work.start { ran.withLock { $0 = true } })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!ran.withLock { $0 })
  }

  @Test func aFinishedTaskLeavesTheSet() async {
    let work = LaneWork()
    work.start {}
    for _ in 0..<100 where work.running > 0 { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(work.running == 0)
    #expect(!work.isClosed)
  }

  @MainActor @Test func aReviewOrSampleAccountIsRefusedAConnect() {
    #expect(LiveMailboxConnecting.refusal(reviewAccount: true, holdsSample: false) == .reviewAccount)
    #expect(LiveMailboxConnecting.refusal(reviewAccount: false, holdsSample: true) == .sampleData)
    #expect(LiveMailboxConnecting.refusal(reviewAccount: true, holdsSample: true) == .sampleData)
    #expect(LiveMailboxConnecting.refusal(reviewAccount: false, holdsSample: false) == nil)
  }

  @MainActor @Test func onlyNewlyTrustedSendersAreBackfilled() {
    #expect(LiveSetupAuthoring.newlyTrusted(kept: ["dib.ae", "emiratesnbd.com"], before: ["dib.ae"]) == ["emiratesnbd.com"])
    #expect(LiveSetupAuthoring.newlyTrusted(kept: ["dib.ae"], before: ["dib.ae", "emiratesnbd.com"]).isEmpty)
  }
}
