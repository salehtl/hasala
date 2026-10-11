// The Maya scenario (spec 04 §15.3; 03a §7.1 inputs), authored through
// `OpAuthor` as ordinary v4 ops, folded, and projected. Maya Rahman is the
// fictional persona of the Paper boards; every row is synthetic.
import CoreCategorize
import CoreDomain
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreTime
import CoreWire
import Foundation

/// A deterministic `RandomSource` (counter-mode SHA-256).
final class CountingRandom: RandomSource, @unchecked Sendable {
  private let lock = NSLock()
  private var n: UInt64 = 0
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    lock.lock()
    defer { lock.unlock() }
    var i = 0
    while i < buffer.count {
      n += 1
      var b = withUnsafeBytes(of: n.bigEndian) { Array($0) }
      b = Array(sha256(b))
      for x in b where i < buffer.count {
        buffer[i] = x
        i += 1
      }
    }
  }
}

struct Maya {
  static let writer = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let today = CivilDate(year: 2026, month: 10, day: 10)!
  static let october = CivilMonth(year: 2026, month: 10)!
  static let september = CivilMonth(year: 2026, month: 9)!
  static let november = CivilMonth(year: 2026, month: 11)!
  /// `2026-10-10T09:40:00Z` (13:40 in Dubai).
  static let nowMs: Int64 = 1_791_625_200_000

  var state = State()
  var seq: Int64 = 0
  var ownLast: Int64?
  let random = CountingRandom()
  var ids: [String: String] = [:]
  var ingest = 0

  init() throws {
    try build()
  }

  func context() -> AuthorContext {
    AuthorContext(writerID: Self.writer, nowMs: Self.nowMs - 86_400_000 * 40, ownLastMs: ownLast, maxAuthored: [:], random: random)
  }

  mutating func commit(_ f: (inout OpAuthor) throws -> Void) throws {
    var a = OpAuthor(context())
    try f(&a)
    let blob = try a.build()
    seq += 1
    try Replay.foldOps(blob.ops, seq: seq, writerID: Self.writer, into: &state)
    ownLast = blob.lastAuthoredMs
  }

  /// Local wall time "2026-10-03 12:00" at +04:00 → UTC instant text.
  static func posted(_ day: String, _ time: String = "12:00") -> String {
    let ms = try! parseInstantMs("\(day)T\(time):00Z") - LocalClock.offsetMs
    return Instant.iso(ms)!
  }

  /// Ingests a row as the mailbox lane would (uncategorized, in review), then,
  /// when `category` is given and `review` is false, sorts it as a person would.
  mutating func txn(
    _ key: String, _ merchant: String, _ amount: Int64, _ day: String, _ time: String = "12:00", category: String?, direction: String = "debit",
    review: Bool = false, last4: String = "4412", bank: String = "enbd"
  ) throws {
    ingest += 1
    let ingestID = String(repeating: "0", count: 60) + String(format: "%04x", ingest)
    var id = ""
    try commit { a in
      id = try a.newEntityID()
      let fields: [(String, JSONValue)] = [
        ("amount_minor", .string(String(amount))), ("currency", .string("AED")), ("direction", .string(direction)),
        ("posted_at", .string(Self.posted(day, time))), ("merchant_raw", .string(merchant)), ("last4", .string(last4)),
        ("tier", .string("template")), ("needs_review", .bool(true)), ("bank", .string(bank)), ("entry_method", .string("mailbox")),
      ]
      try a.ingest(payload: JSONObject(fields), ingestID: ingestID, entityID: id)
    }
    ids[key] = id
    if let category, !review {
      let v = state.txns[id]!.version
      try commit { a in a.categorize(txnID: id, parentVersion: v, category: category, needsReview: false, source: .user) }
    }
  }

