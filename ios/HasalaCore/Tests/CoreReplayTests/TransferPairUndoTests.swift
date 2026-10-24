import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite("CoreReplay combined transfer pair undo")
struct TransferPairUndoTests {
  static let payee = "SAMPLE PAYEE"

  @Test("alert first: keep both on the merged alert counts both, replays the same and refuses nothing")
  func alertFirstUndo() throws {
    func fold(_ extra: Int) throws -> Log {
      var log = Log()
      try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
      try log.blob(Notice.row(2, id: Ids.t2, template: Notice.arabic, merchant: Self.payee, at: "2026-10-03T10:04:00.000Z"))
      for i in 0..<extra { try log.blob(Copy.resolve(Ids.t1, other: Ids.t2, "keep_both", parent: 1 + i, op: 50 + i)) }
      return log
    }
    let merged = try fold(0)
    #expect(merged.state.txns[Ids.t1]?.mergedInto == Ids.t2 && merged.state.txns[Ids.t1]?.copyOf == Ids.t2)
    #expect(merged.state.transferDisplaySource(Ids.t2) == nil)
    let once = try fold(1)
    #expect(once.state.txns.values.filter(\.isLive).map(\.id).sorted() == [Ids.t1, Ids.t2])
    #expect(once.state.txns[Ids.t1]?.copyDecision == "keep_both" && once.state.txns[Ids.t2]?.aliases.isEmpty == true)
    #expect(try fold(1).state.serialized() == once.state.serialized())
    let twice = try fold(2)
    #expect(twice.kinds.isEmpty)
    #expect(twice.state.txns.values.filter(\.isLive).count == 2 && twice.state.txns[Ids.t1]?.copyDecision == "keep_both")
  }

  @Test("an alert kept as the row names the notice it shows until the notice is kept apart")
  func displaySource() throws {
    var log = Log()
    try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:05:00.000Z"))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
    try log.blob(Notice.row(3, id: Ids.t3, template: Notice.arabic, merchant: Self.payee, at: "2026-10-03T10:06:00.000Z"))
    #expect(log.state.txns[Ids.t3]?.mergedInto == Ids.t2 && log.state.txns[Ids.t3]?.copyOf == Ids.t2)
    #expect(log.state.transferDisplaySource(Ids.t2) == Ids.t3)
    #expect(log.state.txns[Ids.t2]?.merchantRaw == "MB FUND TRANSFER DEBIT")
    try log.blob(Copy.resolve(Ids.t3, other: Ids.t2, "keep_both", parent: 1, op: 51))
    #expect(log.state.transferDisplaySource(Ids.t2) == nil && log.state.txns[Ids.t3]?.isLive == true)
    try log.blob(Copy.resolve(Ids.t3, other: Ids.t2, nil, parent: 2, op: 52))
    #expect(log.state.transferDisplaySource(Ids.t2) == Ids.t3)
    #expect(log.kinds.isEmpty)
  }
}
