import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite("CoreReplay: rows from bank texts")
struct TextChannelTests {
  @Test("channel and received_at are kept on the row and never witnessed, so the fold's output is what older builds give")
  func keptNotWitnessed() throws {
    var text = Log()
    try text.blob(ingest(1, id: Ids.t1, extra: #","entry_method":"mailbox","channel":"sms","received_at":"2026-10-03T08:00:00Z""#))
    var plain = Log()
    try plain.blob(ingest(1, id: Ids.t1, extra: #","entry_method":"mailbox""#))
    #expect(text.kinds.isEmpty && plain.kinds.isEmpty)
    let t = try #require(text.state.txns[Ids.t1])
    #expect(t.channel == "sms" && t.receivedAt == "2026-10-03T08:00:00.000Z" && t.isText)
    #expect(plain.state.txns[Ids.t1]?.channel == nil && plain.state.txns[Ids.t1]?.receivedAt == nil)
    #expect(text.state.serialized() == plain.state.serialized())
    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: text.state))).state
    #expect(back == text.state && back.txns[Ids.t1]?.channel == "sms")
  }

  @Test("an unknown channel or an unusable received_at is ignored with no anomaly, as an older build ignores both")
  func lenient() throws {
    for extra in [
      #","channel":"mail""#, #","channel":"SMS""#, #","channel":5"#, #","channel":null"#, #","received_at":"yesterday""#,
      #","received_at":7"#, #","received_at":null"#,
    ] {
      var log = Log()
      try log.blob(ingest(1, id: Ids.t1, extra: extra))
      #expect(log.kinds.isEmpty, "\(extra)")
      #expect(log.state.txns[Ids.t1]?.channel == nil && log.state.txns[Ids.t1]?.receivedAt == nil, "\(extra)")
    }
  }

  @Test("an unparsed text row folds with no anomaly and accepts an archive")
  func unparsedTextRow() throws {
    var log = Log()
    try log.blob(
      op(
        "txn_ingested",
        #"{"unparsed":true,"needs_review":true,"tier":"none","posted_at":"2026-10-03T08:00:00.000Z","posted_precision":"time","merchant_raw":"","last4":"1234","category":null,"entry_method":"mailbox","bank":"dib","gates":{"sender":"untrusted","template":"none","card":"unknown","forwarded":false},"channel":"sms","received_at":"2026-10-03T08:00:00.000Z"}"#,
        id: 1, entity: ("txn", Ids.t1), ingest: Ids.ingest(1)))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"archived":"user"}}"#, id: 2))
    #expect(log.kinds.isEmpty)
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.unparsed && t.isText && t.annotation("archived") == "user" && t.bank == "dib")
  }
}
