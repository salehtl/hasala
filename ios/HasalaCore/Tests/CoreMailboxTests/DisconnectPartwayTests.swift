import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct DisconnectPartwayTests {
  @Test(arguments: [MailboxServerError.offline, .refused(500, "server_error")], [MailboxTrigger.refresh, .launch])
  func aServerThatDoesNotDeleteTheLinkLeavesOutlookReading(_ refusal: MailboxServerError, _ next: MailboxTrigger) async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let token = try rig.keychain.read()
    let made = try #require(await rig.state().watchExpiresAtMs)
    await rig.server.setDeleteRefusal(refusal)
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(try rig.keychain.read() == token)
    #expect(try rig.link.read() != nil)
    #expect(rig.graph.subscriptions.isEmpty)
    #expect(await rig.server.link == .holder(isThisDevice: true, watchExpiresAtMs: made))
    #expect(await rig.state().phase == .active)
    #expect(await !rig.engine.status().watchActive)
    rig.clock.advance(3_600_000)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-after", dateMs: rig.clock.nowMs() - 1000))
    let cycle = await rig.engine.runCycle(trigger: next)
    #expect(cycle.phase == .active && cycle.ops == 1)
    let remade = try #require(rig.graph.subscriptions.first)
    #expect(rig.graph.subscriptions.count == 1 && remade.expiresAtMs != made)
    #expect(await rig.state().watchExpiresAtMs == remade.expiresAtMs)
    #expect(await rig.server.watches.last == remade.expiresAtMs)
    #expect(await rig.engine.status().watchActive)
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

  @Test(arguments: [MailboxTrigger.refresh, .launch, .retry])
  func aRevokeThatFailsLeavesAWatchTheNextCycleCanMakeAgain(_ next: MailboxTrigger) async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let made = try #require(await rig.state().watchExpiresAtMs)
    #expect(await rig.server.link == .holder(isThisDevice: true, watchExpiresAtMs: made))
    rig.gmail.fail("/revoke", with: [503])
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(await rig.server.link == .holder(isThisDevice: true, watchExpiresAtMs: made))
    #expect(await !rig.engine.status().watchActive)
    rig.gmail.clearRequests()
    let remade = made + 86_400_000
    rig.gmail.watchExpirationMs = remade
    #expect(await rig.engine.runCycle(trigger: next).phase == .active)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await rig.state().watchExpiresAtMs == remade)
    #expect(await rig.server.watches.last == remade)
    #expect(await rig.engine.status().watchActive)
  }

  @Test func theRowGivesUpItsWatchBeforeTheStopGoesOut() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let made = try #require(await rig.state().watchExpiresAtMs)
    let tables = rig.tables
    rig.gmail.limiter = { path in
      if path.hasSuffix("/stop") { #expect((try? tables.loadState())?.watchExpiresAt != made) }
      return nil
    }
    rig.gmail.fail("/revoke", with: [503])
    #expect(await rig.engine.disconnect(removing: nil) == .failed)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/stop") })
  }

  @Test func aRowThatLostItsWatchStillTakesTheServersExpiry() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let made = try #require(await rig.state().watchExpiresAtMs)
    var lost = await rig.state()
    lost.watchExpiresAtMs = nil
    var commit = MailboxCommit()
    commit.state = lost
    try await rig.store.commit(commit)
    rig.gmail.clearRequests()
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .active)
    #expect(await rig.state().watchExpiresAtMs == made)
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
  }

  func withPlan(_ rig: Rig, total: Int = 7) async throws -> MailboxRetirePlan {
    await rig.connectAndActivate()
    let grant = MailboxEngineConfig(grantID: "00000000-0000-4000-8000-000000000001")
      .grantID(provider: .gmail, address: SyntheticMail.defaultTo)
    await rig.ledger.setPlan(MailboxRetirePlan(grantID: grant, provider: "gmail", legacy: true, total: total, edited: 1))
    return try #require(await rig.engine.retirePlan())
  }

  @Test func aRemovalThatFailsIsKeptOnThePhoneUntilItIsTriedAgain() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    #expect(plan.address == SyntheticMail.defaultTo)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    #expect(await rig.server.deletes == 1)
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.engine.retirePlan() == nil)
    #expect(await rig.engine.heldRetires() == [plan])
    #expect(await rig.engine.status().heldRetires == [plan])
    #expect(try await rig.store.pendingRetires().isEmpty)

    #expect(await rig.engine.retryHeld(plan) == .failed)
    #expect(await rig.engine.heldRetires() == [plan])

    await rig.ledger.setRetireFails(false)
    let flushes = await rig.ledger.flushes
    #expect(await rig.engine.retryHeld(plan) == .removed(7))
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.ledger.flushes == flushes + 1)
    #expect(await rig.engine.heldRetires().isEmpty)
    #expect(await rig.engine.retryHeld(plan) == .removed(7))
    #expect(await rig.ledger.retired == [plan])
  }

  @Test func aKeptRemovalOutlivesARestartAndNoCycleTriesIt() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    await rig.ledger.setRetireFails(false)
    let restarted = rig.restarted()
    _ = await restarted.runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await restarted.heldRetires() == [plan])
    #expect(await restarted.retryHeld(plan) == .removed(7))
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.restarted().heldRetires().isEmpty)
  }

  @Test func keepThemDropsTheKeptRemoval() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    await rig.ledger.setRetireFails(false)
    await rig.engine.dropHeld(plan)
    #expect(await rig.engine.heldRetires().isEmpty)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func twoTapsOnRemoveThemAuthorTheRemovalOnce() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    await rig.ledger.setRetireFails(false)
    let gate = Gate()
    await rig.ledger.setRetireGate { await gate.pass() }
    let first = Task { await rig.engine.retryHeld(plan) }
    for _ in 0..<100_000 where !gate.reached { await Task.yield() }
    #expect(gate.reached)
    let second = Task { await rig.engine.retryHeld(plan) }
    await rig.ledger.setRetireGate(nil)
    gate.open()
    #expect(await first.value == .removed(7))
    #expect(await second.value == .removed(7))
    #expect(await rig.ledger.retired == [plan])
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aKeptRemovalEndsWhenThatMailboxIsConnectedAgain(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    let plan = try await withPlan(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    await rig.ledger.setRetireFails(false)
    #expect(try await rig.store.heldRetires() == [plan])
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
      == .connected(address: SyntheticMail.defaultTo))
    #expect(try await rig.store.heldRetires().isEmpty)
    #expect(await rig.engine.status().heldRetires.isEmpty)
    _ = await rig.engine.retryHeld(plan)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    #expect(await rig.engine.heldRetires().isEmpty)
  }

  @Test func aKeptRemovalOfTheMailboxLinkedNowIsNotOfferedOrWritten() async throws {
    let rig = Rig()
    let plan = try await withPlan(rig)
    var held = MailboxCommit()
    held.holdRetire = plan
    try await rig.store.commit(held)
    #expect(try await rig.store.heldRetires() == [plan])
    #expect(await rig.engine.heldRetires().isEmpty)
    #expect(await rig.engine.status().heldRetires.isEmpty)
    #expect(await rig.engine.retryHeld(plan) == .failed)
    #expect(await rig.ledger.retired.isEmpty)
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
