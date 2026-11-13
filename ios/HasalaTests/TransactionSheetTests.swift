import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Transaction sheet")
struct TransactionSheetTests {
  @Test func aTransferOffersNoSplit() throws {
    var s = MayaLedger.state
    let i = try #require(s.txns.firstIndex { $0.id == "transfer-in" })
    s.txns[i].categoryID = "transfer"
    s.txns[i].isTransfer = true
    s.txns[i].needsReview = false
    let transfer = try #require(TransactionEngine.detail("transfer-in", s, now: MayaLedger.now))
    #expect(transfer.isTransfer && !TransactionSheet.offersSplit(transfer))
    let carrefour = try #require(TransactionEngine.detail("carrefour", s, now: MayaLedger.now))
    #expect(!carrefour.isTransfer && TransactionSheet.offersSplit(carrefour))
  }
}
