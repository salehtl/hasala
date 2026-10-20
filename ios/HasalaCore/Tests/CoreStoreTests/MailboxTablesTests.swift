// The Gmail lane's ledger.sqlite tables (spec 04 §4.2) through MailboxTableStore.
import Foundation
import Testing

@testable import CoreStore

@Suite struct MailboxTablesTests {
  func op(_ id: String) -> MailboxPendingOpRow {
    MailboxPendingOpRow(opID: id, opJSON: Data("{}".utf8), opType: "txn_ingested", entityKind: "txn", entityID: id, enqueuedAt: 1)
  }

  @Test func opAndAccountingCommitTogetherOrNotAtAll() throws {
    let t = try MailboxTableStore.inMemory()
    var w = MailboxWrite()
    w.pending = [op("A")]
    w.accounted = [MailboxAccountedRow(messageID: "m1", outcome: "op", internalDate: 10, at: 11)]
    try t.commit(w)
    #expect(try t.pendingOpIDs() == ["A"])
    #expect(try t.accounted(among: ["m1", "m2"]) == ["m1"])

    // A second write whose op collides (UNIQUE op_id) rolls back its accounting too.
    var bad = MailboxWrite()
    bad.pending = [op("A")]
    bad.accounted = [MailboxAccountedRow(messageID: "m2", outcome: "op", internalDate: 10, at: 11)]
    #expect(throws: (any Error).self) { try t.commit(bad) }
    #expect(try t.accounted(among: ["m2"]).isEmpty)
    #expect(try t.pendingOpIDs() == ["A"])
  }

  @Test func outcomeOutsideTheCheckIsRefused() throws {
    let t = try MailboxTableStore.inMemory()
    var w = MailboxWrite()
    w.accounted = [MailboxAccountedRow(messageID: "m1", outcome: "staged", internalDate: 1, at: 1)]
    #expect(throws: (any Error).self) { try t.commit(w) }
  }

  @Test func stateRoundTripsEveryColumn() throws {
    let t = try MailboxTableStore.inMemory()
    #expect(try t.loadState() == nil)
    var s = MailboxStateRow(phase: "active")
    s.address = "synthetic.user@example.com"
    s.watermarkMs = 5
    s.profileHistoryID = "123"
    s.backfillDays = 90
    s.scanStartedMs = 4
    s.watchExpiresAt = 9
    s.haltedOn = "account_full"
    s.haltedDetail = "413"
    s.lastCycleAt = 6
    s.lastSuccessAt = 7
    s.lastHolderCheckAt = 8
    var w = MailboxWrite()
    w.state = s
    try t.commit(w)
    #expect(try t.loadState() == s)
  }

  @Test func ringsKeepTheNewest() throws {
    let t = try MailboxTableStore.inMemory()
    var w = MailboxWrite()
    w.setAside = (0..<210).map { MailboxSetAsideRow(messageID: "s\($0)", domain: "x.example", internalDate: Int64($0), at: 1) }
    w.unreadable = (0..<1_010).map { MailboxUnreadableRow(messageID: "u\($0)", reason: "gone", domain: nil, internalDate: nil, at: Int64($0)) }
    try t.commit(w)
    let sa = try t.setAside()
    #expect(sa.count == 200 && sa.first?.messageID == "s209" && sa.last?.messageID == "s10")
    let un = try t.unreadable()
    #expect(un.count == 1_000 && un.first?.messageID == "u1009" && un.last?.messageID == "u10")
  }

  @Test func stagingAndPruneAndHealth() throws {
    let t = try MailboxTableStore.inMemory()
    var w = MailboxWrite()
    w.stage = [
      MailboxStagingRow(
        messageID: "m2", ingestID: String(repeating: "b", count: 64), bank: "dib", last4: "1234", gatesJSON: Data("{}".utf8),
        draftJSON: Data("{}".utf8), internalDate: 20),
      MailboxStagingRow(
        messageID: "m1", ingestID: String(repeating: "a", count: 64), bank: "dib", last4: "1234", gatesJSON: Data("{}".utf8),
        draftJSON: Data("{}".utf8), internalDate: 10),
    ]
    w.accounted = [
      MailboxAccountedRow(messageID: "old", outcome: "dup", internalDate: 1, at: 1),
      MailboxAccountedRow(messageID: "new", outcome: "dup", internalDate: 100, at: 1),
    ]
    w.health = [("dib.ae", "2026-05", 10), ("dib.ae", "2026-05", 20), ("dib.ae", "2026-06", 30)]
    try t.commit(w)
    #expect(try t.staged(limit: 10).map(\.messageID) == ["m1", "m2"])
    #expect(try t.accounted(among: ["m1"]) == ["m1"])  // staged counts as accounted
    #expect(try t.bankHealth() == [BankHealthRecord(domain: "dib.ae", lastEmailAt: 30, month: "2026-06", readThisMonth: 1)])
    var p = MailboxWrite()
    p.unstage = ["m1"]
    p.pruneAccountedBelow = 50
    try t.commit(p)
    #expect(try t.stagedCount() == 1)
    #expect(try t.accounted(among: ["old", "new"]) == ["new"])
    var c = MailboxWrite()
    c.clearAll = true
    try t.commit(c)
    #expect(try t.stagedCount() == 0 && t.bankHealth().isEmpty)
  }
}
