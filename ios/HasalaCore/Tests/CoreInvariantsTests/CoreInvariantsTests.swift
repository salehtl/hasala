// Unit tests for CoreInvariants: a clean fold passes, each broken shape is
// caught, and the audit compares witnesses.
import CoreReplay
import Testing

@testable import CoreInvariants

@Suite("CoreInvariants")
struct CoreInvariantsTests {
  @Test("the fold canary passes every hard stop")
  func canaryClean() {
    let v = Invariants.check(FoldCanary.state())
    #expect(!Invariants.halts(v), "\(v.filter { $0.severity == .hardStop })")
    #expect(v.contains { $0.id == "I14_forks_surfaced" && $0.severity == .notice })
  }

  @Test("broken shapes are hard stops")
  func broken() throws {
    var s = FoldCanary.state()
    let id = try #require(s.txns.first { $0.value.isLive && !$0.value.splits.isEmpty }?.key)
    s.txns[id]!.splits[0].amountMinor += 1
    #expect(Invariants.check(s).contains { $0.id == "I8_split_sum" })

    var u = FoldCanary.state()
    let unparsed = try #require(u.txns.first { $0.value.unparsed }?.key)
    u.txns[unparsed]!.annotations["project_id"] = Keyed("01JC0000000000000000000005", opID: "x")
    u.txns[unparsed]!.needsReview = false
    let v = Invariants.check(u)
    #expect(v.contains { $0.id == "I19_unparsed_links_empty" } && v.contains { $0.id == "I12_money_shape" })

    var c = FoldCanary.state()
    let live = try #require(c.txns.first { $0.value.isLive && !$0.value.unparsed }?.key)
    c.txns[live]!.categorySource = CategorySource(kind: .rule, ruleID: "r")
    c.txns[live]!.category = nil
    #expect(Invariants.check(c).contains { $0.id == "I18_category_source_shape" })

    var p = FoldCanary.state()
    p.pendingByCurrency["AED", default: []].append(live)
    #expect(Invariants.check(p).contains { $0.id == "I10_fx_pending_index" })

    var k = FoldCanary.state()
    k.anomalies.append(Anomaly(kind: "made_up", detail: "", atSeq: 1))
    #expect(Invariants.halts(Invariants.check(k)))
  }

  @Test("the audit compares witnesses, not bookkeeping")
  func audit() {
    let a = FoldCanary.state()
    var b = a
    b.appliedAtCursor.removeAll()
    #expect(Invariants.audit(kept: a, refolded: b) == nil)
    b.homeCurrency = "USD"
    #expect(Invariants.audit(kept: a, refolded: b)?.id == "I22_audit_refold")
  }
}
