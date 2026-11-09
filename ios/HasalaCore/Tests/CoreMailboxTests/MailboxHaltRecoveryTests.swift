import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct MailboxHaltRecoveryTests {
  func halted(_ rig: Rig, on code: MailboxHaltCode) async throws {
    await rig.connectAndActivate()
    var s = await rig.state()
    s.phase = .halted
    s.haltedOn = code
    var c = MailboxCommit()
    c.state = s
    try await rig.store.commit(c)
  }

  @Test(arguments: [MailboxTrigger.launch, .foreground, .silentPush])
  func aHaltOnMissingTemplatesEndsOnceTheyAreBack(_ trigger: MailboxTrigger) async throws {
    let rig = Rig()
    try await halted(rig, on: .templatesUnavailable)
    rig.clock.advance(3_600_000)
    rig.gmail.historyID = "1001"
    rig.gmail.add(SyntheticMail.dibCard(id: "after", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: trigger)
    #expect(r.phase == .active && r.haltedOn == nil && r.ops == 1 && r.completed, "\(r)")
    let s = await rig.state()
    #expect(s.phase == .active && s.haltedOn == nil)
  }

  @Test func aHaltOnMissingTemplatesStaysWhileTheyAreStillMissing() async {
    let rig = Rig(templates: [])
    await rig.connectAndActivate()
    #expect(await rig.state().haltedOn == .templatesUnavailable)
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .halted && r.haltedOn == .templatesUnavailable)
    #expect(rig.gmail.requests.isEmpty)
  }

  @Test func aHaltOnARefusalStillWaitsForTryAgain() async throws {
    let rig = Rig()
    try await halted(rig, on: .gmail)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .halted && r.haltedOn == .gmail)
    #expect(await rig.engine.runCycle(trigger: .retry).phase == .active)
  }
}
