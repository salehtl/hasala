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

  @Test func aSubscriptionTheServerCouldNotRecordIsExtendedAndNotMadeAgain() async throws {
    let rig = OutlookRig()
    await rig.server.setWatchRefusal(.offline)
    await rig.connectAndActivate()
    let first = try #require(rig.graph.subscriptions.first)
    #expect(await rig.server.watches.isEmpty)
    #expect(await rig.state().watchExpiresAtMs == nil)

    await rig.server.setWatchRefusal(nil)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.graph.subscriptions.map(\.id) == [first.id])
    #expect(rig.subscriptionRequests("POST").count == 1)
    #expect(rig.subscriptionRequests("DELETE").isEmpty)
    #expect(rig.subscriptionRequests("PATCH").count == 1)
    #expect(await rig.server.watches.count == 1)
    #expect(await rig.state().watchExpiresAtMs != nil)
    #expect(try rig.link.read()?.subscriptionID == first.id)
  }

  @Test func anUnrecordedSubscriptionGraphLostIsMadeAgain() async throws {
    let rig = OutlookRig()
    await rig.server.setWatchRefusal(.offline)
    await rig.connectAndActivate()
    let first = try #require(rig.graph.subscriptions.first?.id)
    try await GraphClient(http: rig.graph, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 }).deleteSubscription(id: first)

    await rig.server.setWatchRefusal(nil)
    _ = await rig.engine.runCycle(trigger: .refresh)
    let now = try #require(rig.graph.subscriptions.first)
    #expect(now.id != first && rig.graph.subscriptions.count == 1)
    #expect(try rig.link.read()?.subscriptionID == now.id)
    #expect(await rig.server.watches.count == 1)
  }

  @Test func aSubscriptionWhoseIDCouldNotBeKeptIsRemovedAndMadeAgainLater() async throws {
    let rig = OutlookRig()
    _ = await rig.connect()
    rig.link.writesFail = true
    _ = await rig.engine.runCycle(trigger: .launch)
    #expect(rig.graph.subscriptions.isEmpty)
    #expect(await rig.server.watches.isEmpty)
    #expect(await rig.state().watchExpiresAtMs == nil)

    rig.link.writesFail = false
    _ = await rig.engine.runCycle(trigger: .refresh)
    let made = try #require(rig.graph.subscriptions.first)
    #expect(rig.graph.subscriptions.count == 1)
    #expect(try rig.link.read()?.subscriptionID == made.id)
    #expect(await rig.server.watches.count == 1)
  }
}
