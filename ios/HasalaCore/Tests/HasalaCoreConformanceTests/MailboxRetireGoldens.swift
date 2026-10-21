enum MailboxRetireGoldens {
  typealias G = FoldGoldens

  static let a = "01JCUSER0000000000000000AA/mbx-0000000000000000000000000000000a"
  static let b = "01JCUSER0000000000000000AA/mbx-0000000000000000000000000000000b"
  static let legacy = "01JCUSER0000000000000000AA"

  static func ingest(
    _ n: Int, merchant: String, amount: String = "5000", grant: String?, provider: String = "gmail", minute: Int = 0
  ) -> String {
    let mm = minute < 10 ? "0\(minute)" : "\(minute)"
    var p =
      #"{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:\#(mm):00.000Z","merchant_raw":"\#(merchant)","last4":"4412","needs_review":false,"tier":"template","category":null"#
    if let grant {
      p +=
        #","entry_method":"mailbox","bank":"enbd","provenance":{"provider":"\#(provider)","grant_id":"\#(grant)","message_id":"msg-\#(n)"}"#
    } else {
      p += #","entry_method":"manual""#
    }
    return G.op("txn_ingested", p + "}", id: "op-ingest-\(n)", entity: ("txn", G.ulid(n)), ingest: G.ingestID(n))
  }

  static func retire(_ grant: String, provider: String = "gmail", legacy: Bool, id: String) -> String {
    G.op("mailbox_retired", #"{"grant_id":"\#(grant)","provider":"\#(provider)","legacy":\#(legacy)}"#, id: id)
  }

  static let recategorize = G.op(
    "txn_categorized", #"{"category":"transport","needs_review":false,"source":{"kind":"user"}}"#, id: "op-edit-2",
    entity: ("txn", G.ulid(2)), parent: 1)
  static let note = G.op("txn_annotated", #"{"txn_id":"\#(G.ulid(1))","set":{"note":"Team lunch"}}"#, id: "op-note-1")

  static var base: [(seq: Int, writer: String, ops: [String])] {
    [
      (1, G.w1, [ingest(1, merchant: "CARREFOUR MOE", grant: a), ingest(2, merchant: "ENOC 1043", amount: "16850", grant: a)]),
      (2, G.w1, [ingest(3, merchant: "IKEA FESTIVAL CITY", amount: "24280", grant: b)]),
      (3, G.w2, [ingest(4, merchant: "CASH MARKET", amount: "1200", grant: nil)]),
      (4, G.w2, [recategorize, note]),
    ]
  }

  static let set = FoldGoldenSet(
    file: "fold-v4-mailbox-retire.json",
    note:
      "mailbox_retired (v4, parent-free): {grant_id, provider, legacy}. Every v4 txn row projects source_mailbox (provenance.grant_id) and source_provider. The op retires the live rows that one mailbox imported before its position: rows whose source_provider equals provider and whose source_mailbox equals grant_id, or, when legacy is true, equals the account part of grant_id (before \"/mbx-\"). A retired row keeps every field, gets retired_by, and leaves liveByIngestID, byFingerprint and pendingByCurrency, so the same message imported again is a new row. Keep authors no op. Written by the Swift executor; the ledgerd TypeScript fold (schema 3, removed) and Go (no fold) do not model v4.",
    cases: [
      FoldGoldenCase(
        name: "project", note: "Rows from two mailboxes and a manual row; each v4 import carries its mailbox and provider.",
        blobs: base),
      FoldGoldenCase(
        name: "retire-remove",
        note: "Remove retires mailbox A's two rows, the edited and annotated ones too; mailbox B and the manual row stay live.",
        blobs: base + [(5, G.w1, [retire(a, legacy: false, id: "op-retire-a")])]),
      FoldGoldenCase(
        name: "keep", note: "Keep authors nothing: the same log with no retire, every row live and counted.",
        blobs: base + [(5, G.w1, [ingest(5, merchant: "SPINNEYS MARINA", amount: "21540", grant: a, minute: 30)])]),
      FoldGoldenCase(
        name: "reconnect-after-remove",
        note:
          "After the retire the same mailbox is connected again: message 1 imports again under its ingest id as a new live row with no duplicate_ingest, and a new message imports as usual; the retired rows stay retired.",
        blobs: base + [
          (5, G.w1, [retire(a, legacy: false, id: "op-retire-a")]),
          (6, G.w1, [
            G.op(
              "txn_ingested",
              #"{"amount_minor":"5000","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"CARREFOUR MOE","last4":"4412","needs_review":false,"tier":"template","category":null,"entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(a)","message_id":"msg-1"}}"#,
              id: "op-reingest-1", entity: ("txn", G.ulid(11)), ingest: G.ingestID(1)),
            ingest(5, merchant: "SPINNEYS MARINA", amount: "21540", grant: a, minute: 30),
          ]),
        ]),
      FoldGoldenCase(
        name: "old-rows-legacy",
        note:
          "Rows imported before grant ids named a mailbox carry the bare account id. With legacy true the Gmail retire takes the Gmail legacy row; the Outlook legacy row and another account's row stay.",
        blobs: [
          (1, G.w1, [
            ingest(1, merchant: "CARREFOUR MOE", grant: legacy), ingest(2, merchant: "ENOC 1043", grant: legacy, provider: "outlook"),
            ingest(3, merchant: "IKEA FESTIVAL CITY", grant: "01JCUSER0000000000000000BB"),
          ]),
          (2, G.w1, [ingest(4, merchant: "NOON.COM", grant: a)]),
          (3, G.w1, [retire(a, legacy: true, id: "op-retire-a")]),
        ]),
      FoldGoldenCase(
        name: "old-rows-left-alone",
        note: "The same log with legacy false: only the row that names mailbox A is retired.",
        blobs: [
          (1, G.w1, [
            ingest(1, merchant: "CARREFOUR MOE", grant: legacy), ingest(2, merchant: "ENOC 1043", grant: legacy, provider: "outlook"),
            ingest(3, merchant: "IKEA FESTIVAL CITY", grant: "01JCUSER0000000000000000BB"),
          ]),
          (2, G.w1, [ingest(4, merchant: "NOON.COM", grant: a)]),
          (3, G.w1, [retire(a, legacy: false, id: "op-retire-a")]),
        ]),
      FoldGoldenCase(
        name: "retire-malformed",
        note: "A retire with no legacy flag, or a provider outside [a-z0-9_]{2,32}, is an invalid_payload and retires nothing.",
        blobs: base + [
          (5, G.w1, [G.op("mailbox_retired", #"{"grant_id":"\#(a)","provider":"gmail"}"#, id: "op-bad-1")]),
          (6, G.w1, [G.op("mailbox_retired", #"{"grant_id":"\#(a)","provider":"Gmail","legacy":false}"#, id: "op-bad-2")]),
        ]),
    ])
}
