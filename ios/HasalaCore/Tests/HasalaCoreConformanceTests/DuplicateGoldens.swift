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

  static func dib(
    _ n: Int, template: String, merchant: String, last4: String, at: String, amount: String = "314159", grant: String = R.a,
    verified: Bool = true, kind: String? = nil
  ) -> String {
    let trust = verified ? #""ar":"pass","sender":"trusted""# : #""ar":"fail","sender":"untrusted""#
    let marker = kind.map { #","kind":"\#($0)""# } ?? ""
    let p =
      #"{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"2026-10-03T\#(at).000Z","posted_precision":"time","merchant_raw":"\#(merchant)","last4":"\#(last4)","needs_review":true,"tier":"template","category":null,"entry_method":"mailbox","bank":"dib","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"msg-\#(n)"},"gates":{\#(trust),"template":"\#(template)","card":"unknown","forwarded":false\#(marker)}}"#
    return G.op("txn_ingested", p, id: "op-ingest-\(n)", entity: ("txn", G.ulid(n)), ingest: G.ingestID(n))
  }

  static func notice(_ n: Int, at: String, amount: String = "314159", verified: Bool = true) -> String {
    dib(n, template: "dib.transfer.v1@1", merchant: "DIB TRANSFER", last4: "0909", at: at, amount: amount, verified: verified)
  }

  static func debitAlert(_ n: Int, at: String, merchant: String = "MB FUND TRANSFER DEBIT", amount: String = "314159") -> String {
    dib(n, template: "dib.account.v1@3", merchant: merchant, last4: "0606", at: at, amount: amount)
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
      "Copies of one bank alert across mailboxes (and within one, after a reconnect). A v4 txn_ingested may carry dedupe {message_id, bank_ref}: 32 lower-case hex digits each (message_id is the first 16 bytes of SHA-256 over the RFC 5322 Message-ID, angle brackets dropped, ASCII lower-cased). A certain copy (a dedupe key already in byDedupeKey on a live row) merges at once: the copy whose gates say ar pass and sender trusted wins, else the earlier one; the other gets merged_into, merge_kind certain and merge_op, leaves the live indexes, and becomes an alias on the canonical row. Re-ingesting a merged copy's ingest id is a duplicate_ingest. A probable copy (no shared key; both mailbox rows at time precision with the same bank, amount_minor, currency, direction, last4 and merchant after ASCII lower-casing and white-space folding, at most 600000 ms apart) gets copy_of the earliest live match and stays out of money until txn_copy_resolved {other_txn_id, decision: merge | keep_both | null}. A transfer notice (gates.template dib.transfer.v1 or dib.money-transfer.v1) and an account alert (dib.account.v1) of one bank, both mailbox debits at time precision with the same amount_minor and currency at most 1800000 ms apart, are one transfer whatever their merchant and last4: the later gets copy_of the nearest earlier row of the other kind that is live, not held, and has no held or merged copy of the other kind against it. A row without one of these templates takes its role from gates.kind (transfer_notice or account_debit_alert; another value, or a value that is not a string, is dropped). When both rows of a transfer pair say ar pass and sender trusted, the later is merged into the earlier at once (merge_kind transfer, merge_op the ingest op, registered under its dedupe keys) and nobody is asked; txn_copy_resolved keep_both takes it out again, and a null decision merges it again. A pair with an unverified row is held as before. Written by the Swift executor; the ledgerd TypeScript fold (schema 3, removed) and Go (no fold) do not model v4.",
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
      FoldGoldenCase(
        name: "edit-on-merged-copy-forwards",
        note: "Another device, offline, sorted and noted the copy that became an alias: the sort and the note reach the canonical row, which had neither.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:00:30", mid: mid)]),
          (3, G.w2, [
            sort(2, "groceries", parent: 1, id: "op-sort-2"),
            G.op("txn_annotated", #"{"txn_id":"\#(G.ulid(2))","set":{"note":"Team lunch"}}"#, id: "op-note-2"),
          ]),
        ]),
      FoldGoldenCase(
        name: "edit-on-merged-copy-keeps-the-canonical-sort",
        note: "The canonical row was already sorted: a late sort of the alias stays on the alias, and the canonical row keeps its own.",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a, mid: mid)]),
          (2, G.w1, [alert(2, grant: R.b, at: "08:00:30", mid: mid)]),
          (3, G.w1, [sort(1, "transport", parent: 1, id: "op-sort-1")]),
          (4, G.w2, [sort(2, "groceries", parent: 1, id: "op-sort-2")]),
        ]),
      FoldGoldenCase(
        name: "legacy-categorize-on-v4-row",
        note: "A below-v4 txn_categorized on a v4 row carries no source: the source follows the category (user when set, none when cleared).",
        blobs: [
          (1, G.w1, [alert(1, grant: R.a), alert(2, grant: R.a, merchant: "ENOC 1043", at: "12:00:00")]),
          (2, G.w2, [
            legacy(#"{"category":"groceries","needs_review":false}"#, entity: 1, id: "op-legacy-1"),
            sort(2, "transport", parent: 1, id: "op-sort-2"),
          ]),
          (3, G.w2, [legacy(#"{"category":null,"needs_review":false}"#, entity: 2, parent: 2, id: "op-legacy-2")]),
        ]),
      FoldGoldenCase(
        name: "transfer-notice-holds-its-alert",
        note: "A DIB transfer notice, then the account debit alert for the same transfer three minutes later, with its own merchant and card: the alert is merged into the notice. A same-amount alert two hours later stays its own row.",
        blobs: [
          (1, G.w1, [notice(1, at: "10:00:00")]),
          (2, G.w1, [debitAlert(2, at: "10:03:00")]),
          (3, G.w1, [debitAlert(3, at: "12:00:00", merchant: "OWN ACCOUNT TRNSFER")]),
        ]),
      FoldGoldenCase(
        name: "transfer-window",
        note: "A notice and an alert thirty minutes and one second apart stay two rows; another amount's notice and alert exactly thirty minutes apart are one transfer.",
        blobs: [
          (1, G.w1, [notice(1, at: "10:00:00"), debitAlert(2, at: "10:30:01")]),
          (2, G.w1, [notice(3, at: "11:00:00", amount: "271828"), debitAlert(4, at: "11:30:00", amount: "271828")]),
        ]),
      FoldGoldenCase(
        name: "transfer-alert-then-notice",
        note: "The alert arrives first and the English notice twenty minutes later: the notice is the merged copy.",
        blobs: [
          (1, G.w1, [debitAlert(1, at: "10:00:00")]),
          (2, G.w1, [dib(2, template: "dib.money-transfer.v1@1", merchant: "SAMPLE BANK PJSC", last4: "0202", at: "10:20:00")]),
        ]),
      FoldGoldenCase(
        name: "transfer-one-to-one",
        note: "Two same-amount transfers twenty minutes apart, each with its alert, and a third alert: each alert is merged into the nearest notice that has none, the notices never pair with each other, and the third alert stays its own row.",
        blobs: [
          (1, G.w1, [notice(1, at: "10:00:00"), notice(2, at: "10:20:00")]),
          (2, G.w1, [debitAlert(3, at: "10:01:00"), debitAlert(4, at: "10:21:00")]),
          (3, G.w1, [debitAlert(5, at: "10:22:00", merchant: "OWN ACCOUNT TRNSFER")]),
        ]),
      FoldGoldenCase(
        name: "transfer-keep-both-then-undo",
        note: "The person says the merged alert is its own movement (keep_both), then undoes that (null): the alert is merged into the notice again.",
        blobs: [
          (1, G.w1, [notice(1, at: "10:00:00"), debitAlert(2, at: "10:02:00")]),
          (2, G.w1, [resolve(2, other: 1, "keep_both", parent: 1, id: "op-keep-2")]),
          (3, G.w1, [resolve(2, other: 1, nil, parent: 2, id: "op-undo-2")]),
        ]),
      FoldGoldenCase(
        name: "transfer-by-kind-marker",
        note: "Two rows read without a template carry gates.kind transfer_notice and account_debit_alert: they pair as a template pair does. A third row's unknown kind is dropped and it stays its own row.",
        blobs: [
          (1, G.w1, [dib(1, template: "none", merchant: "SAMPLE PAYEE", last4: "0909", at: "10:00:00", kind: "transfer_notice")]),
          (2, G.w1, [dib(2, template: "none", merchant: "ACCOUNT DEBIT", last4: "0606", at: "10:04:00", kind: "account_debit_alert")]),
          (3, G.w1, [dib(3, template: "none", merchant: "OTHER PAYEE", last4: "0606", at: "10:06:00", kind: "card_purchase")]),
        ]),
      FoldGoldenCase(
        name: "transfer-unverified-held",
        note: "The notice's sender did not verify: its alert is held as its copy for the person, as before.",
        blobs: [
          (1, G.w1, [notice(1, at: "10:00:00", verified: false), debitAlert(2, at: "10:03:00")]),
        ]),
    ])

  static func legacy(_ payload: String, entity: Int, parent: Int = 1, id: String) -> String {
    G.op("txn_categorized", payload, id: id, entity: ("txn", G.ulid(entity)), parent: parent)
      .replacingOccurrences(of: #"{"v":4,"#, with: #"{"v":3,"#)
  }
}