  mutating func build() throws {
    try commit { a in
      a.setHomeCurrency("AED")
      try a.setBudgetTemplate(need: 50, want: 30, saving: 20)
      try a.setSenderTrust(typed: "alerts@emiratesnbd.com", trusted: true, currentTrusted: [])
      a.setIncomeSource(id: "salary-1", name: "Salary", category: "salary", amountMinor: 2_500_000, payday: 28)
    }
    let budgets: [(String, Int64)] = [
      ("rent", 750_000), ("utilities", 90_000), ("groceries", 220_000), ("transport", 90_000), ("healthcare", 30_000),
      ("insurance", 55_000), ("dining", 160_000), ("entertainment", 60_000), ("shopping", 160_000), ("travel", 250_000),
      ("subscriptions", 35_000), ("savings", 300_000), ("investments", 200_000),
    ]
    try commit { a in for (c, v) in budgets { a.setBudget(category: c, month: Self.september, amountMinor: v) } }

    // The trip and the emergency fund (03c §6, through 03a §9's defineProject / defineGoal).
    let project = "01JC0000000000000000000P01"
    let goal = "01JC0000000000000000000G01"
    try commit { a in
      try a.defineProject(
        id: project,
        OpAuthor.ProjectDraft(
          name: "Japan trip", startsOn: CivilDate(wire: "2026-12-14"), endsOn: CivilDate(wire: "2026-12-28"), budgetMinor: 1_200_000,
          icon: "plane"))
      try a.defineGoal(
        id: goal,
        OpAuthor.GoalDraft(
          name: "Emergency fund", targetMinor: 5_000_000, targetMonth: CivilMonth(year: 2027, month: 1),
          source: .category(id: "savings", since: CivilDate(wire: "2026-09-01")!), startingMinor: 3_250_000, icon: "jar"))
    }
    ids["project"] = project
    ids["goal"] = goal

    // September: salary, savings, the trip's spending (carved out), dining.
    try txn("salary-sep", "SALARY TRANSFER", 2_500_000, "2026-09-28", category: "salary", direction: "credit")
    try txn("savings-sep", "STANDING ORDER SAVINGS", 300_000, "2026-09-02", category: "savings")
    try txn("emirates", "EMIRATES AIRLINE", 412_000, "2026-09-12", category: "travel")
    try txn("jrpass", "JR PASS", 74_000, "2026-09-15", category: "transport")
    try txn("dining-sep", "ZUMA DIFC", 148_620, "2026-09-20", category: "dining")
    for k in ["emirates", "jrpass"] {
      let id = ids[k]!
      try commit { a in a.annotate(txnID: id, set: [("project_id", project)]) }
    }

    // October, counted (20 rows).
    try txn("rent", "AL HABTOOR PROPERTIES", 750_000, "2026-10-01", category: "rent")
    try txn("du", "DU TELECOM", 42_790, "2026-10-05", category: "utilities")
    try txn("spinneys", "SPINNEYS JUMEIRAH", 27_025, "2026-10-03", category: "groceries")
    try txn("waitrose", "WAITROSE DUBAI MALL", 20_000, "2026-10-05", category: "groceries")
    try txn("carrefour", "CARREFOUR MOE", 34_215, "2026-10-09", "19:12", category: "groceries")
    try txn("enoc", "ENOC 1043", 16_850, "2026-10-04", category: "transport")
    try txn("careem", "CAREEM HALA", 4_600, "2026-10-09", "23:40", category: "transport")
    try txn("aster", "ASTER PHARMACY", 8_600, "2026-10-02", category: "healthcare")
    try txn("talabat1", "TALABAT", 5_825, "2026-10-03", category: "dining")
    try txn("commongrounds", "COMMON GROUNDS", 8_100, "2026-10-06", category: "dining")
    try txn("zuma", "ZUMA DIFC", 41_200, "2026-10-07", category: "dining")
    try txn("starbucks", "STARBUCKS DIFC", 2_700, "2026-10-10", "09:05", category: "dining")
    try txn("talabat2", "TALABAT", 6_450, "2026-10-10", "13:20", category: "dining")
    try txn("vox", "VOX CINEMAS MOE", 9_500, "2026-10-08", category: "entertainment")
    try txn("ikea", "IKEA FESTIVAL CITY", 24_280, "2026-10-02", category: "shopping")
    try txn("noon", "NOON.COM", 18_900, "2026-10-07", category: "shopping")
    try txn("netflix", "NETFLIX.COM", 5_600, "2026-10-06", category: "subscriptions")
    try txn("spotify", "SPOTIFY", 2_199, "2026-10-08", category: "subscriptions")
    try txn("savings-oct", "STANDING ORDER SAVINGS", 300_000, "2026-10-02", category: "savings")
    try txn("sarwa", "SARWA", 200_000, "2026-10-02", category: "investments")

    // October, to review (6 rows): AED 827.28 of debits and one credit.
    try txn("lulu", "LULU HYPERMARKET", 21_430, "2026-10-09", category: nil, review: true)
    try txn("dubaitaxi", "DUBAI TAXI", 3_850, "2026-10-08", category: nil, review: true)
    try txn("apple", "APPLE.COM/BILL", 1_499, "2026-10-07", category: nil, review: true)
    try txn("steam", "STEAM PURCHASE", 5_949, "2026-10-06", category: nil, review: true)
    try txn("atm", "ADCB ATM", 50_000, "2026-10-05", category: nil, review: true)
    try txn("credit", "TRANSFER FROM 1234567890", 125_000, "2026-10-04", category: nil, direction: "credit", review: true)
  }

  /// 03b §3.12's October expectations for the bills categories (03a §7.1 table).
  static func bills() -> [BillExpectation] {
    func d(_ day: Int) -> CivilDate { CivilDate(year: 2026, month: 10, day: day)! }
    return [
      BillExpectation(billID: "rent", categoryID: "rent", payee: "Rent", expectedDay: d(1), amount: 750_000, isEstimate: false, status: .paid, paidDay: d(1)),
      BillExpectation(billID: "du", categoryID: "utilities", payee: "du", expectedDay: d(5), amount: 38_900, isEstimate: false, status: .paid, paidDay: d(5)),
      BillExpectation(billID: "dewa", categoryID: "utilities", payee: "DEWA", expectedDay: d(14), amount: 48_915, isEstimate: true, status: .upcoming),
      BillExpectation(billID: "axa", categoryID: "insurance", payee: "AXA", expectedDay: d(7), amount: 55_000, isEstimate: false, status: .late, usualDayOfMonth: 7),
      BillExpectation(billID: "netflix", categoryID: "subscriptions", payee: "Netflix", expectedDay: d(6), amount: 5_600, isEstimate: false, status: .paid, paidDay: d(6)),
      BillExpectation(billID: "spotify", categoryID: "subscriptions", payee: "Spotify", expectedDay: d(8), amount: 2_199, isEstimate: false, status: .paid, paidDay: d(8)),
    ]
  }
}
