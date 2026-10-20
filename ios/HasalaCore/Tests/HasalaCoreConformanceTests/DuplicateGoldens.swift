enum DuplicateGoldens {
  typealias G = FoldGoldens
  typealias R = MailboxRetireGoldens

  static let mid = "5d41402abc4b2a76b9719d911017c592"
  static let pass = #"{"ar":"pass","sender":"trusted","template":"enbd-card@1","card":"known","forwarded":false}"#
  static let fail = #"{"ar":"fail","sender":"untrusted","template":"enbd-card@1","card":"known","forwarded":false}"#

  static func alert(
    _ n: Int, grant: String, merchant: String = "STARBUCKS DIFC", amount: String = "2700", at: String = "08:00:00",
    mid: String? = nil, verified: Bool = false, message: String? = nil
  ) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    let p =
      #"{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"2026-10-03T\#(at).000Z","posted_precision":"time","merchant_raw":"\#(merchant)","last4":"4412","needs_review":false,"tier":"template","category":null,"entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"\#(message ?? "msg-\(n)")"},"gates":\#(verified ? pass : fail)\#(dedupe)}"#
    return G.op("txn_ingested", p, id: "op-ingest-\(n)", entity: ("txn", G.ulid(n)), ingest: G.ingestID(n))
  }

  static func resolve(_ n: Int, other: Int, _ decision: String?, parent: Int, id: String) -> String {
    G.op(
      "txn_copy_resolved",
      #"{"other_txn_id":"\#(G.ulid(other))","decision":\#(decision.map { "\"\($0)\"" } ?? "null")}"#, id: id,
      entity: ("txn", G.ulid(n)), parent: parent)
  }

  static func sort(_ n: Int, _ category: String, parent: Int, id: String) -> String {
    G.op(
      "txn_categorized", #"{"category":"\#(category)","needs_review":false,"source":{"kind":"user"}}"#, id: id,
      entity: ("txn", G.ulid(n)), parent: parent, at: "2026-10-01T09:00:00.000Z")
  }

  static let set = FoldGoldenSet(
    file: "fold-v4-duplicates.json",
    note:
      "Copies of one bank alert across mailboxes (and within one, after a reconnect). A v4 txn_ingested may carry dedupe {message_id, bank_ref}: 32 lower-case hex digits each (message_id is the first 16 bytes of SHA-256 over the RFC 5322 Message-ID, angle brackets dropped, ASCII lower-cased). A certain copy (a dedupe key already in byDedupeKey on a live row) merges at once: the copy whose gates say ar pass and sender trusted wins, else the earlier one; the other gets merged_into, merge_kind certain and merge_op, leaves the live indexes, and becomes an alias on the canonical row. Re-ingesting a merged copy's ingest id is a duplicate_ingest. A probable copy (no shared key; both mailbox rows at time precision with the same bank, amount_minor, currency, direction, last4 and merchant after ASCII lower-casing and white-space folding, at most 600000 ms apart) gets copy_of the earliest live match and stays out of money until txn_copy_resolved {other_txn_id, decision: merge | keep_both | null}. Written by the Swift executor; the TypeScript reference (schema 3) and Go (no fold) do not model v4.",
    cases: [
      FoldGoldenCase(
        name: "certain-merge",
        note: "The same alert in two mailboxes shares its Message-ID: one row stays, the other is its alias; neither sender verified, so the earlier import is canonical.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:00:30", mid: mid)]),
        ]),
      FoldGoldenCase(
        name: "verified-wins",
        note: "The later copy's sender verified and the earlier one's did not: the later copy is canonical and the earlier row becomes its alias.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid, verified: false)]),
          (2, G.w1, [alert(2, grant: R.b, mid: mid, verified: true)]),
        ]),
      FoldGoldenCase(
        name: "reconnect-rescan-no-readd",
        note: "After a reconnect the same message is read again under the same ingest id: it is refused as duplicate_ingest, and the alias list does not grow.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid)]),
          (2, G.w1, [alert(2, grant: R.b, mid: mid)]),
          (3, G.w1, [G.op(
            "txn_ingested",
            #"{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","posted_precision":"time","merchant_raw":"STARBUCKS DIFC","last4":"4412","needs_review":false,"tier":"template","category":null,"entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(R.b)","message_id":"msg-2"},"gates":\#(fail),"dedupe":{"message_id":"\#(mid)"}}"#,
            id: "op-rescan-2", entity: ("txn", G.ulid(12)), ingest: G.ingestID(2))]),
        ]),
      FoldGoldenCase(
        name: "probable-hold",
        note: "No shared id; same bank, amount, card and merchant (case and spacing differ) five minutes apart: the second is held as a copy. Eleven minutes apart, or one fils different, stays separate.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, merchant: "STARBUCKS  DIFC")]),
          (2, G.w1, [alert(2, grant: R.b, merchant: "starbucks difc", at: "08:05:00")]),
          (3, G.w1, [alert(3, grant: R.b, at: "08:11:00"), alert(4, grant: R.b, amount: "2701", at: "08:01:00")]),
        ]),
      FoldGoldenCase(
        name: "keep-both",
        note: "The held copy is kept as its own transaction: copy_decision keep_both, counted again.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:04:00")]),
          (3, G.w2, [resolve(2, other: 1, "keep_both", parent: 1, id: "op-keep-2")]),
        ]),
      FoldGoldenCase(
        name: "merge-then-undo",
        note: "Merge makes the held copy an alias (merge_kind user); the undo (decision null) brings it back as a held copy, live and indexed again.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:04:00")]),
          (3, G.w2, [resolve(2, other: 1, "merge", parent: 1, id: "op-merge-2")]),
          (4, G.w2, [resolve(2, other: 1, nil, parent: 2, id: "op-undo-2")]),
        ]),
      FoldGoldenCase(
        name: "two-identical-coffees",
        note: "Two real coffees, same card, same amount, three minutes apart, from one mailbox: the second is held, Keep both makes it count, and both stay as two rows; a merge of the kept row with the wrong other row is refused.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a)]),
          (2, G.w1, [alert(2, grant: R.a, at: "08:03:00")]),
          (3, G.w2, [resolve(2, other: 1, "keep_both", parent: 1, id: "op-keep-2")]),
          (4, G.w2, [resolve(2, other: 3, "merge", parent: 2, id: "op-wrong-2")]),
        ]),
      FoldGoldenCase(
        name: "retire-promotes-the-copy",
        note: "Removing the canonical row's mailbox brings its alias from the other mailbox back as the live row, with the dedupe key; a copy held against the removed row is released.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid), alert(3, grant: R.a, merchant: "ENOC 1043", at: "12:00:00")]),
          (2, G.w1, [alert(2, grant: R.b, mid: mid), alert(4, grant: R.b, merchant: "ENOC 1043", at: "12:04:00")]),
          (3, G.w1, [R.retire(R.a, legacy: false, id: "op-retire-a")]),
        ]),
      FoldGoldenCase(
        name: "verified-wins-keeps-the-sort",
        note: "The earlier, unverified copy was sorted (txn_categorized, source user) and noted before the verified copy arrived: the verified copy is canonical and takes the sort (category, category_source, needs_review) and the annotations it lacks.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid, verified: false)]),
          (2, G.w2, [R.note, sort(1, "groceries", parent: 1, id: "op-sort-1")]),
          (3, G.w1, [alert(2, grant: R.a, mid: mid, verified: true, message: "msg-2")]),
        ]),
      FoldGoldenCase(
        name: "retire-promotes-the-sort",
        note: "The canonical row was sorted, then its mailbox was removed: the alias brought back as the live row keeps the sort.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid)]),
          (2, G.w1, [alert(2, grant: R.b, mid: mid)]),
          (3, G.w2, [sort(1, "groceries", parent: 1, id: "op-sort-1")]),
          (4, G.w1, [R.retire(R.a, legacy: false, id: "op-retire-a")]),
        ]),
      FoldGoldenCase(
        name: "merge-retire-keep-both",
        note: "One device merges the held copy, then removes its mailbox, which retires it; another device, offline, chose Keep both on the same copy. The late keep_both is refused with duplicate_disposition_mismatch, and the retired row stays out of the live indexes.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:04:00")]),
          (3, G.w1, [resolve(2, other: 1, "merge", parent: 1, id: "op-merge-2")]),
          (4, G.w1, [R.retire(R.b, legacy: false, id: "op-retire-b")]),
          (5, G.w2, [resolve(2, other: 1, "keep_both", parent: 1, id: "op-keep-2")]),
        ]),
    ])
}
