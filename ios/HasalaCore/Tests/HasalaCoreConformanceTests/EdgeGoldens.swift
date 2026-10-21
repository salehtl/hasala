enum EdgeGoldens {
  typealias G = FoldGoldens
  typealias R = MailboxRetireGoldens
  typealias D = DuplicateGoldens

  static let max = "9223372036854775807"

  static let home = G.op("home_currency_set", #"{"currency":"AED"}"#, id: "op-home")

  static func rate(_ ccy: String, _ micro: String, id: String) -> String {
    G.op("rate_set", #"{"currency":"\#(ccy)","rate_micro":"\#(micro)"}"#, id: id)
  }

  static func row(_ n: Int, _ currency: String, _ amount: String, at: String, merchant: String, grant: String = R.a) -> String {
    let p =
      #"{"amount_minor":"\#(amount)","currency":"\#(currency)","direction":"debit","posted_at":"\#(at)","posted_precision":"time","merchant_raw":"\#(merchant)","last4":"4412","needs_review":false,"tier":"template","category":"shopping","category_source":{"kind":"user"},"entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"msg-\#(n)"}}"#
    return G.op("txn_ingested", p, id: "op-ingest-\(n)", entity: ("txn", G.ulid(n)), ingest: G.ingestID(n))
  }

  static func budget(_ c: String, _ month: String, _ amount: String, _ scope: String, id: String) -> String {
    G.op("budget_set", #"{"category_id":"\#(c)","month":"\#(month)","amount_minor":"\#(amount)","scope":"\#(scope)"}"#, id: id)
  }

  static func move(
    _ from: String?, _ to: String?, _ amount: String, month: String = "2026-10", reason: String = "move", undoes: String? = nil, id: String
  ) -> String {
    func leg(_ c: String?) -> String { c.map { "\"\($0)\"" } ?? "null" }
    let u = undoes.map { "\"\($0)\"" } ?? "null"
    return G.op(
      "budget_moved",
      #"{"month":"\#(month)","from_category_id":\#(leg(from)),"to_category_id":\#(leg(to)),"amount_minor":"\#(amount)","reason":"\#(reason)","batch_id":null,"undoes":\#(u)}"#,
      id: id)
  }

  static func annotate(_ n: Int, _ set: String, id: String) -> String {
    G.op("txn_annotated", #"{"txn_id":"\#(G.ulid(n))","set":\#(set)}"#, id: id)
  }

  static func edit(_ n: Int, parent: Int, _ payload: String, id: String) -> String {
    G.op("txn_edited", payload, id: id, entity: ("txn", G.ulid(n)), parent: parent)
  }

  static let pairingBase: [(seq: Int, writer: String, ops: [String])] = [
    (1, G.w1, [home, rate("USD", "3672500", id: "op-rate-usd")]),
    (
      2, G.w1,
      [
        row(1, "USD", "2500", at: "2026-10-09T15:12:00.000Z", merchant: "AMAZON"),
        row(2, "AED", "9300", at: "2026-10-11T08:00:00.000Z", merchant: "AMAZON MKTPLACE"),
        row(3, "AED", "9300", at: "2026-10-11T08:04:00.000Z", merchant: "AMAZON MKTPLACE", grant: R.b),
      ]
    ),
    (3, G.w2, [annotate(2, #"{"archived":"user"}"#, id: "op-archive-2")]),
  ]

  static func bill(_ extra: String, id: String, parent: Int? = nil, at: String) -> String {
    G.op(
      "bill_set",
      #"{"name":"Netflix","keys":["netflix"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"5600","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-01-31","start":"2026-01-31","end":null,"category":"subscriptions","account":null,"source":"manual","status":"active"\#(extra)}"#,
      id: id, entity: ("bill", "bm_0123456789abcdef0123456789abcdef"), parent: parent, at: at)
  }

  static let pairs: [String: [String]] = [
    "pairing-skips-archived-and-held-rows": [],
    "pairing-takes-the-kept-copy": [G.ulid(1) + ">" + G.ulid(3)],
    "pairing-after-unarchive": [G.ulid(1) + ">" + G.ulid(2)],
    "same-purchase-and-its-undo": [G.ulid(1) + ">" + G.ulid(2)],
  ]

  static let set = FoldGoldenSet(
    file: "fold-v4-edges.json",
    note:
      "Edge cases of the v4 fold that the ledgerd TypeScript fold (schema 3, removed) could not express: held copies, the Undo pairs the app writes (a budget move, a budget edit, a same-purchase confirmation, a reopened copy), archived and held rows around same-purchase pairing, and money at the Int64 limits where the v4 fold records money_overflow or refuses the amount instead of carrying an unbounded number. Bills carry dated price changes and pause ranges as optional lists (absent and [] the same record), a refused list consumes no version, and created_at stays the create's. Written by the Swift executor; a case listed in HasalaCoreConformanceTests EdgeGoldens.pairs also pins SamePurchase.pairs over its folded state.",
    cases: [
      FoldGoldenCase(
        name: "held-copy-at-the-int64-ceiling",
        note: "The same alert at 2^63-1 from two mailboxes four minutes apart: the second is held as a copy of the first; both convert at the identity to 2^63-1 exactly.",
        blobs: [
          (1, G.w1, [home]),
          (2, G.w1, [D.alert(1, grant: R.a, amount: max)]),
          (3, G.w1, [D.alert(2, grant: R.b, amount: max, at: "08:04:00")]),
        ]),
      FoldGoldenCase(
        name: "held-copy-kept-then-reopened",
        note: "Keep both counts the copy; the undo (decision null) holds it again against the same row.",
        blobs: [
          (1, G.w1, [home]),
          (2, G.w1, [D.alert(1, grant: R.a)]),
          (3, G.w1, [D.alert(2, grant: R.b, at: "08:04:00")]),
          (4, G.w2, [D.resolve(2, other: 1, "keep_both", parent: 1, id: "op-keep-2")]),
          (5, G.w2, [D.resolve(2, other: 1, nil, parent: 2, id: "op-reopen-2")]),
        ]),
      FoldGoldenCase(
        name: "move-and-its-undo",
        note: "A move and its undo net to zero in both cells and mark the move undone. A second undo of the same move, an undo with another amount, an undo in another month and an undo of an undo are plan_undo_mismatch and move nothing. An assign from Ready to assign undoes back to it.",
        blobs: [
          (1, G.w1, [budget("groceries", "2026-10", "100000", "onward", id: "op-set-1")]),
          (2, G.w1, [move("groceries", "dining", "20000", id: "op-move-1")]),
          (3, G.w2, [move("dining", "groceries", "20000", reason: "undo", undoes: "op-move-1", id: "op-undo-1")]),
          (4, G.w2, [move("dining", "groceries", "20000", reason: "undo", undoes: "op-move-1", id: "op-undo-again")]),
          (
            5, G.w1,
            [
              move("groceries", "dining", "5000", id: "op-move-2"),
              move("dining", "groceries", "4999", reason: "undo", undoes: "op-move-2", id: "op-undo-short"),
              move("dining", "groceries", "5000", month: "2026-11", reason: "undo", undoes: "op-move-2", id: "op-undo-month"),
              move("groceries", "dining", "20000", reason: "undo", undoes: "op-undo-1", id: "op-undo-undo"),
            ]
          ),
          (6, G.w1, [move(nil, "groceries", "30000", reason: "assign", id: "op-assign-1")]),
          (7, G.w2, [move("groceries", nil, "30000", reason: "undo", undoes: "op-assign-1", id: "op-undo-assign")]),
        ]),
      FoldGoldenCase(
        name: "move-at-the-plan-cap",
        note: "A plan amount is at most 9999999999999 fils (13 digits), far below 2^63-1. Assigning the cap fits and its undo nets the cell to zero; one fils past the cap is an invalid_payload that moves nothing, and so is an undo naming it.",
        blobs: [
          (1, G.w1, [move(nil, "groceries", "9999999999999", reason: "assign", id: "op-assign-cap")]),
          (2, G.w1, [move(nil, "groceries", "10000000000000", reason: "assign", id: "op-assign-past")]),
          (3, G.w2, [move("groceries", nil, "10000000000000", reason: "undo", undoes: "op-assign-past", id: "op-undo-past")]),
          (4, G.w2, [move("groceries", nil, "9999999999999", reason: "undo", undoes: "op-assign-cap", id: "op-undo-cap")]),
        ]),
      FoldGoldenCase(
        name: "budget-edit-and-its-undo",
        note: "October inherits 1000.00 onward from September and has 200.00 moved in (1200.00). An edit sets 1500.00 onward; its undo writes what the app writes: 1000.00 onward, then 1200.00 for October only. November inherits 1000.00 again.",
        blobs: [
          (1, G.w1, [budget("groceries", "2026-09", "100000", "onward", id: "op-set-sep")]),
          (2, G.w1, [move(nil, "groceries", "20000", reason: "assign", id: "op-assign-oct")]),
          (3, G.w1, [budget("groceries", "2026-10", "150000", "onward", id: "op-edit-oct")]),
          (
            4, G.w2,
            [
              budget("groceries", "2026-10", "100000", "onward", id: "op-undo-onward"),
              budget("groceries", "2026-10", "120000", "only", id: "op-undo-only"),
            ]
          ),
        ]),
      FoldGoldenCase(
        name: "same-purchase-and-its-undo",
        note: "Confirming the pair gives the USD row the AED amount as its stated value and archives the AED posting with a note; the undo the app writes with the live rate thaws the stated value, sets the rate again so the row re-freezes at it, and clears the archive and the note. The pair is offered again.",
        blobs: [
          (1, G.w1, [home, rate("USD", "3672500", id: "op-rate-usd")]),
          (
            2, G.w1,
            [
              row(1, "USD", "2500", at: "2026-10-09T15:12:00.000Z", merchant: "AMAZON"),
              row(2, "AED", "9300", at: "2026-10-11T08:00:00.000Z", merchant: "AMAZON MKTPLACE"),
            ]
          ),
          (
            3, G.w2,
            [
              edit(1, parent: 1, #"{"amount_home_minor":"9300"}"#, id: "op-confirm-1"),
              annotate(2, #"{"archived":"user","note":"Settled the USD 25.00 purchase"}"#, id: "op-confirm-2"),
            ]
          ),
          (
            4, G.w2,
            [
              edit(1, parent: 2, #"{"amount_home_minor":null}"#, id: "op-undo-1"),
              rate("USD", "3672500", id: "op-undo-rate"),
              annotate(2, #"{"archived":null,"note":null}"#, id: "op-undo-2"),
            ]
          ),
        ]),
      FoldGoldenCase(
        name: "pairing-skips-archived-and-held-rows",
        note: "A USD purchase, its AED posting from mailbox A and the same posting from mailbox B four minutes later, held as a copy. The posting is archived: neither the archived posting nor the held copy is offered as the pair.",
        blobs: pairingBase),
      FoldGoldenCase(
        name: "pairing-takes-the-kept-copy",
        note: "Keep both on the held copy makes it a counted posting of its own, and it is offered as the pair.",
        blobs: pairingBase + [(4, G.w2, [D.resolve(3, other: 2, "keep_both", parent: 1, id: "op-keep-3")])]),
      FoldGoldenCase(
        name: "pairing-after-unarchive",
        note: "Unarchiving the posting offers it as the pair again; the held copy is still held.",
        blobs: pairingBase + [(4, G.w2, [annotate(2, #"{"archived":null}"#, id: "op-unarchive-2")])]),
      FoldGoldenCase(
        name: "conversion-overflow-is-recorded",
        note: "A USD row at 2^63-1 at 2.000000 does not fit Int64 in AED: the fold records money_overflow and the row waits with no home amount; a later rate of 1.000000 backfills it to 2^63-1.",
        blobs: [
          (1, G.w1, [home, rate("USD", "2000000", id: "op-rate-2")]),
          (2, G.w1, [row(1, "USD", max, at: "2026-10-09T15:12:00.000Z", merchant: "AMAZON")]),
          (3, G.w1, [rate("USD", "1000000", id: "op-rate-1")]),
        ]),
      FoldGoldenCase(
        name: "amount-past-int64-is-refused",
        note: "An amount of 2^63 is not money: the row is an invalid_payload and is not created, while 2^63-1 in the next op is.",
        blobs: [
          (1, G.w1, [home]),
          (
            2, G.w1,
            [
              row(1, "AED", "9223372036854775808", at: "2026-10-09T15:12:00.000Z", merchant: "PAST MAX"),
              row(2, "AED", max, at: "2026-10-09T15:12:00.000Z", merchant: "MAX"),
            ]
          ),
        ]),
      FoldGoldenCase(
        name: "bill-empty-lists-are-the-old-record",
        note: "A bill created with no changes or pauses, then edited with \"changes\":[] and \"pauses\":null: the record has neither list, and created_at stays the create's authored_at.",
        blobs: [
          (1, G.w1, [bill("", id: "op-bill-1", at: "2026-01-20T21:30:00.000Z")]),
          (2, G.w1, [bill(#","changes":[],"pauses":null"#, id: "op-bill-2", parent: 1, at: "2026-10-01T08:00:00.000Z")]),
        ]),
      FoldGoldenCase(
        name: "bill-price-change-pause-and-resume",
        note: "A price change from 2026-06-30, a pause from 2026-08-01 left open, then the resume that closes it and a second change; an edit whose open pause is not the last range is refused and consumes no version.",
        blobs: [
          (1, G.w1, [bill("", id: "op-bill-1", at: "2026-01-20T21:30:00.000Z")]),
          (
            2, G.w1,
            [
              bill(
                #","changes":[{"from":"2026-06-30","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":200}],"pauses":[{"from":"2026-08-01","until":null}]"#,
                id: "op-bill-2", parent: 1, at: "2026-08-01T08:00:00.000Z")
            ]
          ),
          (
            3, G.w2,
            [
              bill(
                #","pauses":[{"from":"2026-08-01","until":null},{"from":"2026-09-01","until":"2026-09-15"}]"#, id: "op-bill-bad",
                parent: 2, at: "2026-09-02T08:00:00.000Z")
            ]
          ),
          (
            4, G.w1,
            [
              bill(
                #","changes":[{"from":"2026-06-30","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":200},{"from":"2026-10-31","amount_mode":"variable","amount_minor":"7000","tolerance_bp":null}],"pauses":[{"from":"2026-08-01","until":"2026-10-01"}]"#,
                id: "op-bill-3", parent: 2, at: "2026-10-01T08:00:00.000Z")
            ]
          ),
        ]),
    ])
}
