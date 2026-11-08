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

  @Test func theCheckStillWaitsForTheIntervalWhenTheClockIsSteady() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    rig.clock.advance(60_000)
    #expect(await rig.engine.runCycle(trigger: .foreground).phase == .active)
  }
}
