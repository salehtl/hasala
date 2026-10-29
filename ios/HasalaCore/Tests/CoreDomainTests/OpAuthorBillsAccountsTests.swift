// OpAuthor's bills-and-accounts authors (03b §1.4, §3.2-§4.4): the ids of
// §1.4's vectors, each payload exactly as the fold's decoder reads it (the
// canary's own payloads, byte for byte), the author-side refusals, and a fold
// of everything they author with no anomaly.
import CoreJSON
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreDomain

enum OlderCardLink { case mine(account: String), notMine, forget }

extension OpAuthor {
  mutating func olderBuildLinkCard(bank: String?, last4: String, _ state: OlderCardLink) {
    var p: [(String, JSONValue)] = [("bank", bank.map(JSONValue.string) ?? .null), ("last4", .string(last4))]
    switch state {
    case .mine(let account):
      p.append(("state", .string("mine")))
      p.append(("account", .string(account)))
    case .notMine:
      p.append(("state", .string("not_mine")))
    case .forget:
      p.append(("state", .string("forget")))
    }
    add(.cardLinked, p)
  }
}

@Suite("OpAuthor: bills and accounts (03b)")
struct OpAuthorBillsAccountsTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  static func payload(_ op: Op) -> String { JSONWriter().string(op.payload) }

  static func fold(_ ops: [Op], into s: inout State, seq: Int64) throws {
    try Replay.foldOps(ops, seq: seq, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
  }

  @Test("03b §1.4 id vectors: card accounts and Pass A / Pass B detected bills")
  func ids() throws {
    #expect(OpAuthor.cardAccountID(bank: "enbd", last4: "4412") == "ac_57aa6a554d52afd8222b3922452ddf79")
    #expect(OpAuthor.cardAccountID(bank: "dib", last4: "8891") == "ac_f2df1a64b65c78b30b7112933690cbb7")
    #expect(OpAuthor.cardAccountID(bank: nil, last4: "8891") == OpAuthor.cardAccountID(bank: "", last4: "8891"))
    #expect(OpAuthor.detectedBillID(key: "apple.com/bill", direction: "debit", currency: "AED") == "bd_65fba949dd5efbb48b1abcb341fc6645")
    let first = String(repeating: "0123456789abcdef", count: 4)
    #expect(
      OpAuthor.detectedBillID(key: "apple.com/bill", direction: "debit", currency: "AED", firstIngestID: first)
        == "bd_9247d3a805d5440fb449e00b2510dc98")
    let a = OpAuthor(ctx())
    for id in [try a.newAccountID(), try a.newManualBillID(), try a.newCheckinID()] {
      #expect(id.utf8.count == 35 && Grammar.isID(id))
    }
    #expect(try a.newManualBillID().hasPrefix("bm_") && a.newCheckinID().hasPrefix("ck_"))
  }

  @Test("the payloads are the canary's, key for key")
  func canaryPayloads() throws {
    var a = OpAuthor(ctx())
    try a.setAccount(id: OpAuthor.cashAccountID, OpAuthor.AccountDraft(name: "Cash", kind: .cash))
    a.olderBuildLinkCard(bank: "enbd", last4: "4412", .mine(account: "ac_cash"))
    try a.checkIn(
      id: "ck_1", account: "ac_cash", asOfMs: try parseInstantMs("2026-10-10T09:31:20.000Z"), balanceMinor: 50_000,
      source: .checkin, resolution: .kept)
    try a.setBill(
      id: "bd_axa",
      OpAuthor.BillDraft(
        name: "AXA Insurance", keys: ["axa insurance"], mode: .fixed(toleranceBp: 200), amountMinor: 55_000,
        anchor: Self.d("2026-09-07"), start: Self.d("2026-04-07"), category: "insurance", account: "ac_cash", source: .detected))
    a.setBillOccurrence(bill: "bd_axa", due: Self.d("2026-10-07"), .paid(txn: "01JC0000000000000000000002"))
    let ops = try a.build().ops
    #expect(ops.map(\.type) == [.accountSet, .cardLinked, .accountCheckin, .billSet, .billOccurrenceSet])
    #expect(
      Self.payload(ops[0])
        == #"{"id":"ac_cash","name":"Cash","institution":null,"kind":"cash","in_plan":true,"currency":"AED","statement_due_day":null,"active":true,"closed_on":null,"color":null}"#
    )
    #expect(Self.payload(ops[1]) == #"{"bank":"enbd","last4":"4412","state":"mine","account":"ac_cash"}"#)
    #expect(
      Self.payload(ops[2])
        == #"{"id":"ck_1","account":"ac_cash","as_of":"2026-10-10T09:31:20.000Z","balance_minor":"50000","source":"checkin","resolution":"kept","void":false}"#
    )
    #expect(
      Self.payload(ops[3])
        == #"{"name":"AXA Insurance","keys":["axa insurance"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"55000","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-09-07","start":"2026-04-07","end":null,"category":"insurance","account":"ac_cash","source":"detected","status":"active"}"#
    )
    #expect(ops[3].entity == EntityRef(kind: "bill", id: "bd_axa") && ops[3].parentVersion == nil)
    #expect(
      Self.payload(ops[4])
        == #"{"bill":"bd_axa","due":"2026-10-07","resolution":"paid","txn":"01JC0000000000000000000002","until":null}"#)
    var s = State()
    try Self.fold(ops, into: &s, seq: 1)
    #expect(s.accounts["ac_cash"]?.kind == "cash")
    #expect(s.cards["enbd\u{0}4412"]?.account == "ac_cash")
    #expect(s.checkins["ck_1"]?.balanceMinor == 50_000)
    #expect(s.bills["bd_axa"]?.version == 1 && s.bills["bd_axa"]?.toleranceBp == 200)
    #expect(s.billResolutions["bd_axa\u{0}2026-10-07"]?.txn == "01JC0000000000000000000002")
  }

  @Test("accounts, cards, bills, occurrences and check-ins fold as authored; a bill edit takes the next version")
  func lifecycle() throws {
    var s = State()
    let enbd = OpAuthor.cardAccountID(bank: "enbd", last4: "4412")
    var a = OpAuthor(ctx())
    try a.setAccount(
      id: enbd, OpAuthor.AccountDraft(name: "  Emirates NBD ···4412 ", institution: "enbd", kind: .current))
    try a.setAccount(
      id: "ac_f2df1a64b65c78b30b7112933690cbb7",
      OpAuthor.AccountDraft(name: "DIB card", institution: "dib", kind: .creditCard, statementDueDay: 18))
    let sarwa = try a.newAccountID()
    try a.setAccount(id: sarwa, OpAuthor.AccountDraft(name: "Sarwa", kind: .investment, inPlan: false))
    a.olderBuildLinkCard(bank: "enbd", last4: "4412", .mine(account: enbd))
    a.olderBuildLinkCard(bank: "adcb", last4: "1111", .notMine)
    a.olderBuildLinkCard(bank: nil, last4: "2222", .notMine)
    let bill = try a.newManualBillID()
    try a.setBill(
      id: bill,
      OpAuthor.BillDraft(
        name: "DEWA", keys: ["dewa"], mode: .variable, amountMinor: 48_915, anchor: Self.d("2026-10-14"), start: Self.d("2026-04-14"),
        category: "utilities", account: enbd))
    a.setBillOccurrence(bill: bill, due: Self.d("2026-09-14"), .paid(txn: nil))
    a.setBillOccurrence(bill: bill, due: Self.d("2026-08-14"), .skipped)
    a.setBillOccurrence(bill: bill, due: Self.d("2026-10-14"), .snoozed(until: Self.d("2026-10-20")))
    let ck = try a.checkIn(account: sarwa, asOfMs: now, balanceMinor: 18_940_500, source: .update)
    try a.checkIn(account: enbd, asOfMs: now, balanceMinor: -1_000, resolution: .adjusted(-250))
    try Self.fold(try a.build().ops, into: &s, seq: 1)

    #expect(s.accounts[enbd]?.name == "Emirates NBD ···4412")  // NFC, trimmed
    #expect(s.accounts["ac_f2df1a64b65c78b30b7112933690cbb7"]?.statementDueDay == 18)
    #expect(s.accounts[sarwa]?.inPlan == false)
    #expect(s.cards["adcb\u{0}1111"]?.state == "not_mine" && s.cards["\u{0}2222"]?.state == "not_mine")
    #expect(s.bills[bill]?.amountMode == "variable" && s.bills[bill]?.toleranceBp == nil)
    #expect(s.billResolutions.count == 3 && s.billResolutions[bill + "\u{0}2026-10-14"]?.until == "2026-10-20")
    #expect(s.checkins[ck]?.source == "update" && s.checkins.count == 2)

    // Edit the bill (parent 1 → version 2), clear an occurrence, forget a card, void a check-in, close an account.
    var b = OpAuthor(ctx(own: now + 100))
    try b.setBill(
      id: bill, parentVersion: 1,
      OpAuthor.BillDraft(
        name: "DEWA", keys: ["dewa", "dewa bill"], mode: .variable, amountMinor: 50_000, anchor: Self.d("2026-10-14"),
        start: Self.d("2026-04-14"), end: Self.d("2026-12-14"), category: "utilities", account: enbd, status: .cancelled))
    b.setBillOccurrence(bill: bill, due: Self.d("2026-08-14"), .clear)
    b.olderBuildLinkCard(bank: "adcb", last4: "1111", .forget)
    try b.checkIn(id: ck, account: sarwa, asOfMs: now, balanceMinor: 18_940_500, source: .update, void: true)
    try b.setAccount(id: sarwa, OpAuthor.AccountDraft(name: "Sarwa", kind: .investment, inPlan: false, active: false, closedOn: Self.d("2026-10-10")))
    try Self.fold(try b.build().ops, into: &s, seq: 2)
    #expect(s.bills[bill]?.version == 2 && s.bills[bill]?.status == "cancelled" && s.bills[bill]?.keys.count == 2)
    #expect(s.billResolutions[bill + "\u{0}2026-08-14"] == nil)
    #expect(s.cards["adcb\u{0}1111"] == nil)
    #expect(s.checkins[ck]?.void == true)
    #expect(s.accounts[sarwa]?.active == false && s.accounts[sarwa]?.closedOn == "2026-10-10")
  }

  @Test("author-side refusals: closing dates, statement days, bill dates and amounts, resolutions, labels")
  func refusals() throws {
    // 03b §4.2: in_plan defaults by kind; an explicit value wins.
    for kind in OpAuthor.AccountKind.allCases {
      let everyday = [.current, .savings, .creditCard, .cash].contains(kind)
      #expect(OpAuthor.AccountDraft(name: "x", kind: kind).inPlan == everyday, "\(kind)")
      #expect(OpAuthor.AccountDraft(name: "x", kind: kind, inPlan: !everyday).inPlan == !everyday)
    }

    func refused(_ f: (inout OpAuthor) throws(AuthorError) -> Void) -> Bool {
      var a = OpAuthor(ctx())
      do {
        try f(&a)
        _ = try a.build()
        return false
      } catch {
        if case .refused = error { return true }
        return false
      }
    }
    #expect(refused { a throws(AuthorError) in try a.setAccount(id: "ac_cash", OpAuthor.AccountDraft(name: "Cash", kind: .cash, active: false)) })
    #expect(refused { a throws(AuthorError) in
      try a.setAccount(id: "ac_cash", OpAuthor.AccountDraft(name: "Cash", kind: .cash, closedOn: Self.d("2026-10-01")))
    })
    #expect(refused { a throws(AuthorError) in
      try a.setAccount(id: "ac_cash", OpAuthor.AccountDraft(name: "Cash", kind: .cash, statementDueDay: 3))
    })
    #expect(refused { a throws(AuthorError) in try a.setAccount(id: "ac_cash", OpAuthor.AccountDraft(name: "   ", kind: .cash)) })
    let draft = OpAuthor.BillDraft(
      name: "Rent", keys: ["al habtoor"], mode: .fixed(toleranceBp: 0), amountMinor: 750_000, anchor: Self.d("2026-10-01"),
      start: Self.d("2026-04-01"))
    var zero = draft
    zero.amountMinor = 0
    #expect(refused { a throws(AuthorError) in try a.setBill(id: "bm_1", zero) })
    var backwards = draft
    backwards.end = Self.d("2026-03-01")
    #expect(refused { a throws(AuthorError) in try a.setBill(id: "bm_1", backwards) })
    var cancelled = draft
    cancelled.status = .cancelled
    #expect(refused { a throws(AuthorError) in try a.setBill(id: "bm_1", cancelled) })
    #expect(refused { a throws(AuthorError) in
      try a.checkIn(account: "ac_cash", asOfMs: now, balanceMinor: 1, source: .update, resolution: .kept)
    })
    #expect(refused { a throws(AuthorError) in try a.checkIn(account: "ac_cash", asOfMs: now, balanceMinor: 1, resolution: .adjusted(0)) })
    #expect(!refused { a throws(AuthorError) in try a.setBill(id: "bm_1", draft) })
  }

  @Test("payloads outside 03b's grammar are author bugs, refused by build() before anything is enqueued")
  func invalid() throws {
    var a = OpAuthor(ctx())
    a.olderBuildLinkCard(bank: "ENBD", last4: "4412", .notMine)  // a Bank is lower-case
    #expect(throws: AuthorError.self) { try a.build() }
    var b = OpAuthor(ctx())
    try b.setBill(
      id: "bm_1",
      OpAuthor.BillDraft(
        name: "x", keys: [], mode: .variable, amountMinor: 1, anchor: Self.d("2026-10-01"), start: Self.d("2026-09-01")))
    #expect(throws: AuthorError.self) { try b.build() }
  }
}
