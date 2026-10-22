import Foundation
import HasalaMocks
import HasalaModels
import Testing

@Suite("Maya backlog scenario")
struct MayaBacklogScenarioTests {
  struct Entry: Decodable {
    var m: String
    var p: String
  }

  struct DictionaryFile: Decodable {
    var entries: [Entry]
  }

  static func dictionary() throws -> [Entry] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("HasalaCore/Sources/HasalaCore/Resources/merchant-dictionary.json")
    return try JSONDecoder().decode(DictionaryFile.self, from: Data(contentsOf: url)).entries
  }

  static func canonical(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  @Test func noBacklogNameIsOnHasalasList() throws {
    let entries = try Self.dictionary()
    #expect(entries.count > 100)
    let raws = Set(MayaBacklog.txns.compactMap { $0.provenance?.rawMerchant })
    #expect(raws == Set(MayaBacklog.spellings.map(\.raw)))
    for raw in raws {
      let subject = Self.canonical(raw)
      let hits = entries.filter { e in
        switch e.m {
        case "exact": subject == e.p
        case "starts_with": subject.hasPrefix(e.p)
        case "contains": subject.contains(e.p)
        default: true
        }
      }
      #expect(hits.isEmpty, "\(raw) is on the dictionary: \(hits.map(\.p))")
    }
  }

  @Test func everyRowCarriesItsPrecomputedKeys() {
    let bySpelling = Dictionary(uniqueKeysWithValues: MayaBacklog.spellings.map { ($0.raw, $0) })
    for t in MayaBacklog.txns {
      let spelling = bySpelling[t.provenance?.rawMerchant ?? ""]
      #expect(spelling != nil)
      #expect(t.merchantKey == spelling?.merchantKey)
      #expect(t.merchantKey == Self.canonical(t.provenance?.rawMerchant ?? ""))
      #expect(t.merchantGroup == spelling?.group)
      #expect(t.id.hasPrefix("bl-"))
    }
    let tailscale = Set([MayaBacklog.tailscaleCom, MayaBacklog.tailscaleInc, MayaBacklog.tailscalePaypal].map(\.group))
    #expect(tailscale == ["n:tailscale"])
    #expect(MayaBacklog.alNoorTrading.group != MayaBacklog.alNoorPharmacy.group)
    #expect(MayaBacklog.nimbusCom.group == MayaBacklog.nimbusPaypal.group)
  }

  @Test func theScenarioAddsTheBacklogToMaya() {
    let s = Scenario.mayaBacklog.state
    let base = Scenario.maya.state
    #expect(Scenario.mayaBacklog.now == MayaLedger.now)
    #expect(Scenario.fromLaunchArguments(["-HasalaScenario", "mayaBacklog"]) == .mayaBacklog)
    #expect(s.txns.count == base.txns.count + MayaBacklog.txns.count)
    #expect(Set(base.txns.map(\.id)).isSubset(of: Set(s.txns.map(\.id))))
    #expect(s.billCandidates.contains { $0.id == MayaBacklog.candidate.id })
    #expect(s.rates.contains { $0.currency == "EUR" })
    let reachable = Set(s.txns.filter(\.reachable).map(\.id))
    let waiting = Set(s.txns.filter(\.inReview).map(\.id))
    #expect(waiting.subtracting(reachable) == ["bl-ts-unverified", "steam"])
    #expect(reachable.isSubset(of: waiting))
    #expect(base.txns.allSatisfy { $0.merchantGroup == nil && !$0.reachable })
  }

  static func waiting(_ id: TxnID, in s: LedgerState, _ change: (inout Txn) -> Void = { _ in }) -> Bool? {
    var s = s
    for i in s.txns.indices where s.txns[i].id == id {
      s.txns[i].needsReview = true
      s.txns[i].categorySource = s.txns[i].categorySource == .dictionary ? nil : s.txns[i].categorySource
      change(&s.txns[i])
    }
    return MockReach.refreshed(s).txn(id)?.reachable
  }

  @Test func aHeldCopyIsNeverWaiting() throws {
    let s = Scenario.mayaCopy.state
    #expect(try #require(s.txn("starbucks-copy")).isHeldCopy)
    #expect(MockReach.refreshed(s).txn("starbucks-copy")?.reachable == false)
    #expect(Self.waiting("starbucks-copy", in: s) == false)
    #expect(Self.waiting("starbucks-copy", in: s) { $0.heldCopy = nil } == true)
  }

  @Test func bothSidesOfASamePurchaseAreNeverWaiting() {
    let s = Scenario.mayaSamePurchase.state
    #expect(MockReach.refreshed(s).txn("amazon-aed")?.reachable == false)
    #expect(MockReach.refreshed(s).txn("amazon-usd")?.reachable == false)
    #expect(Self.waiting("amazon-aed", in: s) == false)
    #expect(Self.waiting("amazon-usd", in: s) == false)
    var unpaired = s
    for i in unpaired.txns.indices where unpaired.txns[i].id == "amazon-aed" { unpaired.txns[i].samePurchase = nil }
    #expect(Self.waiting("amazon-aed", in: unpaired) == true)
    #expect(Self.waiting("amazon-usd", in: unpaired) == true)
  }

  @Test func aPaymentThePersonFiledIsNeverWaiting() {
    let s = Scenario.mayaBacklog.state
    #expect(Self.waiting("bl-ts-01", in: s) == true)
    #expect(Self.waiting("bl-ts-01", in: s) { $0.categoryID = "subscriptions"; $0.categorySource = .user } == false)
    #expect(Self.waiting("bl-ts-01", in: s) { $0.categoryID = "subscriptions"; $0.categorySource = .manual } == false)
    #expect(Self.waiting("bl-ts-01", in: s) { $0.categoryID = "shopping"; $0.categorySource = .model(tag: "cf-clef/1") } == true)
    #expect(Self.waiting("bl-ts-01", in: s) { $0.needsReview = false; $0.categoryID = "subscriptions" } == false)
  }

  @Test func aPaymentWithAReviewReasonIsNeverWaiting() {
    let s = Scenario.mayaBacklog.state
    #expect(MockReach.refreshed(s).txn("bl-ts-unverified")?.reachable == false)
    for reason in [TxnReviewReason.senderUnverified, .probableCopy, .samePurchase] {
      #expect(Self.waiting("bl-ts-01", in: s) { $0.reviewReason = reason } == false)
    }
    #expect(Self.waiting("bl-ts-01", in: s) { $0.archived = true } == false)
  }

  @Test func foreignRowsCarryTheirHomeEstimate() {
    for t in MayaBacklog.txns where t.amount.currency != Money.home {
      #expect(t.homeSource == .rate)
      #expect(t.homeMinor != nil)
      #expect(t.isEstimate)
    }
    #expect(MayaBacklog.txns.first { $0.id == "bl-ts-01" }?.homeMinor == ExchangeRates.convert(6_00, 3_672_500))
  }
}
