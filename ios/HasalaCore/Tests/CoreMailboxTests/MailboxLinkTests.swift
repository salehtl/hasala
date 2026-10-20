import CoreTestSupport
import Foundation
import Testing

@testable import CoreMailbox

@Suite struct PendingImportTests {
  let day: Int64 = 86_400_000

  func activeWithENBDTrusted(_ rig: Rig) async {
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    await rig.ledger.setTrust(["dib.ae": true, "emiratesnbd.com": true])
  }

  @Test func aBackfillReadsEveryListingPage() async throws {
    let rig = Rig()
    rig.gmail.pageSize = 2
    await activeWithENBDTrusted(rig)
    for i in 0..<15 { rig.gmail.add(SyntheticMail.enbdAlert(id: "old\(i)", dateMs: rig.clock.nowMs() - Int64(i + 10) * day)) }
    let r = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    #expect(r.ops == 15 && r.listed == 15 && r.completed)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func aBackfillCutOfflineIsFinishedByALaterCycle() async throws {
    let rig = Rig()
    await activeWithENBDTrusted(rig)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "old", dateMs: rig.clock.nowMs() - 20 * day))
    let before = await rig.state().watermarkMs
    rig.gmail.offline = true
    let r = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    #expect(!r.completed && r.ops == 0)
    #expect(try await rig.store.pendingImports().map(\.domain) == ["emiratesnbd.com"])
    rig.gmail.offline = false
    rig.clock.advance(60_000)
    let cycle = await rig.engine.runCycle(trigger: .refresh)
    #expect(cycle.ops == 1 && cycle.completed)
    #expect(await rig.accounted("old") == .op)
    #expect(try await rig.store.pendingImports().isEmpty)
    #expect(await rig.state().watermarkMs ?? 0 >= before ?? 0)
  }

  @Test func aSenderAddedWhileHaltedIsImportedOnceTheLaneRunsAgain() async throws {
    let rig = Rig()
    await activeWithENBDTrusted(rig)
    var s = await rig.state()
    s.phase = .halted
    s.haltedOn = .gmail
    var c = MailboxCommit()
    c.state = s
    try await rig.store.commit(c)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "old", dateMs: rig.clock.nowMs() - 40 * day))
    let r = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    #expect(r.ops == 0 && !r.completed)
    #expect(try await rig.store.pendingImports().count == 1)
    let retry = await rig.engine.runCycle(trigger: .retry)
    #expect(retry.phase == .active && retry.ops == 1)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func aPendingImportOfASenderNoLongerTrustedIsDropped() async throws {
    let rig = Rig()
    await activeWithENBDTrusted(rig)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "old", dateMs: rig.clock.nowMs() - 20 * day))
    rig.gmail.offline = true
    _ = await rig.engine.backfill(senders: ["emiratesnbd.com"])
    rig.gmail.offline = false
    await rig.ledger.setTrust(["dib.ae": true, "emiratesnbd.com": false])
    rig.clock.advance(60_000)
    let cycle = await rig.engine.runCycle(trigger: .refresh)
    #expect(cycle.ops == 0)
    #expect(await rig.accounted("old") == nil)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func pendingImportsKeepTheEarliestStartAndADisconnectClearsThem(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    var c = MailboxCommit()
    c.addImports = [PendingImport(domain: "dib.ae", sinceMs: 2_000), PendingImport(domain: "emiratesnbd.com", sinceMs: 5_000)]
    try await rig.store.commit(c)
    c = MailboxCommit()
    c.addImports = [PendingImport(domain: "dib.ae", sinceMs: 9_000), PendingImport(domain: "emiratesnbd.com", sinceMs: 1_000)]
    try await rig.store.commit(c)
    #expect(
      try await rig.store.pendingImports()
        == [PendingImport(domain: "dib.ae", sinceMs: 2_000), PendingImport(domain: "emiratesnbd.com", sinceMs: 1_000)])
    c = MailboxCommit()
    c.doneImports = ["dib.ae"]
    try await rig.store.commit(c)
    #expect(try await rig.store.pendingImports().map(\.domain) == ["emiratesnbd.com"])
    c = MailboxCommit()
    c.clearAll = true
    try await rig.store.commit(c)
    #expect(try await rig.store.pendingImports().isEmpty)
  }
}

@Suite struct LinkHeldElsewhereTests {
  func revokes(_ rig: Rig) -> Int { rig.gmail.requests.filter { $0.path.hasSuffix("/revoke") }.count }

