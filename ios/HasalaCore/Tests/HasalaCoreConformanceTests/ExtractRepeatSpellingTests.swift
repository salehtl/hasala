import CoreCategorize
import CoreDomain
import CoreExtract
import CoreReplay
import Foundation
import Testing

@Suite struct ExtractRepeatSpellingTests {
  static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
  static let arMonths = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو"]

  static func mail(_ i: Int) -> ExtractInput {
    ExtractInput(
      sender: "bank-d.example", subject: "Card alert",
      text: "Dear Customer,\nYour card ending 4821 was used for AED \(10 + i).00 at TALABAT on \(months[i % 6]) \(1 + i), 2030.\nThank you.",
      receivedAtMs: 1_900_000_000_000 + Int64(i) * 86_400_000, listUnsubscribe: false)
  }

  static func mailAR(_ i: Int) -> ExtractInput {
    ExtractInput(
      sender: "bank-e.example", subject: "إشعار",
      text: "عزيزي المتعامل،\nتم خصم مبلغ \(10 + i).00 درهم من بطاقتك المنتهية ب 4821 لدى TALABAT يوم \(1 + i) \(arMonths[i % 6]) 2030.\nشكرا لكم",
      receivedAtMs: 1_900_000_000_000 + Int64(i) * 86_400_000, listUnsubscribe: false)
  }

  static func check(_ make: (Int) -> ExtractInput) throws {
    let groups = MerchantGroup(dictionary: try MerchantDictionary.bundled().get())
    var mem = LearnedLayouts()
    var rows: [RuleReach.Row] = []
    for i in 0..<12 {
      let (r, next) = CombinedReader.read(make(i), mem)
      mem = next
      let raw = try #require(r.merchant)
      let g = groups.key(raw: raw)
      rows.append(
        RuleReach.Row(
          id: "t\(i)", version: 1, merchantRaw: raw, merchantGroup: g.isEmpty ? nil : g, direction: "debit", category: nil,
          sourceKind: .none, sourceRef: nil, needsReview: true, lane: .needsReview, postedMs: Int64(i),
          purchase: SamePurchase.Row(
            id: "t\(i)", amountMinor: Int64(1000 + i * 100), currency: "AED", amountHomeMinor: Int64(1000 + i * 100),
            direction: "debit", bank: "bank-d", last4: "4821", postedMs: Int64(i), merchantKey: Canon.merchantKey(raw))))
    }
    #expect(Set(rows.map(\.merchantRaw)) == ["TALABAT"])
    #expect(Set(rows.compactMap(\.merchantGroup)) == ["d:talabat"])
    let filed = rows[0]
    let pool = RuleReach.eligible(rows: rows, group: "d:talabat", direction: "debit", home: "AED").filter { $0.id != filed.id }
    let patterns = RuleReach.patterns(filed: filed.merchantRaw, members: pool, filing: "dining")
    let rule = RuleInput(id: "r1", patterns: patterns, match: "exact", category: "dining", priority: 100)
    let targets = RuleReach.plan(rows: rows, rule: rule, group: "d:talabat", direction: "debit", home: "AED", except: [filed.id])
    let left = rows.filter { r in r.id != filed.id && !targets.contains { $0.txnID == r.id } }
    #expect(patterns.count == 1)
    #expect(targets.count == 11)
    #expect(left.isEmpty)
    let (later, _) = CombinedReader.read(make(20), mem)
    let raw = try #require(later.merchant)
    #expect(RuleReach.hits(rule, raw), "\(raw)")
  }

  @Test func twelveDatedAlertsGiveOneSpellingAndAlwaysUseReachesAll() throws {
    try Self.check(Self.mail)
  }

  @Test func twelveDatedArabicAlertsGiveOneSpellingAndAlwaysUseReachesAll() throws {
    try Self.check(Self.mailAR)
  }
}
