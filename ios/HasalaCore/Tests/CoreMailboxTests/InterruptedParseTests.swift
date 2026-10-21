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

actor CancelOnParse: MailboxPersistence {
  let base: any MailboxPersistence
  var armed = false

  init(_ base: any MailboxPersistence) { self.base = base }

  func arm() { armed = true }

  func loadState() async throws(MailboxPersistenceError) -> MailboxState { try await base.loadState() }
  func accounted(among ids: [String]) async throws(MailboxPersistenceError) -> Set<String> {
    try await base.accounted(among: ids)
  }
  func staged(limit: Int) async throws(MailboxPersistenceError) -> [ParsedMail] { try await base.staged(limit: limit) }
  func stagedCount() async throws(MailboxPersistenceError) -> Int { try await base.stagedCount() }
  func commit(_ c: MailboxCommit) async throws(MailboxPersistenceError) { try await base.commit(c) }
  func setAsideRecords() async throws(MailboxPersistenceError) -> [SetAsideRecord] { try await base.setAsideRecords() }
  func unreadableRecords() async throws(MailboxPersistenceError) -> [UnreadableRecord] { try await base.unreadableRecords() }
  func bankHealth() async throws(MailboxPersistenceError) -> [BankHealthRow] { try await base.bankHealth() }
  func senderAddresses() async throws(MailboxPersistenceError) -> [String] { try await base.senderAddresses() }
  func addSenderAddress(_ address: String) async throws(MailboxPersistenceError) { try await base.addSenderAddress(address) }
  func isParsing(_ messageID: String) async throws(MailboxPersistenceError) -> Bool { try await base.isParsing(messageID) }
  func markParsing(_ messageID: String) async throws(MailboxPersistenceError) {
    if armed {
      armed = false
      withUnsafeCurrentTask { $0?.cancel() }
    }
    try await base.markParsing(messageID)
  }
  func clearParsing(_ messageID: String) async throws(MailboxPersistenceError) { try await base.clearParsing(messageID) }
  func pendingImports() async throws(MailboxPersistenceError) -> [PendingImport] { try await base.pendingImports() }
}

@Suite struct CancelledParseTests {
  @Test(arguments: [Backend.sqlite, .memory])
  func aCycleCancelledWhileParsingLeavesTheMessageForTheNextCycle(_ backend: Backend) async throws {
    var gate: CancelOnParse?
    let rig = Rig(backend: backend, wrapStore: { base in
      let g = CancelOnParse(base)
      gate = g
      return g
    })
    let store = try #require(gate)
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "d2", amount: "2.00", dateMs: rig.clock.nowMs() - 1000))
    await store.arm()
    let engine = rig.engine
    _ = await Task { await engine.runCycle(trigger: .refresh) }.value
    #expect(await rig.accounted("d2") == nil)
    #expect(try await store.isParsing("d2") == false)
    #expect(!(await rig.enqueued()).contains { $0.messageID == "d2" })

    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.review == 0)
    let d2 = try #require(await rig.enqueued().first { $0.messageID == "d2" })
    #expect(d2.payload["unparsed"] == .bool(false) && d2.payload["amount_minor"] == .string("200"))
    #expect(await rig.accounted("d2") == .op)
  }
}
