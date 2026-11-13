import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct MessageStrikeTests {
  @Test(arguments: [Backend.sqlite, .memory])
  func aMessageThatKeepsFailingIsSkippedAcrossRestarts(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "empty", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/empty?format=raw", with: Array(repeating: 200, count: 9))
    let r1 = await rig.restarted().runCycle(trigger: .refresh)
    #expect(r1.haltedOn == .gmail && !r1.completed)
    let r2 = await rig.restarted().runCycle(trigger: .refresh)
    #expect(r2.haltedOn == .gmail && !r2.completed)
    let r3 = await rig.restarted().runCycle(trigger: .refresh)
    #expect(r3.completed && r3.unreadable == 1)
    #expect(await rig.accounted("empty") == .unreadable)
    #expect(await rig.unreadableReasons() == [.undecodable])
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aRefusedMessageIsSkippedAcrossRestarts(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "odd", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/odd", with: [400, 400, 400])
    #expect(await rig.restarted().runCycle(trigger: .refresh).phase == .halted)
    #expect(await rig.restarted().runCycle(trigger: .retry).phase == .halted)
    let r = await rig.restarted().runCycle(trigger: .retry)
    #expect(r.phase == .active && r.completed && r.unreadable == 1)
    #expect(await rig.unreadableReasons() == [.refused])
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aMessageThatRecoversStartsItsCountAgain(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "blip", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/blip", with: [400])
    #expect(await rig.restarted().runCycle(trigger: .refresh).phase == .halted)
    let r = await rig.restarted().runCycle(trigger: .retry)
    #expect(r.completed && r.ops == 1 && r.unreadable == 0)
    #expect(await rig.accounted("blip") == .op)
    let held = (try? await rig.store.strikes(messageID: "blip")) ?? -1
    #expect(held == 0)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aDisconnectForgetsTheCounts(_ backend: Backend) async {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "odd", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/odd", with: [400])
    #expect(await rig.engine.runCycle(trigger: .refresh).phase == .halted)
    #expect(((try? await rig.store.strikes(messageID: "odd")) ?? 0) == 1)
    #expect(await rig.engine.disconnect())
    #expect(((try? await rig.store.strikes(messageID: "odd")) ?? -1) == 0)
  }
}
