import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct DisconnectPartwayTests {
  @Test(arguments: [MailboxServerError.offline, .refused(500, "server_error")])
  func aServerThatDoesNotDeleteTheLinkLeavesOutlookReading(_ refusal: MailboxServerError) async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let token = try rig.keychain.read()
    await rig.server.setDeleteRefusal(refusal)
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(try rig.keychain.read() == token)
    #expect(try rig.link.read() != nil)
    #expect(rig.graph.subscriptions.isEmpty)
    let left = await rig.state()
    #expect(left.phase == .active && left.watchExpiresAtMs == nil)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-after", dateMs: rig.clock.nowMs() - 1000))
    let cycle = await rig.engine.runCycle(trigger: .refresh)
    #expect(cycle.phase == .active && cycle.ops == 1)
    #expect(rig.graph.subscriptions.count == 1)
    await rig.server.setDeleteRefusal(nil)
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    #expect(try rig.keychain.read() == nil && rig.link.read() == nil)
    #expect(await rig.state().phase == .unlinked)
  }

  @Test func aGrantRevokedBeforeTheLinkCouldBeDeletedCanStillBeDisconnected() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setDeleteRefusal(.offline)
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(await rig.server.deletes == 0)
    #expect(await rig.state().phase == .active)
    rig.gmail.invalidGrant = true
    let cycle = await rig.engine.runCycle(trigger: .launch)
    #expect(cycle.phase == .reconnectRequired)
    await rig.server.setDeleteRefusal(nil)
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    #expect(await rig.server.deletes == 1)
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.state().phase == .unlinked)
  }

  @Test func aRevokeThatFailsLeavesAWatchTheNextCycleCanMakeAgain() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.fail("/revoke", with: [503])
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(await rig.state().watchExpiresAtMs == nil)
    rig.gmail.clearRequests()
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .active)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await rig.state().watchExpiresAtMs != nil)
  }

  func withPlan(_ rig: Rig, total: Int = 7) async throws -> MailboxRetirePlan {
    await rig.connectAndActivate()
    let grant = MailboxEngineConfig(grantID: "00000000-0000-4000-8000-000000000001")
      .grantID(provider: .gmail, address: SyntheticMail.defaultTo)
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: grant, provider: "gmail", legacy: true, total: total, edited: 1))
    return try #require(await rig.engine.retirePlan())
  }

  @Test func aRemovalThatFailsLeavesTheRowSoTheRemovalCanBeAskedForAgain() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    #expect(await rig.server.deletes == 1)
    #expect(try rig.keychain.read() == nil)
    let s = await rig.state()
    #expect(s.phase == .reconnectRequired && s.haltedOn == .reconnectRequired && s.address == SyntheticMail.defaultTo)
    #expect(await rig.engine.retirePlan() == plan)

    await rig.server.setDeleteRefusal(.noLink)
    await rig.ledger.setRetireFails(false)
    #expect(await rig.engine.disconnect(removing: plan) == .removed(7))
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.engine.retirePlan() == nil)
  }

  @Test func aRemovalThatFailsStaysRetryableAfterTheNextCycle() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    let cycle = await rig.engine.runCycle(trigger: .launch)
    #expect(cycle.phase == .reconnectRequired && cycle.ops == 0)
    #expect(await rig.engine.retirePlan() == plan)
    await rig.server.setDeleteRefusal(.noLink)
    await rig.ledger.setRetireFails(false)
    #expect(await rig.engine.disconnect(removing: plan) == .removed(7))
  }

  @Test func aLinkThatCouldNotBeDeletedRemovesNothing() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.server.setDeleteRefusal(.offline)
    #expect(await rig.engine.disconnect(removing: plan) == .failed)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.engine.retirePlan() == plan)
  }

  @Test func aRemovalThatIsWrittenIsSentOnceTheRowIsCleared() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    let flushes = await rig.ledger.flushes
    #expect(await rig.engine.disconnect(removing: plan) == .removed(7))
    #expect(await rig.ledger.flushes == flushes + 1)
    #expect(await rig.ledger.retired == [plan])
  }
}
