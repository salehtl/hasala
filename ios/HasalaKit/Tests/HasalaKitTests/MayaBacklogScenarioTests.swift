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

  @Test func foreignRowsCarryTheirHomeEstimate() {
    for t in MayaBacklog.txns where t.amount.currency != Money.home {
      #expect(t.homeSource == .rate)
      #expect(t.homeMinor != nil)
      #expect(t.isEstimate)
    }
    #expect(MayaBacklog.txns.first { $0.id == "bl-ts-01" }?.homeMinor == ExchangeRates.convert(6_00, 3_672_500))
  }
}
