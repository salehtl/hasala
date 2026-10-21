import CoreJSON
import CoreMailbox
import CoreStore
import CoreTestSupport
import Foundation
import Testing

@Suite struct UnparsedSenderTests {
  @Test(arguments: [Backend.sqlite, .memory])
  func anUnparsedEmailKeepsItsSenderDomainOnTheDeviceOnly(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 2 * day))
    rig.gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: Rig.t0 - day))
    await rig.connectAndActivate()
    #expect(try await rig.store.unparsedSenders() == ["n1": "emiratesnbd.com"])
    let byID = Dictionary(uniqueKeysWithValues: await rig.enqueued().map { ($0.messageID, $0) })
    let n1 = try #require(byID["n1"])
    #expect(n1.payload["unparsed"] == .bool(true) && n1.payload["bank"] == nil)
    #expect(!String(decoding: JSONWriter().bytes(.object(n1.payload)), as: UTF8.self).contains("emiratesnbd"))
    #expect(await rig.engine.status().unparsedSenders == ["n1": "emiratesnbd.com"])

    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.bankNotice(id: "n2", dateMs: rig.clock.nowMs() - 60_000))
    rig.gmail.add(SyntheticMail.dibCard(id: "d2", amount: "10.00", dateMs: rig.clock.nowMs() - 30_000))
    rig.gmail.historyID = "1001"
    #expect(await rig.engine.runCycle(trigger: .silentPush).ops == 2)
    #expect(try await rig.store.unparsedSenders() == ["n1": "emiratesnbd.com", "n2": "emiratesnbd.com"])
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func anInterruptedParseFallsBackToTheFromDomain(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "crashed", dateMs: rig.clock.nowMs() - 60_000))
    rig.gmail.historyID = "1001"
    try await rig.store.markParsing("crashed")
    _ = await rig.engine.runCycle(trigger: .silentPush)
    #expect(try await rig.store.unparsedSenders() == ["crashed": "dib.ae"])
  }

  @Test func theTableKeepsTheNewestThousandAndSurvivesADisconnect() throws {
    let t = try MailboxTableStore.inMemory()
    var w = MailboxWrite()
    w.unparsedSenders = (0..<1_005).map { MailboxUnparsedSenderRow(messageID: "m\($0)", domain: "dib.ae", at: Int64($0)) }
    try t.commit(w)
    let kept = try t.unparsedSenders()
    #expect(kept.count == MailboxTableStore.unparsedSenderRing && kept["m4"] == nil && kept["m5"] == "dib.ae")
    var clear = MailboxWrite()
    clear.clearAll = true
    try t.commit(clear)
    #expect(try t.unparsedSenders().count == MailboxTableStore.unparsedSenderRing)
  }
}
