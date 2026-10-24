import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("A row combined from two bank emails")
struct CombinedCopyTests {
  static var state: LedgerState {
    var s = MayaLedger.state
    if let i = s.txns.firstIndex(where: { $0.id == "carrefour" }) { s.txns[i].combinedCopy = "carrefour-alert" }
    return s
  }

  @Test func theDetailSaysItWasCombined() throws {
    let s = Self.state
    #expect(TransactionEngine.detail("carrefour", s, now: MayaLedger.now)?.combined == true)
    #expect(TransactionEngine.detail("lulu", s, now: MayaLedger.now)?.combined == false)
  }

  @Test func keepingItApartClearsTheMarkAndCanBeUndone() throws {
    let ledger = InMemoryLedger(state: Self.state)
    let token = try #require(try ledger.apply(.keepCombinedApart("carrefour")))
    #expect(token.title == "Kept both")
    #expect(ledger.state.txn("carrefour")?.combinedCopy == nil)
    ledger.undo(token)
    #expect(ledger.state.txn("carrefour")?.combinedCopy == "carrefour-alert")
    #expect(throws: ActionError.notFound) { try ledger.apply(.keepCombinedApart("lulu")) }
  }
}
