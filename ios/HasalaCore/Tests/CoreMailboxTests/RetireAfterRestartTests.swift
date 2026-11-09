import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct RetireAfterRestartTests {
  let helper = GmailAddressSwitchTests()

  func reach(_ gate: Gate) async {
    for _ in 0..<100_000 where !gate.reached { await Task.yield() }
    #expect(gate.reached)
  }

  func diedDuringRemove(_ rig: Rig) async throws -> (MailboxRetirePlan, Gate, Task<ConnectResult, Never>) {
    await helper.signedOutWithImports(rig, total: 7, edited: 2)
    let plan = try #require(await rig.engine.retirePlan())
    let gate = Gate()
    await rig.ledger.setRetireGate { await gate.pass() }
    let connecting = Task { await helper.connect(rig, SwitchAsks(.remove)) }
    await reach(gate)
    await rig.ledger.setRetireGate(nil)
    return (plan, gate, connecting)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aRemoveConfirmedBeforeTheAppDiedIsFinishedAfterTheRestart(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    let (plan, gate, connecting) = try await diedDuringRemove(rig)
    let flushes = await rig.ledger.flushes
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.ledger.flushes > flushes)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired == [plan])
    gate.open()
    _ = await connecting.value
  }

  @Test func aRetryThatFailsIsTriedAgainOnTheNextCycle() async throws {
    let rig = Rig()
    let (plan, gate, connecting) = try await diedDuringRemove(rig)
    await rig.ledger.setRetireFails(true)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
    await rig.ledger.setRetireFails(false)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired == [plan])
    gate.open()
    _ = await connecting.value
  }

  @Test func aDisconnectThatDiedAfterTheLinkWasDeletedFinishesItsRemove() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let grant = MailboxEngineConfig(grantID: helper.account).grantID(provider: .gmail, address: helper.old)
    let plan = MailboxRetirePlan(grantID: grant, provider: "gmail", legacy: true, total: 4, edited: 0)
    let gate = Gate()
    await rig.ledger.setRetireGate { await gate.pass() }
    let disconnecting = Task { await rig.engine.disconnect(removing: plan) }
    await reach(gate)
    await rig.ledger.setRetireGate(nil)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired == [plan])
    gate.open()
    _ = await disconnecting.value
  }

  let otherLane = MailboxRetirePlan(grantID: "00000000-0000-4000-8000-000000000001/mbx-other", provider: "outlook", legacy: false, total: 3, edited: 0)

  func connectedReplacing(_ rig: Rig) async {
    let r = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, replacing: true, retiring: otherLane)
    #expect(r == .connected(address: SyntheticMail.defaultTo))
  }

  @Test func aProviderSwitchThatDiedBeforeItsRemoveFinishesItAfterTheRestart() async throws {
    let rig = Rig()
    await connectedReplacing(rig)
    #expect(try await rig.store.pendingRetires() == [otherLane])
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired == [otherLane])
    #expect(try await rig.store.pendingRetires().isEmpty)
  }

  @Test func aRemoveTheCycleFinishedIsNotAuthoredAgainByTheConnect() async throws {
    let rig = Rig()
    await connectedReplacing(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    #expect(await rig.engine.retire(otherLane) == .removed(3))
    #expect(await rig.ledger.retired == [otherLane])
  }

  @Test func aCycleLeavesARemoveThatIsRunningToItsOwner() async throws {
    let rig = Rig()
    await connectedReplacing(rig)
    let gate = Gate()
    await rig.ledger.setRetireGate { await gate.pass() }
    let retiring = Task { await rig.engine.retire(otherLane) }
    await reach(gate)
    await rig.ledger.setRetireGate(nil)
    _ = await rig.engine.runCycle(trigger: .launch)
    gate.open()
    #expect(await retiring.value == .removed(3))
    #expect(await rig.ledger.retired == [otherLane])
    #expect(try await rig.store.pendingRetires().isEmpty)
  }

  @Test func aRemoveThePersonWasToldFailedIsNotDoneLater() async throws {
    let rig = Rig()
    await helper.signedOutWithImports(rig)
    await rig.ledger.setRetireFails(true)
    #expect(
      await helper.connect(rig, SwitchAsks(.remove))
        == .connected(address: helper.other, anotherAddress: true, retired: .failed))
    #expect(try await rig.store.pendingRetires().isEmpty)
    await rig.ledger.setRetireFails(false)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aSwitchTheServerRefusedRecordsNoRemove() async throws {
    let rig = Rig()
    await helper.signedOutWithImports(rig)
    await rig.server.setLinkRefusal(.refused(409, "mailbox_in_use"))
    #expect(await helper.connect(rig, SwitchAsks(.remove)) == .failed(.mailboxInUse))
    #expect(try await rig.store.pendingRetires().isEmpty)
  }

  @Test func aSwitchThatFailsAfterTheLinkMovedRecordsNoRemove() async throws {
    let rig = Rig()
    await helper.signedOutWithImports(rig)
    let puts = await rig.server.puts.count
    rig.keychain.locked = true
    #expect(await helper.connect(rig, SwitchAsks(.remove)) == .failed(.keychain))
    rig.keychain.locked = false
    #expect(await rig.server.puts.count == puts + 1)
    #expect(try await rig.store.pendingRetires().isEmpty)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aDisconnectThatStopsBeforeTheDeleteRecordsNoRemove() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let plan = try #require(await rig.engine.retirePlan())
    await rig.server.setDeleteRefusal(.refused(500, "server_error"))
    #expect(await rig.engine.disconnect(removing: plan) == .failed)
    #expect(try await rig.store.pendingRetires().isEmpty)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aRemoveThePersonWasToldFailedOnDisconnectIsNotDoneLater() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let plan = try #require(await rig.engine.retirePlan())
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.disconnect(removing: plan) == .disconnectedRemoveFailed)
    #expect(try await rig.store.pendingRetires().isEmpty)
  }

  @Test func aFinishedDisconnectLeavesNoRemoveBehind() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let plan = try #require(await rig.engine.retirePlan())
    #expect(await rig.engine.disconnect(removing: plan) == .removed(0))
    #expect(try await rig.store.pendingRetires().isEmpty)
    #expect(await rig.ledger.retired == [plan])
  }
}

