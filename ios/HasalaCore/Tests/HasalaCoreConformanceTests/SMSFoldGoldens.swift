enum SMSFoldGoldens {
  typealias G = FoldGoldens

  static let purchase =
    #"{"amount_minor":"12345","currency":"AED","direction":"debit","posted_at":"2026-06-05T06:11:00.000Z","posted_precision":"time","merchant_raw":"SAMPLE SHOP","last4":"1234","needs_review":false,"unparsed":false,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"sender":"trusted","template":"dib.sms.purchase.v1@1","card":"known","forwarded":false},"channel":"sms","received_at":"2026-06-05T08:00:00.000Z"}"#

  static let unparsed =
    #"{"unparsed":true,"needs_review":true,"tier":"none","posted_at":"2026-06-05T08:00:00.000Z","posted_precision":"time","merchant_raw":"","last4":"1234","category":null,"entry_method":"mailbox","bank":"dib","gates":{"sender":"untrusted","template":"none","card":"unknown","forwarded":false},"channel":"sms","received_at":"2026-06-05T08:00:00.000Z"}"#

  static let debitAlert =
    #"{"amount_minor":"23456","currency":"AED","direction":"debit","posted_at":"2026-06-05T08:00:00.000Z","posted_precision":"time","merchant_raw":"OUTGOING DOMESTIC FUND TR","last4":"","needs_review":true,"unparsed":false,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"sender":"trusted","template":"dib.sms.debit.v1@1","card":"none","forwarded":false},"channel":"sms","received_at":"2026-06-05T08:00:00.000Z"}"#

  static let transferNotice =
    #"{"amount_minor":"23456","currency":"AED","direction":"debit","posted_at":"2026-06-05T08:10:00.000Z","posted_precision":"time","merchant_raw":"DIB OWN ACCOUNT TRANSFER","last4":"","needs_review":true,"unparsed":false,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"sender":"trusted","template":"dib.sms.own-transfer.v1@1","card":"none","forwarded":false},"channel":"sms","received_at":"2026-06-05T08:10:00.000Z"}"#

  static let reader =
    #"{"amount_minor":"4500","currency":"AED","direction":"debit","posted_at":"2026-06-05T08:00:00.000Z","posted_precision":"time","merchant_raw":"SYNTHETIC SHOP","last4":"1234","needs_review":true,"unparsed":false,"tier":"heuristic","entry_method":"mailbox","gates":{"sender":"untrusted","template":"none","card":"unknown","forwarded":false},"channel":"sms","received_at":"2026-06-05T08:00:00.000Z"}"#

  static let pasted =
    #"{"amount_minor":"12345","currency":"AED","direction":"debit","posted_at":"2026-06-05T06:11:00.000Z","posted_precision":"time","merchant_raw":"SAMPLE SHOP","last4":"1234","needs_review":true,"unparsed":false,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"sender":"untrusted","template":"dib.sms.purchase.v1@1","card":"unknown","forwarded":false},"channel":"sms","received_at":"2026-06-05T09:00:00.000Z"}"#

  static let payloads: [String: String] = [
    "purchase": purchase, "unparsed": unparsed, "debit_alert": debitAlert, "transfer_notice": transferNotice, "reader": reader,
    "pasted": pasted,
  ]

  static let textIngest = String(repeating: "0", count: 62) + "c1"
  static let textIngest2 = String(repeating: "0", count: 62) + "c2"

  static func ingest(_ n: Int, _ payload: String, key: String? = nil, at: String = "2026-06-05T08:00:01.000Z") -> String {
    G.op("txn_ingested", payload, id: "op-sms-\(n)", entity: ("txn", G.ulid(n)), ingest: key ?? G.ingestID(n), at: at)
  }

  static let set = FoldGoldenSet(
    file: "fold-v4-sms-texts.json",
    note:
      "Rows from bank texts (docs/decisions/bank-texts.md, The op log). A text row is a v4 txn_ingested with entry_method mailbox, no provenance, no dedupe and no gates.ar, gates.sender trusted only when the sender matched the template's sms_sender, and two keys that older builds ignore: channel \"sms\" and received_at (the arrival minute). Its ingest_id is an HMAC key (64 hex digits). The fold keeps channel and received_at on the row for the projection and leaves both out of the witness, so state_sha256 is what a build from before bank texts gives. A text row never forms the fold's implicit transfer pair (no gates.ar pass); the authoring side holds the second row of a DIB debit alert and transfer notice in Review instead, and the fold keeps both rows. A repeat with a new key inside ten minutes is a held probable copy; the same key again is duplicate_ingest; a repeat with no bank is a second row beside the first; an unparsed text row folds and accepts an archive. Every op is synthetic. Written by the Swift executor.",
    cases: [
      FoldGoldenCase(
        name: "sms-template-row", note: "A DIB SMS purchase that filed itself: no anomaly.",
        blobs: [(1, G.w1, [ingest(1, purchase, key: textIngest)])]),
      FoldGoldenCase(
        name: "sms-repeat-held", note: "Equal texts in one minute get keys n 0 and n 1: the second is a held probable copy.",
        blobs: [(1, G.w1, [ingest(1, purchase, key: textIngest)]), (2, G.w1, [ingest(2, purchase, key: textIngest2, at: "2026-06-05T08:00:51.000Z")])]),
      FoldGoldenCase(
        name: "sms-same-key", note: "The same key again is duplicate_ingest.",
        blobs: [(1, G.w1, [ingest(1, purchase, key: textIngest)]), (2, G.w1, [ingest(2, purchase, key: textIngest, at: "2026-06-05T08:00:51.000Z")])]),
      FoldGoldenCase(
        name: "sms-transfer-pair-kept", note: "A DIB debit alert and a transfer notice from texts, ten minutes apart: two rows, no merge.",
        blobs: [
          (1, G.w1, [ingest(1, debitAlert)]), (2, G.w1, [ingest(2, transferNotice, at: "2026-06-05T08:10:01.000Z")]),
        ]),
      FoldGoldenCase(
        name: "sms-reader-repeat-no-bank", note: "A reader row with no bank, twice: a second row beside the first.",
        blobs: [(1, G.w1, [ingest(1, reader)]), (2, G.w1, [ingest(2, reader, at: "2026-06-05T08:00:30.000Z")])]),
      FoldGoldenCase(
        name: "sms-unparsed-pasted-over",
        note: "An unparsed text row, then a pasted text that replaces it: the paste and the archive are one blob.",
        blobs: [
          (1, G.w1, [ingest(1, unparsed)]),
          (
            2, G.w1,
            [
              ingest(2, pasted, at: "2026-06-05T09:00:01.000Z"),
              G.op(
                "txn_annotated", #"{"txn_id":"\#(G.ulid(1))","set":{"archived":"user"}}"#, id: "op-sms-archive",
                at: "2026-06-05T09:00:01.001Z"),
            ]
          ),
        ]),
    ])
}
