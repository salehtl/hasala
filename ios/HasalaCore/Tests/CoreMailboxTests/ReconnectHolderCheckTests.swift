import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct ReconnectHolderCheckTests {
  func waitingForSignIn(_ rig: Rig, lastCheckAtMs: Int64? = nil, detail: String? = nil) async throws {
    await rig.connectAndActivate()
    var s = await rig.state()
    s.phase = .reconnectRequired
    s.haltedOn = .reconnectRequired
    s.haltedDetail = detail
    s.lastHolderCheckAtMs = lastCheckAtMs
    var c = MailboxCommit()
    c.state = s
    try await rig.store.commit(c)
  }

  @Test func aPhoneWaitingForASignInLearnsAnotherIPhoneHoldsTheLink() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig, detail: "resume:authoring_backfill")
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice && r.haltedOn == .notHolder && r.ops == 0)
    let s = await rig.state()
    #expect(s.phase == .otherDevice && s.haltedOn == .notHolder && s.haltedDetail == "resume:authoring_backfill")
    #expect(try rig.keychain.read() == nil)
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/revoke") })
    #expect(await rig.engine.status().hero == .otherDevice)
  }

  @Test func aPhoneWaitingForASignInAsksAgainOnlyWhenTheCheckIsDue() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig, lastCheckAtMs: Rig.t0)
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    #expect(await rig.engine.runCycle(trigger: .silentPush).phase == .reconnectRequired)
    rig.clock.advance(11 * 60_000)
    #expect(await rig.engine.runCycle(trigger: .silentPush).phase == .otherDevice)
  }

  @Test(arguments: [MailboxLinkStatus.holder(isThisDevice: true, watchExpiresAtMs: nil), .noLink])
  func aPhoneWaitingForASignInKeepsWaitingWhileNoOtherIPhoneHoldsTheLink(_ link: MailboxLinkStatus) async throws {
    let rig = Rig()
    try await waitingForSignIn(rig)
    let before = await rig.state()
    await rig.server.setLink(link)
    rig.clock.advance(60_000)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired && r.haltedOn == nil)
    var expected = before
    expected.lastHolderCheckAtMs = rig.clock.nowMs()
    #expect(await rig.state() == expected)
    #expect(try rig.keychain.read() != nil)
  }

  @Test func aPhoneWaitingForASignInThatCannotReachTheServerChangesNothing() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig)
    let before = await rig.state()
    await rig.server.setOffline(true)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired && r.haltedOn == .offline)
    #expect(await rig.state() == before)
    #expect(try rig.keychain.read() != nil)
  }

  @Test func aPhoneWaitingForASignInLeavesALinkAnotherIPhoneMovedToTheOtherProvider() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig)
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    await rig.server.setLinkProvider(.outlook)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice && r.haltedOn == .notHolder)
    let s = await rig.state()
    #expect(s.phase == .otherDevice && s.address == nil && s.watermarkMs == nil)
    #expect(try rig.keychain.read() == nil)
  }

  @Test func aPhoneWaitingForASignInStopsWhenItMovedTheLinkToTheOtherProvider() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig)
    let before = await rig.state()
    await rig.server.setLinkProvider(.outlook)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired && r.haltedOn == nil)
    #expect(await rig.engine.stopped)
    #expect(await rig.state() == before)
  }

  @Test func aPhoneWaitingForASignInThatCannotAskWhoHoldsTheOtherProvidersLinkChangesNothing() async throws {
    let rig = Rig()
    try await waitingForSignIn(rig)
    let before = await rig.state()
    await rig.server.setLinkProvider(.outlook)
    await rig.server.setOffline(true)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired && r.haltedOn == .offline)
    #expect(await !rig.engine.stopped)
    #expect(await rig.state() == before)
  }
}