@Suite struct RetireNotRecordedTests {
  let helper = GmailAddressSwitchTests()
  let otherLane = MailboxRetirePlan(grantID: "00000000-0000-4000-8000-000000000001/mbx-other", provider: "outlook", legacy: false, total: 3, edited: 0)

  func rigThatCannotRecord() async throws -> Rig {
    var wrapped: UnreadableStateStore?
    let rig = Rig(wrapStore: { base in
      let store = UnreadableStateStore(base)
      wrapped = store
      return store
    })
    try await #require(wrapped).setRetireWriteFails(true)
    return rig
  }

  func connectedReplacing(_ rig: Rig) async throws {
    let r = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, replacing: true, retiring: otherLane)
    #expect(r == .connected(address: SyntheticMail.defaultTo))
    #expect(try await rig.store.pendingRetires().isEmpty)
  }

  @Test func anAddressSwitchWhoseRemoveCouldNotBeRecordedStillRemoves() async throws {
    let rig = try await rigThatCannotRecord()
    await helper.signedOutWithImports(rig, total: 7, edited: 2)
    let plan = try #require(await rig.engine.retirePlan())
    let flushes = await rig.ledger.flushes
    #expect(
      await helper.connect(rig, SwitchAsks(.remove))
        == .connected(address: helper.other, anotherAddress: true, retired: .removed(7)))
    #expect(await rig.ledger.retired == [plan])
    #expect(await rig.ledger.flushes > flushes)
  }

  @Test func aProviderSwitchWhoseRemoveCouldNotBeRecordedStillRemovesOnce() async throws {
    let rig = try await rigThatCannotRecord()
    try await connectedReplacing(rig)
    #expect(await rig.engine.retire(otherLane) == .removed(3))
    #expect(await rig.ledger.retired == [otherLane])
    #expect(await rig.engine.retire(otherLane) == .removed(3))
    #expect(await rig.ledger.retired == [otherLane])
  }

  @Test func aCycleBeforeTheRemoveDoesNotCountAsFinishingIt() async throws {
    let rig = try await rigThatCannotRecord()
    try await connectedReplacing(rig)
    _ = await rig.engine.runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
    #expect(await rig.engine.retire(otherLane) == .removed(3))
    #expect(await rig.ledger.retired == [otherLane])
  }

  @Test func aRemoveThatCouldNotBeRecordedAndThenFailsSaysItFailed() async throws {
    let rig = try await rigThatCannotRecord()
    try await connectedReplacing(rig)
    await rig.ledger.setRetireFails(true)
    #expect(await rig.engine.retire(otherLane) == .failed)
    await rig.ledger.setRetireFails(false)
    _ = await rig.restarted().runCycle(trigger: .launch)
    #expect(await rig.ledger.retired.isEmpty)
  }

  @Test func aDisconnectWhoseRemoveCouldNotBeRecordedStillRemoves() async throws {
    let rig = try await rigThatCannotRecord()
    await rig.connectAndActivate()
    let plan = try #require(await rig.engine.retirePlan())
    #expect(await rig.engine.disconnect(removing: plan) == .removed(plan.total))
    #expect(await rig.ledger.retired == [plan])
  }
}
