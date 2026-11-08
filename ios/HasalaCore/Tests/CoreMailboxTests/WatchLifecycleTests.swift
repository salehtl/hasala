import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct WatchLifecycleTests {
  static let day: Int64 = 86_400_000

  @Test func aWatchPastItsExpiryIsNotShownAsActive() async {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.engine.status().watchActive)
    rig.clock.advance(7 * Self.day - 1)
    #expect(await rig.engine.status().watchActive)
    rig.clock.advance(1)
    #expect(await rig.engine.status().watchActive == false)
  }
}
