import CoreMailbox
import CoreStore
import CoreSync
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

  @MainActor @Test func aNewlyChosenBankIsSavedToImportWithItsTrustWhenTheLaneIsStopped() async throws {
    let server = MiniHasalad(invite: LiveAccountServiceTests.invite)
    let env = LiveAccountServiceTests.phone(server)
    let (account, _) = try await LiveAccountServiceTests.signUp(server, env)
    let binding = try #require(try env.secrets.binding())
    let facts = BankTextsFacts(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)"))
    let rt = try await AccountRuntime.open(
      env: env, binding: binding, enrolled: account.enrolled, build: .current,
      profile: BootController.profileInfo(nil, binding: binding), usesPasskey: { false }, stopped: { _ in },
      bankTextFacts: facts)
    let now = rt.context.clock.nowMs()
    let persistence = LedgerMailboxPersistence(
      store: rt.context.store, authoring: MailboxAuthoring(observer: rt.observer), nowMs: { now })
    let readFrom = now - 5 * 86_400_000
    var state = MailboxState()
    state.phase = .active
    state.watermarkMs = now
    state.readFromMs = readFrom
    var commit = MailboxCommit()
    commit.state = state
    try await persistence.commit(commit)
    server.offline = true
    await rt.lane?.close()
    let domains = MailboxLane.senderDomains(bank: SupportedBank.enbd.rawValue)
    #expect(!domains.isEmpty)

    try await LiveSetupAuthoring(runtime: { rt }).setBanks([.enbd])

    #expect(try await persistence.pendingImports() == domains.map { PendingImport(domain: $0, sinceMs: readFrom) })
    let trustOps = try rt.context.store.pendingOps().filter { $0.opType == "sender_trust_set" }
    #expect(trustOps.count == domains.count)
    await rt.close()
  }
}
