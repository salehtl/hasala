import CoreWire
import Foundation
import Testing

@testable import CoreReplay

func usd(_ n: Int, id: String, amount: String = "2500") -> String {
  op(
    "txn_ingested",
    #"{"amount_minor":"\#(amount)","currency":"USD","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"AMAZON US","last4":"4412","needs_review":true}"#,
    id: 1000 + n, entity: ("txn", id), ingest: Ids.ingest(n))
}

@Suite("CoreReplay home source")
struct HomeSourceTests {
  static let home = op("home_currency_set", #"{"currency":"AED"}"#, id: 1)
  static let usdRate = op("rate_set", #"{"currency":"USD","rate_micro":"3672500"}"#, id: 2)

  @Test("a home-currency row is identity, a converted row is rate")
  func freeze() throws {
    var log = Log()
    try log.blob(Self.home, Self.usdRate)
    try log.blob(ingest(1, id: Ids.t1), usd(2, id: Ids.t2))
    #expect(log.state.txns[Ids.t1]?.homeSource == .identity)
    #expect(log.state.txns[Ids.t2]?.amountHomeMinor == 9181)
    #expect(log.state.txns[Ids.t2]?.homeSource == .rate)
    #expect(log.state.txns[Ids.t2]?.homeRateMicro == 3_672_500)
    #expect(log.state.txns[Ids.t1]?.homeRateMicro == nil)
    #expect(log.kinds.isEmpty)
  }

  @Test("a row with no rate has no source until a rate backfills it")
  func backfill() throws {
    var log = Log()
    try log.blob(Self.home)
    try log.blob(usd(1, id: Ids.t1))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == nil)
    #expect(log.state.txns[Ids.t1]?.homeSource == nil)
    try log.blob(Self.usdRate)
    #expect(log.state.txns[Ids.t1]?.homeSource == .rate)
  }

  @Test("a verbatim home amount is stated, a clear removes the source, a money edit refreezes at the rate")
  func stated() throws {
    var log = Log()
    try log.blob(Self.home, Self.usdRate)
    try log.blob(usd(1, id: Ids.t1))
    try log.blob(op("txn_edited", #"{"amount_home_minor":"9250"}"#, id: 3, entity: ("txn", Ids.t1), parent: 1))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == 9250)
    #expect(log.state.txns[Ids.t1]?.homeSource == .stated)
    #expect(log.state.txns[Ids.t1]?.homeRateMicro == nil)
    try log.blob(op("txn_edited", #"{"amount_home_minor":null}"#, id: 4, entity: ("txn", Ids.t1), parent: 2))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == nil)
    #expect(log.state.txns[Ids.t1]?.homeSource == nil)
    try log.blob(op("txn_edited", #"{"amount_home_minor":"9300"}"#, id: 5, entity: ("txn", Ids.t1), parent: 3))
    try log.blob(op("txn_edited", #"{"amount_minor":"3000"}"#, id: 6, entity: ("txn", Ids.t1), parent: 4))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == 11018)
    #expect(log.state.txns[Ids.t1]?.homeSource == .rate)
    #expect(log.kinds.isEmpty)
  }

  @Test("the witness does not carry the source, and a snapshot keeps it")
  func witnessAndSnapshot() throws {
    var log = Log()
    try log.blob(Self.home, Self.usdRate)
    try log.blob(usd(1, id: Ids.t1))
    let w = String(decoding: log.state.serialized(), as: UTF8.self)
    #expect(!w.contains("home_source") && !w.contains("homeSource"))
    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: log.state))).state
    #expect(back.txns[Ids.t1]?.homeSource == .rate)
    #expect(StateSnapshot.currentFormat == 4)
    var old = StateSnapshot(state: log.state)
    old.formatVersion = 1
    #expect(throws: SnapshotError.version) { try SnapshotCodec.decode(try SnapshotCodec.encode(old)) }
  }
}
