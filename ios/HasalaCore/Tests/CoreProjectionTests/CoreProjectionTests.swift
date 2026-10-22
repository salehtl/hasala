// CoreProjection: the Maya scenario of spec 03a §7 end to end — authored by
// OpAuthor, folded by CoreReplay, projected into SQLite, read back through
// LedgerReader and computed by PlanEngine — against the worked example's
// figures (03a §7.2), plus the projection's own contracts.
import CoreCategorize
import CoreDomain
import CoreInvariants
import CoreReplay
import CoreTime
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite("Maya, Sat 10 Oct 2026 (03a §7)")
struct MayaScenarioTests {
  static let maya = try! Maya()
  static let dictionary = try! MerchantDictionary.bundled().get()

  static func projected() throws -> (LedgerReader, PlanEngine) {
    let db = try Projector.open(path: nil)
    try Projector.project(maya.state, dictionary: dictionary, projectedAtMs: Maya.nowMs, into: db)
    let reader = LedgerReader(db)
    return (reader, try reader.planEngine(month: Maya.october, today: Maya.today, bills: Maya.bills()))
  }

  @Test("the log folds clean")
  func foldsClean() {
    #expect(Self.maya.state.anomalies.isEmpty)
    #expect(Self.maya.state.forks.isEmpty)
    #expect(Self.maya.state.unreadable.isEmpty)
    #expect(!Invariants.halts(Invariants.check(Self.maya.state)))
  }

  @Test("plan income, planned, ready to assign, split")
  func plan() throws {
    let (_, e) = try Self.projected()
    let m = Maya.october
    #expect(e.income(m).total == 2_500_000)
    #expect(e.planned(m) == 2_400_000)
    #expect(e.readyToAssign(m) == 100_000)
    #expect(e.splitShares(m) == [.need: 51, .want: 28, .saving: 21])
    let b = Dictionary(uniqueKeysWithValues: e.buckets(m).map { ($0.bucket, $0) })
    #expect(b[.need]?.assigned == 1_235_000 && b[.need]?.spent == 904_080 && b[.need]?.left == 330_920)
    #expect(b[.want]?.assigned == 665_000 && b[.want]?.spent == 124_754 && b[.want]?.left == 540_246)
    #expect(e.savingsDone(m))
  }

  @Test("the everyday hero: 7,417.55 left, on track, about 337 a day")
  func hero() throws {
    let (_, e) = try Self.projected()
    let h = e.hero(Maya.october)
    #expect(h.budget == 970_000)
    #expect(h.spent == 228_245)
    #expect(h.left == 741_755)
    #expect(h.pace.verdict == .onTrack)
    #expect(h.pace.allowancePerDay == 33_716)
    #expect(h.pace.usedPercent == 23 && h.pace.monthPercent == 32)
    #expect(h.billsPaid == 800_589)
    #expect(h.billsToCome == 103_915)
  }

