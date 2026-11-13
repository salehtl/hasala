import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct HolderCheckCadenceTests {
  @Test func aClockThatWentBackDoesNotPostponeTheCheck() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.clock.set(Rig.t0 - 3_600_000)
    #expect(await rig.engine.runCycle(trigger: .foreground).phase == .otherDevice)
  }

  @Test(arguments: [MailboxTrigger.refresh, .launch, .retry])
  func aLinkThatCameBackIsAskedAboutOnceInTheCycle(_ trigger: MailboxTrigger) async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.clock.advance(11 * 60_000)
    #expect(await rig.engine.runCycle(trigger: .refresh).phase == .otherDevice)
    var parked = await rig.state()
    parked.watchExpiresAtMs = nil
    var c = MailboxCommit()
    c.state = parked
    try? await rig.store.commit(c)
    let watch = Rig.t0 + 86_400_000
    await rig.server.setLink(.holder(isThisDevice: true, watchExpiresAtMs: watch))
    rig.clock.advance(11 * 60_000)
    let reads = await rig.server.linkStatusReads
    _ = await rig.engine.runCycle(trigger: trigger)
    #expect(await rig.server.linkStatusReads == reads + 1)
    let s = await rig.state()
    #expect(s.lastHolderCheckAtMs == rig.clock.nowMs())
    #expect(s.watchExpiresAtMs == watch)
  }

  @Test func theCheckStillWaitsForTheIntervalWhenTheClockIsSteady() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.clock.advance(60_000)
    #expect(await rig.engine.runCycle(trigger: .foreground).phase == .active)
  }

  @Test(arguments: [false, true])
  func aLaneTheLinkDoesNotNameTouchesNothingOnTheFirstCycleAfterAConnect(_ replacing: Bool) async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 86_400_000))
    #expect(
      await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, replacing: replacing)
        == .connected(address: SyntheticMail.defaultTo))
    let row = await rig.state()
    await rig.server.setLinkProvider(.outlook)
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.ops == 0 && r.staged == 0)
    #expect(await rig.engine.stopped)
    #expect(rig.listRequests.isEmpty)
    #expect(await rig.state() == row)
  }

  @Test func theLaneTheLinkNamesRunsItsFirstCycleAfterAConnect() async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 86_400_000))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.phase == .active && r.ops == 1)
    #expect(await rig.state().lastHolderCheckAtMs == Rig.t0)
  }
}
