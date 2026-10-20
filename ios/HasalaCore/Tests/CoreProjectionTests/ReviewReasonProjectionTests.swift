import CoreReplay
import Testing

@testable import CoreProjection

@Suite struct ReviewReasonProjectionTests {
  @Test func aFailedVerdictReadsAsSenderUnverified() {
    for ar in ["fail", "no_ar", "multiple_ar", "not_topmost", "parse_error", "no_eop"] {
      #expect(TxnRow.reviewReason(gatesJSON: #"{"ar":"\#(ar)","sender":"untrusted"}"#) == .senderUnverified, "\(ar)")
    }
    #expect(TxnRow.reviewReason(gatesJSON: #"{"ar":"fail","sender":"trusted"}"#) == .senderUnverified)
  }

  @Test func aPassingVerdictHasNoSenderReason() {
    #expect(TxnRow.reviewReason(gatesJSON: #"{"ar":"pass","sender":"untrusted"}"#) == nil)
    #expect(TxnRow.reviewReason(gatesJSON: #"{"ar":"pass","sender":"trusted"}"#) == nil)
  }

  @Test func noGatesHaveNoReason() {
    #expect(TxnRow.reviewReason(gatesJSON: nil) == nil)
    #expect(TxnRow.reviewReason(gatesJSON: #"{"sender":"untrusted"}"#) == nil)
    #expect(TxnRow.reviewReason(gatesJSON: "not json") == nil)
  }

  @Test func theSenderCheckIsTheCodeOfAnUnverifiedRow() {
    for ar in ["fail", "no_ar", "multiple_ar", "not_topmost", "parse_error", "no_eop"] {
      #expect(TxnRow.senderCheck(gatesJSON: #"{"ar":"\#(ar)","sender":"untrusted"}"#) == ar)
    }
    #expect(TxnRow.senderCheck(gatesJSON: #"{"ar":"pass","sender":"untrusted"}"#) == nil)
    #expect(TxnRow.senderCheck(gatesJSON: #"{"ar":"pass","sender":"trusted"}"#) == nil)
    #expect(TxnRow.senderCheck(gatesJSON: #"{"sender":"untrusted"}"#) == nil)
    #expect(TxnRow.senderCheck(gatesJSON: nil) == nil)
    #expect(TxnRow.senderCheck(gatesJSON: "not json") == nil)
  }
}
