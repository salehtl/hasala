import CoreReplay
import Testing

@testable import CoreProjection

@Suite struct ReviewReasonProjectionTests {
  @Test func aFailedVerdictReadsAsSenderUnverified() {
    for ar in ["fail", "no_ar", "multiple_ar", "not_topmost", "parse_error", "no_eop"] {
      #expect(TxnRow.senderUnverified(gatesJSON: #"{"ar":"\#(ar)","sender":"untrusted"}"#), "\(ar)")
    }
    #expect(TxnRow.senderUnverified(gatesJSON: #"{"ar":"fail","sender":"trusted"}"#))
  }

  @Test func aPassingVerdictIsVerified() {
    #expect(!TxnRow.senderUnverified(gatesJSON: #"{"ar":"pass","sender":"untrusted"}"#))
    #expect(!TxnRow.senderUnverified(gatesJSON: #"{"ar":"pass","sender":"trusted"}"#))
  }

  @Test func noGatesAreNotUnverified() {
    #expect(!TxnRow.senderUnverified(gatesJSON: nil))
    #expect(!TxnRow.senderUnverified(gatesJSON: #"{"sender":"untrusted"}"#))
    #expect(!TxnRow.senderUnverified(gatesJSON: "not json"))
  }

  @Test func anUnverifiedMailIsNoSweepCandidate() throws {
    var s = State()
    try MerchantGroupProjectionTests.blob(
      1,
      [
        MerchantGroupProjectionTests.txn(1, "TAILSCALE INC", posted: "2026-10-03T08:00:00.000Z", extra: #","needs_review":true,"gates":{"ar":"fail","sender":"untrusted"}"#),
        MerchantGroupProjectionTests.txn(2, "TAILSCALE INC", posted: "2026-10-04T08:00:00.000Z", extra: #","needs_review":true,"gates":{"ar":"pass","sender":"trusted"}"#),
      ], into: &s)
    #expect(s.anomalies.isEmpty)
    let (_, r) = try MerchantGroupProjectionTests.project(s)
    let rows = Dictionary(uniqueKeysWithValues: try r.sweepRows().map { ($0.id, $0) })
    #expect(rows[MerchantGroupProjectionTests.id(1)]?.candidate == false)
    #expect(rows[MerchantGroupProjectionTests.id(2)]?.candidate == true)
    #expect(try r.txn(MerchantGroupProjectionTests.id(1))?.senderUnverified == true)
  }
}