  @Test("category rows: groceries and dining over pace, the run-out days")
  func rows() throws {
    let (_, e) = try Self.projected()
    let rows = Dictionary(uniqueKeysWithValues: e.categoryRows(Maya.october).map { ($0.info.id, $0) })
    let g = try #require(rows["groceries"])
    #expect(g.spent == 81_240 && g.left == 138_760 && g.pace.verdict == .overPace && g.pace.projection == 251_844)
    #expect(g.pace.runOutDay == 28)
    let d = try #require(rows["dining"])
    #expect(d.spent == 64_275 && d.left == 95_725 && d.pace.verdict == .overPace)
    #expect(d.pace.projection == 199_252 && d.pace.allowancePerDay == 4_351 && d.pace.dailyBudget == 5_161)
    #expect(d.pace.runOutDay == 25 && d.pace.daysEarly == 6)
    for id in ["transport", "healthcare", "entertainment", "shopping"] { #expect(rows[id]?.pace.verdict == .onTrack, "\(id)") }
    #expect(rows["travel"]?.spent == 0 && rows["travel"]?.assigned == 250_000)
    #expect(rows["rent"]?.role == "bills" && rows["subscriptions"]?.spent == 7_799)
    #expect(rows["debt"] == nil)
  }

  @Test("the emergency fund: 38,500 of 50,000, 77%, 3,625 a month to January")
  func goal() throws {
    let (reader, e) = try Self.projected()
    let (id, g) = try #require(try reader.goals().first)
    let p = e.goalProgress(id: id, g, month: Maya.october)
    #expect(p.progress == 3_850_000 && p.percent == 77 && p.required == 362_500)
  }

  @Test("the Japan trip: 4,860 spent, 7,140 left, carved out of September")
  func trip() throws {
    let (_, e) = try Self.projected()
    let spent = e.projectSpent(Self.maya.ids["project"]!)
    #expect(spent == 486_000)
    #expect(1_200_000 - spent == 714_000)
    #expect(e.spent(Maya.september, "travel") == 0)
    #expect(e.spent(Maya.september, "dining") == 148_620)
  }

  @Test("F6: auto-assign on the 10 October state allocates exactly 1,000.00")
  func autoAssign() throws {
    let (_, e) = try Self.projected()
    let alloc = e.autoAssign(Maya.october)
    #expect(alloc.map(\.category) == ["utilities", "savings", "groceries", "transport", "healthcare", "dining", "entertainment", "shopping", "travel"])
    #expect(alloc.map(\.amount) == [1_705, 62_500, 3_132, 1_281, 428, 7_861, 2_948, 7_861, 12_284])
    #expect(alloc.reduce(0) { $0 + $1.amount } == 100_000)
    // Applied as one blob of moves, Ready to assign reaches 0.
    var s = Self.maya.state
    var a = OpAuthor(Self.maya.context())
    a.autoAssign(month: Maya.october, alloc, batchID: "b1")
    try Replay.foldOps(try a.build().ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: Maya.nowMs, into: db)
    let after = try LedgerReader(db).planEngine(month: Maya.october, today: Maya.today, bills: Maya.bills())
    #expect(after.readyToAssign(Maya.october) == 0)
    #expect(after.assigned(Maya.october, "groceries") == 223_132)
    #expect(after.assigned(Maya.november, "groceries") == 220_000)
  }

  @Test("03a §7.3-§7.4: change Dining's budget, move money, undo")
  func changeAndMove() throws {
    var s = Self.maya.state
    var a = OpAuthor(Self.maya.context())
    a.setBudget(category: "dining", month: Maya.october, amountMinor: 180_000)
    try Replay.foldOps(try a.build().ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    var e = PlanEngine(plan: s.plan, taxonomy: TaxonomyView(state: s), lines: try Self.projected().1.lines, bills: Maya.bills(), today: Maya.today)
    #expect(e.assigned(Maya.october, "dining") == 180_000 && e.assigned(Maya.november, "dining") == 180_000)
    #expect(e.readyToAssign(Maya.october) == 80_000 && e.hero(Maya.october).left == 761_755)
    var m = OpAuthor(Self.maya.context())
    m.moveMoney(month: Maya.october, from: nil, to: "groceries", amountMinor: 31_800)
    let moveOps = try m.build().ops
    try Replay.foldOps(moveOps, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    e = PlanEngine(plan: s.plan, taxonomy: TaxonomyView(state: s), lines: e.lines, bills: Maya.bills(), today: Maya.today)
    #expect(e.assigned(Maya.october, "groceries") == 251_800 && e.assigned(Maya.november, "groceries") == 220_000)
    #expect(e.readyToAssign(Maya.october) == 48_200)
    var u = OpAuthor(Self.maya.context())
    u.moveMoney(month: Maya.october, from: "groceries", to: nil, amountMinor: 31_800, reason: "undo", undoes: moveOps[0].opID)
    try Replay.foldOps(try u.build().ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    e = PlanEngine(plan: s.plan, taxonomy: TaxonomyView(state: s), lines: e.lines, bills: Maya.bills(), today: Maya.today)
    #expect(e.assigned(Maya.october, "groceries") == 220_000 && e.readyToAssign(Maya.october) == 80_000)
    #expect(s.anomalies.isEmpty)
  }

  @Test("review: six to sort, AED 827.28 of debits; 26 rows this month")
  func review() throws {
    let (reader, _) = try Self.projected()
    let queue = try reader.review()
    #expect(queue.count == 6)
    #expect(queue.filter { $0.direction == "debit" }.reduce(0) { $0 + $1.amountMinor } == 82_728)
    #expect(try reader.reviewCounts()[.needsReview] == 6)
    #expect(try reader.activity(month: Maya.october, limit: 100).count == 26)
  }

  @Test("category members: live, parsed, unsplit rows of one category, archived included")
  func categoryMembers() throws {
    let (reader, _) = try Self.projected()
    let all = try reader.activity(limit: 100_000) + reader.archived(limit: 100_000)
    let used = Set(all.compactMap(\.category))
    #expect(!used.isEmpty)
    for category in used {
      let expected = all.filter { $0.category == category && !$0.split && !$0.unparsed }.sorted {
        $0.postedMs != $1.postedMs ? $0.postedMs > $1.postedMs : $0.id > $1.id
      }
      let members = try reader.categoryMembers(category)
      #expect(members.map(\.id) == expected.map(\.id), "\(category)")
      #expect(members.map(\.version) == expected.map(\.version) && members.map(\.needsReview) == expected.map(\.needsReview))
    }
    #expect(try reader.categoryMembers("no_such_category").isEmpty)
  }
}

@Suite("CoreProjection contracts")
struct ProjectionContractTests {
  static let dictionary = try! MerchantDictionary.bundled().get()

  @Test("meta: complete after a projection, current version and fold print")
  func meta() throws {
    let db = try Projector.open(path: nil)
    let reader = LedgerReader(db)
    #expect(try reader.isUsable() == false)
    try Projector.project(State(), dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    #expect(try reader.isUsable())
    #expect(try reader.meta()?.cursorHot == 0)
    #expect(try reader.taxonomy().ordered.count == 18)
  }

  @Test("a custom category's parent is projected and read back")
  func categoryParent() throws {
    let maya = try Maya()
    var s = maya.state
    var a = OpAuthor(maya.context())
    let id = try a.createCategory(name: "Coffee", parent: "dining", icon: "cup", in: TaxonomyView(state: s))
    try Replay.foldOps(try a.build().ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let t = try LedgerReader(db).taxonomy()
    #expect(t.info(id)?.parent == "dining" && t.info(id)?.bucket == .want)
    #expect(t.info("dining")?.parent == nil)
    #expect(t.ordered == TaxonomyView(state: s).ordered)
  }

  @Test("display names: rename beats the dictionary beats prettify; local dates at +04:00")
  func displayAndDates() throws {
    let maya = try Maya()
    var s = maya.state
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let reader = LedgerReader(db)
    let careem = try #require(try reader.txn(maya.ids["careem"]!))
    #expect(careem.displayName == "Careem")  // dictionary `d`
    #expect(careem.localDate == "2026-10-09" && careem.postedAt == "2026-10-09T19:40:00.000Z")
    let ikea = try #require(try reader.txn(maya.ids["ikea"]!))
    #expect(ikea.displayName == "IKEA")
    let rent = try #require(try reader.txn(maya.ids["rent"]!))
    #expect(rent.displayName == "Al Habtoor Properties")  // prettify
    // Rename the merchant: every row with its key follows.
    var a = OpAuthor(maya.context())
    a.renameMerchant(raw: "TALABAT", to: "Talabat (food)")
    let blob = try a.build()
    try Replay.foldOps(blob.ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: 2, into: db)
    #expect(try reader.txn(maya.ids["talabat1"]!)?.displayName == "Talabat (food)")
    #expect(try reader.txn(maya.ids["talabat2"]!)?.displayName == "Talabat (food)")
  }

  @Test("project roll-ups read every month, not just the plan engine's window (03c §6.1)")
  func projectAllMonths() throws {
    var maya = try Maya()
    let project = maya.ids["project"]!
    try maya.txn("deposit", "JAPAN TOURS DEPOSIT", 50_000, "2026-03-05", category: "travel")
    try maya.txn("ryokan", "KYOTO RYOKAN", 120_000, "2026-12-20", category: "travel")
    for k in ["deposit", "ryokan"] {
      let id = maya.ids[k]!
      try maya.commit { a in a.annotate(txnID: id, set: [("project_id", project)]) }
    }
    let db = try Projector.open(path: nil)
    try Projector.project(maya.state, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let e = try LedgerReader(db).planEngine(month: Maya.october, today: Maya.today, bills: Maya.bills())
    #expect(e.projectSpent(project) == 486_000 + 50_000 + 120_000)
    #expect(!e.lines.contains { $0.txnID == maya.ids["deposit"]! })
  }

  @Test("the pending overlay marks the rows an outbox op touches, and is rebuilt each time")
  func pending() throws {
    let maya = try Maya()
    let lulu = maya.ids["lulu"]!
    var a = OpAuthor(maya.context())
    a.categorize(txnID: lulu, parentVersion: maya.state.txns[lulu]!.version, category: "groceries")
    let blob = try a.build()
    let db = try Projector.open(path: nil)
    try Projector.project(maya.state, pending: [blob.ops], writerID: Maya.writer, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let reader = LedgerReader(db)
    let row = try #require(try reader.txn(lulu))
    #expect(row.pending && row.category == "groceries" && row.reviewLane == nil)
    #expect(try reader.review().count == 5)
    #expect(try reader.meta()?.cursorHot == maya.state.cursors.hot)
    try Projector.project(maya.state, dictionary: Self.dictionary, projectedAtMs: 2, into: db)
    #expect(try reader.txn(lulu)?.pending == false)
  }

  @Test("splits apportion the home amount; money_line carries the parts")
  func splits() throws {
    let maya = try Maya()
    var s = maya.state
    let carrefour = maya.ids["carrefour"]!
    var a = OpAuthor(maya.context())
    a.split(txnID: carrefour, parentVersion: s.txns[carrefour]!.version, parts: [("groceries", 29_700, nil), ("shopping", 4_515, "Kitchen towels")])
    try Replay.foldOps(try a.build().ops, seq: s.cursors.hot + 1, writerID: Maya.writer, into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let reader = LedgerReader(db)
    let parts = try reader.parts(carrefour)
    #expect(parts.map(\.amountHomeMinor) == [29_700, 4_515])
    let lines = try reader.moneyLines(from: Maya.october.firstDay, to: Maya.october.lastDay).filter { $0.txnID == carrefour }
    #expect(lines.map(\.category) == ["groceries", "shopping"])
  }

  @Test("sweep rows exclude user rows from re-filing; query domains come from trust")
  func sweepAndTrust() throws {
    let maya = try Maya()
    let db = try Projector.open(path: nil)
    try Projector.project(maya.state, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
    let reader = LedgerReader(db)
    #expect(try reader.queryDomains() == ["emiratesnbd.com"])
    let taxonomy = try reader.taxonomy()
    let c = Categorizer(rules: [], dictionary: Self.dictionary, categories: taxonomy)
    let (actions, queue) = Sweep.plan(try reader.sweepRows(), c)
    // Only uncategorized review rows are candidates for re-filing: the dictionary files Lulu,
    // Dubai Taxi and Apple; Steam and the ATM join the model queue.
    #expect(Set(actions.map(\.txnID)) == Set(["lulu", "dubaitaxi", "apple"].map { maya.ids[$0]! }))
    #expect(actions.allSatisfy { $0.needsReview })
    #expect(Set(queue.map(\.id)) == Set(["steam", "atm"].map { maya.ids[$0]! }))
    #expect(try reader.knownMailboxMessageIDs(["x"]).isEmpty)
  }

  @Test("AT-SYNC-6: a warm start (snapshot + the rest) projects exactly what a cold fold does")
  func warmEqualsCold() throws {
    let maya = try Maya()
    // Re-fold Maya's state from its own canonical history: split the ops at a midpoint.
    var a = OpAuthor(maya.context())
    a.defineCategory(id: "zz_pets", name: "Pets", kind: .spending, bucket: .want, icon: "paw", active: true)
    a.defineCategory(id: "aa_gifts", name: "Gifts", kind: .spending, bucket: .want, icon: "gift", active: true)
    a.declareBank("enbd", active: true)
    a.declareBank("dib", active: true)
    let extra = try a.build().ops
    var cold = maya.state
    try Replay.foldOps(extra, seq: cold.cursors.hot + 1, writerID: Maya.writer, into: &cold)
    var b = OpAuthor(maya.context())
    b.defineCategory(id: "zz_pets", name: "Pets and vets", kind: .spending, bucket: .want, icon: "paw", active: true)
    let later = try b.build().ops
    try Replay.foldOps(later, seq: cold.cursors.hot + 1, writerID: Maya.writer, into: &cold)

    var warm = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: maya.state))).state
    try Replay.foldOps(extra, seq: warm.cursors.hot + 1, writerID: Maya.writer, into: &warm)
    let snap = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: warm))).state
    warm = snap
    try Replay.foldOps(later, seq: warm.cursors.hot + 1, writerID: Maya.writer, into: &warm)
    #expect(warm == cold)

    func dump(_ s: State) throws -> [String] {
      let db = try Projector.open(path: nil)
      try Projector.project(s, dictionary: Self.dictionary, projectedAtMs: 1, into: db)
      return try db.read { db in
        var out: [String] = []
        for t in ProjectionSchema.tables {
          for r in try Row.fetchAll(db, sql: "SELECT * FROM \(t) ORDER BY 1, 2") { out.append("\(t) \(r)") }
        }
        return out
      }
    }
    #expect(try dump(warm) == dump(cold))
    let cats = try LedgerReader(try { let d = try Projector.open(path: nil); try Projector.project(warm, dictionary: Self.dictionary, projectedAtMs: 1, into: d); return d }()).taxonomy()
    #expect(cats.ordered.suffix(2).map(\.id) == ["zz_pets", "aa_gifts"])
    #expect(Array(warm.banks.keys) == ["enbd", "dib"])
  }
}