  @Test func disconnectOnAnIPhoneThatLostTheLinkLeavesTheHoldersLinkAlone() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.gmail.clearRequests()
    let outcome = await rig.engine.disconnect(removing: nil)
    #expect(outcome == .otherDevice)
    #expect(await rig.server.deletes == 0)
    #expect(!rig.stepUps.kinds.contains("mailbox.unlink"))
    #expect(revokes(rig) == 0)
    #expect(try rig.keychain.read() == nil)
    let s = await rig.state()
    #expect(s.phase == .otherDevice && s.haltedOn == .notHolder)
  }

  @Test func disconnectAfterTheLinkMovedToTheOtherProviderLeavesItAlone() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    await rig.server.setLinkProvider(.outlook)
    rig.gmail.clearRequests()
    #expect(await !rig.engine.disconnect())
    #expect(await rig.server.deletes == 0)
    #expect(revokes(rig) == 0)
    #expect(await rig.state().phase == .otherDevice)
  }

  @Test func disconnectOnTheHolderStillEndsTheLink() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.engine.disconnect(removing: nil) == .disconnected)
    #expect(await rig.server.deletes == 1)
    #expect(rig.stepUps.kinds.contains("mailbox.unlink"))
    #expect(await rig.state().phase == .unlinked)
  }

  @Test func aLinkAnotherIPhoneMovedToTheOtherProviderEndsThisLaneHere() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "early", dateMs: Rig.t0 - 86_400_000))
    await rig.connectAndActivate()
    #expect(await rig.accountedCount() > 0)
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    await rig.server.setLinkProvider(.outlook)
    rig.gmail.clearRequests()
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == .notHolder && r.phase == .otherDevice && r.ops == 0)
    #expect(await !rig.engine.stopped)
    #expect(revokes(rig) == 0)
    #expect(try rig.keychain.read() == nil)
    let s = await rig.state()
    #expect(s.phase == .otherDevice && s.address == nil && s.watermarkMs == nil)
    #expect(await rig.accountedCount() == 0)
    #expect(await rig.engine.status().hero == .otherDevice)
  }

  @Test func aLinkThisIPhoneMovedToTheOtherProviderStopsThisLaneWithoutWriting() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state()
    await rig.server.setLinkProvider(.outlook)
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == nil && r.ops == 0)
    #expect(await rig.engine.stopped)
    #expect(await rig.state() == before)
  }

  func takenOver(_ rig: Rig) async {
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice)
  }

  @Test func anIPhoneThatLostTheLinkCanConnectAgainOnceTheHolderDisconnects() async {
    let rig = Rig()
    await takenOver(rig)
    await rig.server.setLink(.noLink)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .unlinked)
    #expect(await rig.state() == MailboxState())
    #expect(await rig.accountedCount() == 0)
    #expect(await rig.engine.status().hero == .notConnected)
  }

  @Test func anIPhoneThatLostTheLinkWaitsForTheCheckIntervalBetweenChecks() async {
    let rig = Rig()
    await takenOver(rig)
    await rig.server.setLink(.noLink)
    rig.clock.advance(60_000)
    #expect(await rig.engine.runCycle(trigger: .foreground).phase == .otherDevice)
    rig.clock.advance(await rig.engine.config.holderCheckIntervalMs)
    #expect(await rig.engine.runCycle(trigger: .foreground).phase == .unlinked)
  }

  @Test func anIPhoneThatLostTheLinkStaysElsewhereWhileAnotherIPhoneHoldsIt() async {
    let rig = Rig()
    await takenOver(rig)
    await rig.server.setLinkProvider(.outlook)
    #expect(await rig.engine.runCycle(trigger: .retry).phase == .otherDevice)
    await rig.server.setLinkProvider(nil)
    #expect(await rig.engine.runCycle(trigger: .retry).phase == .otherDevice)
  }

  @Test func anIPhoneThatHoldsTheLinkAgainLeavesTheOtherDeviceState() async {
    let rig = Rig()
    await takenOver(rig)
    await rig.server.setLink(.holder(isThisDevice: true, watchExpiresAtMs: nil))
    let r = await rig.engine.runCycle(trigger: .retry)
    #expect(r.phase == .reconnectRequired && r.haltedOn == .reconnectRequired)
  }
}

@Suite struct OutlookLinkItemTests {
  @Test func theLinkItemKeepsTheSubscriptionResource() {
    let state = OutlookLinkState(
      clientState: OutlookServer.clientState, subscriptionID: "sub-1", subscriptionResource: GraphClient.subscriptionResource)
    #expect(OutlookLinkState(bytes: state.bytes) == state)
    let older = OutlookLinkState(clientState: OutlookServer.clientState, subscriptionID: "sub-1")
    #expect(OutlookLinkState(bytes: older.bytes)?.subscriptionResource == nil)
  }
}
