// OpAuthor's beta authors and author rules: projects and goals (03c §6, 03a
// §9), duplicate dispositions, rates, the 8 KiB op guard (04 §5.4 S7), user
// text (03c §1.6), rule pause chunking (03c §5.5) and the mailbox supersede
// rule (03c §3.1). Every authored blob is folded and must fold clean.
import CoreCategorize
import CoreJSON
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaText
import Testing

@testable import CoreDomain

@Suite("OpAuthor")
struct OpAuthorTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  /// Folds `ops` at `seq` and expects no anomaly.
  static func fold(_ ops: [Op], _ s: inout State, seq: Int64) throws {
    try Replay.foldOps(ops, seq: seq, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
  }

  @Test("defineProject and defineGoal: create, edit, complete, and the dedicated-category blob")
  func projectsAndGoals() throws {
    var s = State()
    var a = OpAuthor(ctx())
    let pid = try a.defineProject(
      OpAuthor.ProjectDraft(name: " Japan trip ", startsOn: Self.d("2026-12-14"), endsOn: Self.d("2026-12-28"), budgetMinor: 1_200_000, icon: "plane"))
    let cat = try a.newCategoryID()
    a.defineCategory(id: cat, name: "Emergency fund", kind: .spending, bucket: .saving, icon: "jar", active: true)
    let gid = try a.defineGoal(
      OpAuthor.GoalDraft(
        name: "Emergency fund", targetMinor: 5_000_000, targetMonth: CivilMonth(year: 2027, month: 1), source: .category(id: cat, since: Self.d("2026-01-01")),
        startingMinor: 3_000_000, icon: "jar"))
    let blob = try a.build()
    #expect(blob.ops.map(\.type) == [.projectDefined, .categoryDefined, .goalDefined])
    try Self.fold(blob.ops, &s, seq: 1)
    let p = try #require(s.projects[pid])
    #expect(p.name == "Japan trip" && p.budgetMinor == 1_200_000 && !p.countInPlan && p.status == "active" && p.icon == "plane")
    let g = try #require(s.goals[gid])
    #expect(g.targetMinor == 5_000_000 && g.startingMinor == 3_000_000 && g.source.categoryID == cat && g.targetMonth == "2027-01")

    // Mark complete: a whole-record edit on the projected version.
    var b = OpAuthor(ctx(own: blob.lastAuthoredMs))
    var done = OpAuthor.ProjectDraft(name: "Japan trip", status: .completed, completedOn: Self.d("2026-12-29"))
    try b.defineProject(id: pid, parentVersion: p.version, done)
    try Self.fold(try b.build().ops, &s, seq: 2)
    #expect(s.projects[pid]?.status == "completed" && s.projects[pid]?.completedOn == "2026-12-29" && s.projects[pid]?.icon == "flag")

    // Refusals the editor shows inline.
    var c = OpAuthor(ctx())
    done.completedOn = nil
    #expect(throws: AuthorError.refused("a completed record needs its completion date")) { try c.defineProject(done) }
    #expect(throws: AuthorError.refused("the end date is before the start date")) {
      try c.defineProject(OpAuthor.ProjectDraft(name: "x", startsOn: Self.d("2026-12-14"), endsOn: Self.d("2026-12-01")))
    }
    #expect(throws: AuthorError.refused("an account goal starts from the account's balance")) {
      try c.defineGoal(OpAuthor.GoalDraft(name: "Car", targetMinor: 100, source: .account(id: "ac_cash"), startingMinor: 5))
    }
    #expect(throws: AuthorError.refused("the target must be more than 0")) {
      try c.defineGoal(OpAuthor.GoalDraft(name: "Car", targetMinor: 0, source: .account(id: "ac_cash")))
    }
    var e = OpAuthor(ctx())
    try e.defineGoal(OpAuthor.GoalDraft(name: "Car", targetMinor: 100, source: .account(id: "ac_cash")))
    #expect(try e.build().ops.count == 1)
  }

  @Test("resolveDuplicate settles the duplicate lane")
  func duplicate() throws {
    var s = State()
    var a = OpAuthor(ctx())
    let first = try a.manualEntry(amountMinor: 1_000, currency: "AED", direction: "debit", localWallMs: now, merchant: "CAFE", category: "dining")
    let second = try a.manualEntry(amountMinor: 1_000, currency: "AED", direction: "debit", localWallMs: now, merchant: "CAFE", category: "dining")
    let blob = try a.build()
    try Replay.foldOps(blob.ops, seq: 1, writerID: w, into: &s)
    let t = try #require(s.txns[second])
    #expect(t.possibleDuplicateOf == first && ReviewQueue.lane(t) == .duplicate)
    var b = OpAuthor(ctx(own: blob.lastAuthoredMs))
    b.resolveDuplicate(txnID: second, parentVersion: t.version, otherTxnID: first, disposition: .different)
    let before = s.anomalies.count
    try Replay.foldOps(try b.build().ops, seq: 2, writerID: w, into: &s)
    #expect(s.anomalies.count == before)
    let resolved = try #require(s.txns[second])
    #expect(resolved.duplicateDisposition == "different" && ReviewQueue.lane(resolved) != .duplicate)
  }

  @Test("setRate and unsetRate")
  func rates() throws {
    var s = State()
    var a = OpAuthor(ctx())
    a.setHomeCurrency("AED")
    try a.setRate(currency: "USD", rateMicro: 3_672_500)
    try a.setRate(currency: "JPY", rateMicro: 24_500)
    a.unsetRate(currency: "JPY")
    try Self.fold(try a.build().ops, &s, seq: 1)
    #expect(s.rates["USD"] == .some(3_672_500))
    #expect(s.rates["JPY"] == .some(nil))
    var b = OpAuthor(ctx())
    #expect(throws: AuthorError.refused("the rate must be more than 0")) { try b.setRate(currency: "USD", rateMicro: 0) }
  }

  @Test("an op over 8 KiB of canonical JSON is refused (S7)")
  func sizeGuard() throws {
    func payload(_ merchant: String) -> JSONObject {
      JSONObject([
        ("amount_minor", .string("100")), ("currency", .string("AED")), ("direction", .string("debit")),
        ("posted_at", .string("2026-10-09T15:12:00.000Z")), ("merchant_raw", .string(merchant)), ("last4", .string("4412")),
        ("tier", .string("template")), ("needs_review", .bool(true)), ("entry_method", .string("mailbox")),
      ])
    }
    var a = OpAuthor(ctx())
    try a.ingest(payload: payload(String(repeating: "x", count: 9_000)), ingestID: String(repeating: "a", count: 64))
    #expect {
      try a.build()
    } throws: { e in
      guard case .opTooLarge(let type, let bytes) = e as? AuthorError else { return false }
      return type == "txn_ingested" && bytes > OpAuthor.maxOpBytes
    }
    // Just under the limit passes, and the measure is the wire's own bytes.
    var b = OpAuthor(ctx())
    try b.ingest(payload: payload(String(repeating: "x", count: 7_000)), ingestID: String(repeating: "a", count: 64))
    let ops = try b.build().ops
    let wire = try OpCodec.encodeBlobOps(ops)
    let envelope = #"{"v":4,"kind":"ops","ops":[]}"#.utf8.count
    #expect(OpAuthor.canonicalSize(ops[0]) == wire.count - envelope)
  }

  @Test("user text is NFC-normalized and trimmed; empty text is a refusal, not an author bug")
  func userText() throws {
    #expect(UserText.normalize("  Carrefour \u{00A0}\n") == "Carrefour")
    #expect(UserText.normalize("Cafe\u{0301}").unicodeScalars.map(\.value) == "Café".precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
    #expect(UserText.normalize(" \u{3000} ") == "")

    var a = OpAuthor(ctx())
    a.renameMerchant(raw: "CARREFOUR MOE", to: "Carrefour ")
    a.annotate(txnID: "01JC0000000000000000000001", set: [("note", " Cafe\u{0301} with Sara\n")])
    a.defineCategory(id: "c_01jc0000000000000000000002", name: "\u{2003}Pets", kind: .spending, bucket: .want, icon: "paw", active: true)
    a.renameMerchant(raw: "ZUMA", to: "   ")
    let ops = try a.build().ops
    #expect(ops[0].payload["display_name"]?.stringValue == "Carrefour")
    let note = ops[1].payload["set"]?.objectValue?["note"]?.stringValue
    #expect(note == "Caf\u{00E9} with Sara" && note?.unicodeScalars.count == 14)
    #expect(ops[2].payload["name"]?.stringValue == "Pets")
    #expect(ops[3].payload["display_name"] == .null)

    var b = OpAuthor(ctx())
    b.defineCategory(id: "c_01jc0000000000000000000003", name: " \n ", kind: .spending, bucket: .want, icon: nil, active: true)
    #expect(throws: AuthorError.refused("name: \(TextViolation.empty)")) { try b.build() }
    var c = OpAuthor(ctx())
    _ = try c.manualEntry(amountMinor: 1, currency: "AED", direction: "debit", localWallMs: now, merchant: " ", category: nil)
    #expect(throws: AuthorError.refused("merchant: \(TextViolation.empty)")) { try c.build() }
    var d = OpAuthor(ctx())
    try d.defineProject(OpAuthor.ProjectDraft(name: String(repeating: "a", count: 65)))
    #expect(throws: AuthorError.refused("name: \(TextViolation.tooManyScalars(max: 64))")) { try d.build() }
  }

  @Test("pausing a rule holds its rows in blobs of at most 500 ops, the rule edit first")
  func ruleChunks() throws {
    let rule = OpAuthor.RuleSnapshot(
      id: "01JC00000000000000000000R1", version: 1, draft: .init(patterns: ["lulu"], match: .contains, category: "groceries"))
    let rows = (0..<1_200).map { i in (id: String(format: "01JC0000000000000000%06d", i), version: Int64(1), category: "groceries") }
    let blobs = try OpAuthor.setRule(rule, enabled: false, heldRows: rows, context: ctx())
    #expect(blobs.map(\.ops.count) == [500, 500, 201])
    #expect(blobs[0].ops[0].type == .ruleAdded && blobs[0].ops[0].payload["enabled"] == .bool(false))
    let held = blobs.flatMap(\.ops).dropFirst()
    #expect(held.allSatisfy { $0.type == .txnCategorized && $0.payload["needs_review"] == .bool(true) })
    #expect(held.allSatisfy { $0.payload["source"]?.objectValue?["kind"]?.stringValue == "held" })
    let stamps = blobs.flatMap(\.ops).map(\.authoredAt)
    #expect(stamps == stamps.sorted() && Set(stamps).count == stamps.count)
    // Re-enabling is the rule edit alone.
    let on = try OpAuthor.setRule(rule, enabled: true, heldRows: rows, context: ctx())
    #expect(on.map(\.ops.count) == [1])
  }

  @Test("a mailbox supersede keeps a person's category (03c §3.1)")
  func supersede() throws {
    // One random source for the whole story, so each author mints fresh ids.
    let random = Counter()
    func ctx(own: Int64? = nil) -> AuthorContext { AuthorContext(writerID: w, nowMs: now, ownLastMs: own, maxAuthored: [:], random: random) }
    var s = State()
    var a = OpAuthor(ctx())
    let p = JSONObject([
      ("amount_minor", .string("34215")), ("currency", .string("AED")), ("direction", .string("debit")),
      ("posted_at", .string("2026-10-09T15:12:00.000Z")), ("merchant_raw", .string("CARREFOUR MOE")), ("last4", .string("4412")),
      ("tier", .string("template")), ("needs_review", .bool(true)), ("entry_method", .string("mailbox")),
    ])
    let ingest = String(repeating: "a", count: 64)
    let id = try a.ingest(payload: p, ingestID: ingest)
    let blob1 = try a.build()
    try Self.fold(blob1.ops, &s, seq: 1)
    var b = OpAuthor(ctx(own: blob1.lastAuthoredMs))
    b.categorize(txnID: id, parentVersion: s.txns[id]!.version, category: "dining")
    let blob2 = try b.build()
    try Self.fold(blob2.ops, &s, seq: 2)

    // The template fix re-reads the email; the pipeline now says groceries.
    let decision = Decision(category: "groceries", source: .dictionary(bundle: "2026.10.11-1", entry: "contains:carrefour"), display: nil, suggested: nil)
    var fixed = p
    for (k, v) in OpAuthor.decisionFields(decision) { fixed[k] = v }
    let pred = OpAuthor.CategoryState(category: s.txns[id]!.category, source: s.txns[id]!.categorySource ?? CategorySource.none)
    var c = OpAuthor(ctx(own: blob2.lastAuthoredMs))
    let next = try c.ingest(payload: fixed, ingestID: ingest, superseding: true, predecessor: pred)
    try Self.fold(try c.build().ops, &s, seq: 3)
    #expect(s.txns[next]?.category == "dining" && s.txns[next]?.categorySource?.kind == .user)

    // A predecessor filed by automation takes the new decision.
    let auto = OpAuthor.CategoryState(category: "shopping", source: CategorySource(kind: .rule, ruleID: "01JC00000000000000000000R1"))
    let fields = try #require(OpAuthor.supersedeFields(predecessor: auto, decision: decision))
    #expect(fields.first { $0.0 == "category" }?.1 == .string("groceries"))
    let held = OpAuthor.CategoryState(category: "shopping", source: CategorySource(kind: .held, ruleID: "01JC00000000000000000000R1"))
    #expect(OpAuthor.supersedeFields(predecessor: held, decision: decision)?.first { $0.0 == "category" }?.1 == .string("shopping"))
  }
}
