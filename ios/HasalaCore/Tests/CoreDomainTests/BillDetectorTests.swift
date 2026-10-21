import CoreTime
import Testing

@testable import CoreDomain

@Suite("BillDetector")
struct BillDetectorTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  static func row(
    _ day: String, _ amount: Int64, key: String = "netflix", name: String = "Netflix", currency: String = "AED",
    category: String? = "subscriptions", direction: String = "debit", eligible: Bool = true, id: String? = nil
  ) -> DetectRow {
    DetectRow(
      txnID: id ?? "t_\(key)_\(currency)_\(day)_\(amount)", merchantKey: key, merchantName: name, direction: direction,
      amountMinor: amount, currency: currency, day: d(day), category: category, eligible: eligible)
  }

  static func run(_ rows: [DetectRow], covered: Set<String> = [], today: String) -> [BillCandidateCore] {
    BillDetector.run(rows: rows, coveredKeys: covered, today: d(today))
  }

  @Test("a monthly series with a small price change is one fixed candidate at the median")
  func monthlyPriceChange() throws {
    let rows = [
      Self.row("2026-01-15", 5_600), Self.row("2026-02-15", 5_600), Self.row("2026-03-16", 5_600),
      Self.row("2026-04-15", 6_300), Self.row("2026-05-14", 6_300), Self.row("2026-06-15", 6_300),
    ]
    let out = Self.run(rows, today: "2026-07-01")
    #expect(out.count == 1)
    let c = try #require(out.first)
    #expect(c.id == OpAuthor.detectedBillID(key: "netflix", direction: "debit", currency: "AED"))
    #expect(c.key == "netflix")
    #expect(c.name == "Netflix")
    #expect(c.unit == "month")
    #expect(c.every == 1)
    #expect(c.variable == false)
    #expect(c.amountMinor == 5_950)
    #expect(c.seen == 6)
    #expect(c.anchor == Self.d("2026-06-15"))
    #expect(c.last == Self.d("2026-06-15"))
    #expect(c.start == Self.d("2026-01-15"))
    #expect(c.category == "subscriptions")
  }

  @Test("a price change beyond 20% of the median keeps one candidate, marked variable")
  func monthlyLargePriceChange() throws {
    let rows = [
      Self.row("2026-01-15", 5_600), Self.row("2026-02-15", 5_600), Self.row("2026-03-15", 5_600),
      Self.row("2026-04-15", 9_000), Self.row("2026-05-15", 9_000), Self.row("2026-06-15", 9_000),
    ]
    let out = Self.run(rows, today: "2026-07-01")
    #expect(out.count == 1)
    let c = try #require(out.first)
    #expect(c.variable)
    #expect(c.amountMinor == 7_300)
    #expect(c.seen == 6)
  }

  @Test("a utility with varying amounts is variable")
  func dewaVariable() throws {
    let rows = [
      Self.row("2026-03-04", 42_000, key: "dewa", name: "DEWA", category: "utilities"),
      Self.row("2026-04-08", 61_000, key: "dewa", name: "DEWA", category: "utilities"),
      Self.row("2026-05-05", 38_000, key: "dewa", name: "DEWA", category: "utilities"),
      Self.row("2026-06-03", 75_000, key: "dewa", name: "DEWA", category: "utilities"),
    ]
    let c = try #require(Self.run(rows, today: "2026-06-20").first)
    #expect(c.variable)
    #expect(c.amountMinor == 51_500)
    #expect(c.seen == 4)
    #expect(c.unit == "month")
    #expect(c.anchor == Self.d("2026-06-03"))
    #expect(c.start == Self.d("2026-03-03"))
    #expect(c.category == "utilities")
  }

  @Test("a weekly series is weekly")
  func weekly() throws {
    let rows = [
      Self.row("2026-05-01", 3_000, key: "gym"), Self.row("2026-05-08", 3_000, key: "gym"),
      Self.row("2026-05-16", 3_000, key: "gym"), Self.row("2026-05-22", 3_000, key: "gym"),
      Self.row("2026-05-29", 3_000, key: "gym"), Self.row("2026-06-05", 3_000, key: "gym"),
    ]
    let c = try #require(Self.run(rows, today: "2026-06-10").first)
    #expect(c.unit == "week")
    #expect(c.seen == 6)
    #expect(c.anchor == Self.d("2026-06-05"))
    #expect(c.start == Self.d("2026-05-01"))
    #expect(c.variable == false)
    #expect(Self.run(rows, today: "2026-06-20").isEmpty)
  }

  @Test("a yearly series of three fires")
  func yearly() throws {
    let rows = [
      Self.row("2024-03-01", 35_000, key: "domain"), Self.row("2025-03-02", 35_000, key: "domain"),
      Self.row("2026-03-01", 35_000, key: "domain"),
    ]
    let c = try #require(Self.run(rows, today: "2026-07-01").first)
    #expect(c.unit == "year")
    #expect(c.seen == 3)
    #expect(c.start == Self.d("2024-03-01"))
    #expect(Self.run(Array(rows.suffix(2)), today: "2026-07-01").isEmpty)
  }

  @Test("irregular gaps give no candidate")
  func irregular() {
    let rows = [
      Self.row("2026-01-02", 4_000, key: "noon"), Self.row("2026-01-12", 4_000, key: "noon"),
      Self.row("2026-03-03", 4_000, key: "noon"), Self.row("2026-03-06", 4_000, key: "noon"),
      Self.row("2026-06-04", 4_000, key: "noon"),
    ]
    #expect(Self.run(rows, today: "2026-06-10").isEmpty)
  }

  @Test("two rows are not a series")
  func onlyTwo() {
    let rows = [Self.row("2026-05-15", 5_600), Self.row("2026-06-15", 5_600)]
    #expect(Self.run(rows, today: "2026-06-20").isEmpty)
  }

  @Test("a series that stopped long ago is not proposed")
  func stopped() {
    let rows = [
      Self.row("2025-11-15", 5_600), Self.row("2025-12-15", 5_600), Self.row("2026-01-15", 5_600),
      Self.row("2026-02-15", 5_600), Self.row("2026-03-15", 5_600),
    ]
    #expect(Self.run(rows, today: "2026-07-01").isEmpty)
    #expect(Self.run(rows, today: "2026-04-29").count == 1)
    #expect(Self.run(rows, today: "2026-04-30").isEmpty)
  }

  @Test("a covered key is never a candidate")
  func covered() {
    let rows = [Self.row("2026-04-15", 5_600), Self.row("2026-05-15", 5_600), Self.row("2026-06-15", 5_600)]
    #expect(Self.run(rows, today: "2026-06-20").count == 1)
    #expect(Self.run(rows, covered: ["netflix"], today: "2026-06-20").isEmpty)
  }

  @Test("credits and ineligible rows are ignored")
  func ineligible() {
    let rows = [
      Self.row("2026-04-15", 5_600), Self.row("2026-05-15", 5_600, eligible: false),
      Self.row("2026-06-15", 5_600, direction: "credit"),
    ]
    #expect(Self.run(rows, today: "2026-06-20").isEmpty)
  }

  @Test("two charges in one month keep the one closest to the median")
  func twoInOneMonth() throws {
    let rows = [
      Self.row("2026-01-15", 5_600), Self.row("2026-02-15", 5_600), Self.row("2026-03-15", 5_600),
      Self.row("2026-03-20", 1_500), Self.row("2026-04-15", 5_600), Self.row("2026-05-15", 5_600),
      Self.row("2026-05-17", 2_000),
    ]
    let c = try #require(Self.run(rows, today: "2026-05-30").first)
    #expect(c.seen == 5)
    #expect(c.amountMinor == 5_600)
    #expect(c.variable == false)
    #expect(c.last == Self.d("2026-05-15"))
    #expect(c.start == Self.d("2026-01-15"))
  }

  @Test("a month-end anchor on the 31st survives February")
  func monthEnd() throws {
    let rows = [
      Self.row("2025-10-31", 9_900, key: "rent"), Self.row("2025-11-30", 9_900, key: "rent"),
      Self.row("2025-12-31", 9_900, key: "rent"), Self.row("2026-01-31", 9_900, key: "rent"),
      Self.row("2026-02-28", 9_900, key: "rent"), Self.row("2026-03-31", 9_900, key: "rent"),
    ]
    let c = try #require(Self.run(rows, today: "2026-04-10").first)
    #expect(c.unit == "month")
    #expect(c.seen == 6)
    #expect(c.anchor == Self.d("2026-03-31"))
    #expect(c.start == Self.d("2025-10-31"))
  }

  @Test("the name is the most frequent one, the latest on a tie")
  func names() throws {
    let rows = [
      Self.row("2026-03-15", 5_600, name: "NETFLIX.COM", category: nil),
      Self.row("2026-04-15", 5_600, name: "Netflix", category: "fun"),
      Self.row("2026-05-15", 5_600, name: "NETFLIX.COM", category: "subscriptions"),
      Self.row("2026-06-15", 5_600, name: "Netflix", category: nil),
    ]
    let c = try #require(Self.run(rows, today: "2026-06-20").first)
    #expect(c.name == "Netflix")
    #expect(c.category == "subscriptions")
  }

  @Test("each currency is its own group")
  func multiCurrency() throws {
    let rows = [
      Self.row("2026-03-10", 1_000, currency: "USD"), Self.row("2026-04-10", 1_000, currency: "USD"),
      Self.row("2026-05-10", 1_000, currency: "USD"), Self.row("2026-04-15", 5_600), Self.row("2026-05-15", 5_600),
    ]
    #expect(Self.run(rows, today: "2026-05-20").map(\.currency) == ["USD"])
    let more = rows + [Self.row("2026-03-15", 5_600)]
    let out = Self.run(more, today: "2026-05-20")
    #expect(out.map(\.currency) == ["AED", "USD"])
    #expect(out[0].id == OpAuthor.detectedBillID(key: "netflix", direction: "debit", currency: "AED"))
    #expect(out[1].id == OpAuthor.detectedBillID(key: "netflix", direction: "debit", currency: "USD"))
    #expect(out[0].id != out[1].id)
  }

  @Test("the result does not depend on input order")
  func orderIndependent() {
    let rows = [
      Self.row("2026-01-15", 5_600), Self.row("2026-02-15", 5_600), Self.row("2026-03-15", 5_600),
      Self.row("2026-03-20", 5_600), Self.row("2026-04-15", 6_300), Self.row("2026-05-15", 6_300),
      Self.row("2026-03-04", 42_000, key: "dewa", name: "DEWA"), Self.row("2026-04-08", 61_000, key: "dewa", name: "DEWA"),
      Self.row("2026-05-05", 38_000, key: "dewa", name: "DEWA"),
      Self.row("2026-04-25", 3_000, key: "gym", name: "Gym"), Self.row("2026-05-02", 3_000, key: "gym", name: "Gym"),
      Self.row("2026-05-09", 3_000, key: "gym", name: "Gym"), Self.row("2026-05-16", 3_000, key: "gym", name: "Gym"),
    ]
    let base = Self.run(rows, today: "2026-05-20")
    #expect(base.count == 3)
    #expect(base.map(\.key) == ["gym", "netflix", "dewa"])
    #expect(Self.run(rows.reversed(), today: "2026-05-20") == base)
    let permuted = rows.enumerated().sorted { ($0.offset * 7) % 13 < ($1.offset * 7) % 13 }.map(\.element)
    #expect(Self.run(permuted, today: "2026-05-20") == base)
  }
}
