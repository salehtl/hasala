import CoreJSON
import CoreMailbox
import CoreStore
import CoreTestSupport
import Foundation
import Testing

@Suite struct InterruptedParseTests {
  @Test(arguments: [Backend.sqlite, .memory])
  func aMessageStillMarkedAsParsingGoesToReviewInsteadOfParsingAgain(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "crashed", dateMs: rig.clock.nowMs() - 60_000))
    rig.gmail.add(SyntheticMail.dibCard(id: "fine", amount: "10.00", dateMs: rig.clock.nowMs() - 30_000))
    rig.gmail.historyID = "1001"
    try await rig.store.markParsing("crashed")
    let r = await rig.engine.runCycle(trigger: .silentPush)
    #expect(r.ops == 2 && r.completed)
    let byID = Dictionary(uniqueKeysWithValues: await rig.enqueued().map { ($0.messageID, $0) })
    let crashed = try #require(byID["crashed"])
    #expect(crashed.needsReview)
    #expect(crashed.payload["unparsed"] == .bool(true))
    #expect(crashed.payload["gates"]?["ar"] == .string("parse_error"))
    #expect(crashed.payload["amount_minor"] == nil)
    #expect(byID["fine"]?.needsReview == false && byID["fine"]?.payload["unparsed"] == .bool(false))
    #expect(await rig.accounted("crashed") == .op)
    #expect(try await rig.store.isParsing("crashed") == false)
    #expect(try await rig.store.isParsing("fine") == false)
  }

  @Test(arguments: [Backend.sqlite, .memory])
  func aParseThatReturnsLeavesNoMark(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    rig.gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: Rig.t0 - day / 2))
    await rig.connectAndActivate()
    #expect(await rig.enqueued().count == 2)
    for id in ["d1", "n1"] { #expect(try await rig.store.isParsing(id) == false) }
  }

  @Test func theMarkIsDurableAndDisconnectClearsIt() throws {
    let tables = try MailboxTableStore.inMemory()
    #expect(try !tables.isParsing("m1"))
    try tables.markParsing("m1", at: 1)
    try tables.markParsing("m2", at: 2)
    #expect(try tables.isParsing("m1"))
    try tables.clearParsing("m1")
    #expect(try !tables.isParsing("m1") && tables.isParsing("m2"))
    var w = MailboxWrite()
    w.clearAll = true
    try tables.commit(w)
    #expect(try !tables.isParsing("m2"))
  }
}
