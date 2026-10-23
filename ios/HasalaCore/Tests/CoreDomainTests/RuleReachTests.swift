import CoreCategorize
import CoreReplay
import CoreTestSupport
import Testing

@testable import CoreDomain

@Suite("RuleReach")
struct RuleReachTests {
  static let dictionary = try! MerchantDictionary.bundled().get()
  static let groups = MerchantGroup(dictionary: dictionary)

  static func row(
    _ id: String, _ raw: String, direction: String = "debit", category: String? = nil, source: SweepRow.SourceKind = .none,
    needsReview: Bool = true, lane: ReviewLane? = .needsReview, unverified: Bool = false, heldCopy: Bool = false,
    copyOf: String? = nil, duplicateOf: String? = nil, archived: Bool = false, transfer: Bool = false, split: Bool = false,
    amount: Int64 = 1_000, currency: String = "AED", home: Int64? = nil, postedMs: Int64 = 1_790_000_000_000, bank: String? = "dib",
    last4: String = "4412"
  ) -> RuleReach.Row {
    RuleReach.Row(
      id: id, version: 1, merchantRaw: raw, merchantGroup: groups.key(raw: raw).isEmpty ? nil : groups.key(raw: raw),
      direction: direction, category: category, sourceKind: source, sourceRef: nil, needsReview: needsReview, lane: lane,
      unverified: unverified, heldCopy: heldCopy, copyOf: copyOf, possibleDuplicateOf: duplicateOf, archived: archived,
      transfer: transfer, split: split, postedMs: postedMs,
      purchase: SamePurchase.Row(
        id: id, archived: archived, amountMinor: amount, currency: currency, amountHomeMinor: home ?? (currency == "AED" ? amount : nil),
        direction: direction, bank: bank, last4: last4, postedMs: postedMs, merchantKey: Canon.merchantKey(raw),
        possibleDuplicateOf: duplicateOf, heldCopy: heldCopy))
  }

  static func rule(_ patterns: [String], match: String = "exact", category: String = "subscriptions") -> RuleInput {
    RuleInput(id: "r1", patterns: patterns, match: match, category: category, priority: 100)
  }

  @Test("an Al Noor Trading rule leaves Al Noor Pharmacy waiting, even when its pattern reaches both")
  func alNoor() {
    let rows = [
      Self.row("t1", "AL NOOR TRADING LLC"), Self.row("t2", "AL NOOR TRADING"), Self.row("p1", "AL NOOR PHARMACY"),
      Self.row("p2", "AL NOOR PHARMACY"),
    ]
    let broad = Self.rule(["al noor"], match: "starts_with", category: "shopping")
    let group = Self.groups.key(raw: "AL NOOR TRADING LLC")
    #expect(group == "n:al noor trading")
    let targets = RuleReach.plan(rows: rows, rule: broad, group: group, direction: "debit", home: "AED")
    #expect(targets.map(\.txnID) == ["t1", "t2"])
    let exact = Self.rule(RuleReach.patterns(filed: "AL NOOR TRADING LLC", members: rows.filter { $0.merchantGroup == group }))
    #expect(exact.patterns == ["al noor trading llc", "al noor trading"])
    #expect(RuleReach.plan(rows: rows, rule: exact, group: group, direction: "debit", home: "AED").map(\.txnID) == ["t1", "t2"])
  }

  @Test("a dictionary-filed row in the group is left as it is")
  func dictionaryRow() {
    let rows = [
      Self.row("w", "TAILSCALE.COM"),
      Self.row("d", "TAILSCALE.COM", category: "shopping", source: .dictionary, needsReview: false, lane: nil),
      Self.row("m", "TAILSCALE INC", category: "shopping", source: .model, needsReview: false, lane: nil),
      Self.row("s", "TAILSCALE INC", category: "shopping", source: .model, needsReview: true, lane: .needsReview),
      Self.row("u", "TAILSCALE INC", category: "dining", source: .user, needsReview: false, lane: nil),
      Self.row("r", "TAILSCALE INC", category: "dining", source: .rule, needsReview: false, lane: nil),
      Self.row("h", "TAILSCALE INC", category: "dining", source: .held, needsReview: true, lane: .needsReview),
    ]
    let targets = RuleReach.plan(
      rows: rows, rule: Self.rule(["tailscale.com", "tailscale inc"]), group: "n:tailscale", direction: "debit", home: "AED")
    #expect(targets.map(\.txnID) == ["w", "s"])
  }

  @Test("unverified, copy, duplicate, same-purchase, archived, transfer and split rows are left in Review")
  func alertRows() {
    let base: Int64 = 1_790_000_000_000
    let rows = [
      Self.row("ok", "TAILSCALE.COM"),
      Self.row("unverified", "TAILSCALE.COM", unverified: true),
      Self.row("copy", "TAILSCALE.COM", lane: .copy, heldCopy: true, copyOf: "ok"),
      Self.row("kept", "TAILSCALE.COM", copyOf: "ok"),
      Self.row("dup", "TAILSCALE.COM", duplicateOf: "ok"),
      Self.row("archived", "TAILSCALE.COM", archived: true),
      Self.row("transfer", "TAILSCALE.COM", transfer: true),
      Self.row("split", "TAILSCALE.COM", split: true),
      Self.row("usd", "TAILSCALE.COM", amount: 1_000, currency: "USD", home: 3_673, postedMs: base),
      Self.row("aed", "TAILSCALE.COM", amount: 3_673, postedMs: base + 3_600_000),
      Self.row("credit", "TAILSCALE.COM", direction: "credit"),
    ]
    #expect(RuleReach.paired(rows, home: "AED") == ["usd", "aed"])
    let targets = RuleReach.plan(rows: rows, rule: Self.rule(["tailscale.com"]), group: "n:tailscale", direction: "debit", home: "AED")
    #expect(targets.map(\.txnID) == ["ok"])
    #expect(RuleReach.members(rows: rows, group: "n:tailscale", direction: "debit", home: "AED").map(\.id) == ["ok"])
  }

  @Test("1000 waiting rows are planned in one pass and authored in blobs of at most 500")
  func thousand() throws {
    let rows = (0..<1_000).map { Self.row("t\($0)", ["TAILSCALE.COM", "TAILSCALE INC", "PAYPAL *TAILSCALE"][$0 % 3]) }
    let patterns = RuleReach.patterns(filed: "TAILSCALE.COM", members: rows)
    #expect(patterns == ["tailscale.com", "tailscale inc", "paypal *tailscale"])
    let targets = RuleReach.plan(rows: rows, rule: Self.rule(patterns), group: "n:tailscale", direction: "debit", home: "AED")
    #expect(targets.count == 1_000)
    let items = RuleReach.items(targets, ruleID: "01JC0000000000000000000004", category: "subscriptions")
    #expect(items.allSatisfy { !$0.needsReview && $0.source.kind == .rule && $0.source.ruleID == "01JC0000000000000000000004" })
    let ctx = AuthorContext(writerID: "w", nowMs: 1_790_000_000_000, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "reach"))
    let blobs = try OpAuthor.categorizations(items, context: ctx)
    #expect(blobs.map(\.ops.count) == [500, 500])
  }

  @Test("a group's rule holds at most 8 exact patterns, most used first, the filed spelling always in")
  func nineSpellings() {
    var rows: [RuleReach.Row] = []
    for n in 1...9 {
      for k in 0..<(10 - n) { rows.append(Self.row("t\(n)-\(k)", "SOME SHOP*REF \(n)")) }
    }
    rows.append(Self.row("rare", "SOME SHOP*REF 99"))
    #expect(Set(rows.compactMap { $0.merchantGroup }) == ["n:some shop"])
    let patterns = RuleReach.patterns(filed: "SOME SHOP*REF 99", members: rows)
    #expect(patterns.count == RuleReach.maxPatterns)
    #expect(patterns.first == "some shop*ref 99")
    #expect(Array(patterns.dropFirst()) == (1...7).map { "some shop*ref \($0)" })
    #expect(OpAuthor.groupRule(patterns: patterns, category: "shopping", existing: []) != nil)
    #expect(OpAuthor.groupRule(patterns: patterns + ["x y"], category: "shopping", existing: []) == nil)
    #expect(OpAuthor.groupRule(patterns: [], category: "shopping", existing: []) == nil)
  }

  @Test("a group rule reuses the same exact rule, edits its category, or makes a learned one")
  func groupRule() {
    let draft = OpAuthor.RuleDraft(patterns: ["tailscale.com", "tailscale inc"], match: .exact, category: "shopping", priority: 100, origin: "learned")
    let existing = [OpAuthor.RuleSnapshot(id: "r9", version: 3, draft: draft)]
    let same = OpAuthor.groupRule(patterns: ["tailscale inc", "tailscale.com"], category: "shopping", existing: existing)
    #expect(same?.id == "r9" && same?.unchanged == true)
    let moved = OpAuthor.groupRule(patterns: ["tailscale inc", "tailscale.com"], category: "subscriptions", existing: existing)
    #expect(moved?.id == "r9" && moved?.parentVersion == 3 && moved?.draft.category == "subscriptions" && moved?.unchanged == false)
    let fresh = OpAuthor.groupRule(patterns: ["brightwell academy"], category: "education", existing: existing)
    #expect(fresh?.id == nil && fresh?.draft.origin == "learned" && fresh?.draft.priority == 100 && fresh?.draft.match == .exact)
    #expect(fresh?.trims.isEmpty == true)
  }

  @Test("re-filing one spelling of a ruled group edits that rule in place, so no second rule disagrees with it")
  func groupRuleOverlap() {
    let draft = OpAuthor.RuleDraft(patterns: ["tailscale.com", "tailscale inc"], match: .exact, category: "shopping", priority: 100, origin: "learned")
    let existing = [OpAuthor.RuleSnapshot(id: "r9", version: 3, draft: draft)]
    let refiled = OpAuthor.groupRule(patterns: ["tailscale.com"], category: "subscriptions", existing: existing)
    #expect(refiled?.id == "r9" && refiled?.parentVersion == 3 && refiled?.unchanged == false)
    #expect(refiled?.draft.category == "subscriptions" && refiled?.draft.enabled == true)
    #expect(refiled?.draft.patterns == ["tailscale.com", "tailscale inc"] && refiled?.trims.isEmpty == true)
    let again = OpAuthor.groupRule(patterns: ["tailscale inc"], category: "shopping", existing: existing)
    #expect(again?.id == "r9" && again?.unchanged == true)
    let wider = OpAuthor.groupRule(patterns: ["paypal *tailscale", "tailscale.com"], category: "shopping", existing: existing)
    #expect(wider?.id == "r9" && wider?.unchanged == false)
    #expect(wider?.draft.patterns == ["paypal *tailscale", "tailscale.com", "tailscale inc"])
    var paused = draft
    paused.enabled = false
    let resumed = OpAuthor.groupRule(patterns: ["tailscale inc"], category: "shopping", existing: [OpAuthor.RuleSnapshot(id: "r9", version: 4, draft: paused)])
    #expect(resumed?.id == "r9" && resumed?.unchanged == false && resumed?.draft.enabled == true)
  }

  @Test("other rules that file a shared spelling elsewhere lose that spelling, or are removed when it was their only one")
  func groupRuleTrims() {
    let a = OpAuthor.RuleSnapshot(
      id: "ra", version: 2,
      draft: OpAuthor.RuleDraft(patterns: ["tailscale.com", "tailscale inc"], match: .exact, category: "shopping", priority: 100, origin: "learned"))
    let b = OpAuthor.RuleSnapshot(
      id: "rb", version: 5, draft: OpAuthor.RuleDraft(patterns: ["tailscale.com"], match: .exact, category: "software", priority: 100, origin: "learned"))
    let c = OpAuthor.RuleSnapshot(
      id: "rc", version: 1, draft: OpAuthor.RuleDraft(patterns: ["tailscale.com"], match: .contains, category: "travel", priority: 100, origin: "learned"))
    let plan = OpAuthor.groupRule(patterns: ["tailscale.com"], category: "subscriptions", existing: [b, a, c])
    #expect(plan?.id == "ra" && plan?.draft.category == "subscriptions")
    #expect(plan?.trims.map(\.id) == ["rb"] && plan?.trims.first?.draft.removed == true && plan?.trims.first?.version == 5)
    let d = OpAuthor.RuleSnapshot(
      id: "rd", version: 7,
      draft: OpAuthor.RuleDraft(patterns: ["tailscale.com", "kite studio"], match: .exact, category: "dining", priority: 100, origin: "learned"))
    let trimmed = OpAuthor.groupRule(patterns: ["tailscale.com"], category: "subscriptions", existing: [a, d])
    #expect(trimmed?.trims.first?.id == "rd" && trimmed?.trims.first?.draft.patterns == ["kite studio"])
    #expect(trimmed?.trims.first?.draft.removed == false)
    let rules = ([trimmed!.draft] + trimmed!.trims.map(\.draft)).enumerated().map { i, d in
      RuleInput(id: "x\(i)", patterns: d.patterns, match: d.match.rawValue, category: d.category, priority: d.priority, enabled: d.enabled, removed: d.removed)
    }
    let prepared = Matcher.prepare(rules: rules, entries: []).rules
    #expect(prepared.filter { Matcher.hits($0, merchantRaw: "TAILSCALE.COM") }.map(\.category) == ["subscriptions"])
  }

  @Test("a full rule that shares one spelling with the group keeps its other eight and the group gets its own rule")
  func groupRuleFullPrimary() {
    let own = (1...8).map { "some shop*ref \($0)" }
    let wanted = ["some shop*ref 1", "some shop*ref 9", "some shop*ref 10"]
    let full = OpAuthor.RuleSnapshot(
      id: "rf", version: 4, draft: OpAuthor.RuleDraft(patterns: own, match: .exact, category: "shopping", priority: 100, origin: "learned"))
    for category in ["subscriptions", "shopping"] {
      let plan = OpAuthor.groupRule(patterns: wanted, category: category, existing: [full])
      #expect(plan?.id == nil && plan?.parentVersion == nil && plan?.unchanged == false)
      #expect(plan?.draft.patterns == wanted && plan?.draft.category == category && plan?.draft.origin == "learned")
      #expect(plan?.trims.count == 1)
      let trim = plan?.trims.first
      #expect(trim?.id == "rf" && trim?.version == 4 && trim?.draft.removed == false)
      #expect(trim?.draft.patterns == Array(own.dropFirst()) && trim?.draft.category == "shopping")
      let kept = Set((plan?.draft.patterns ?? []) + (trim?.draft.patterns ?? []))
      #expect(Set(own).isSubset(of: kept))
    }
  }

  @Test("a rule's spelling outside the group stays in it, and another rule that shares that spelling is not trimmed")
  func groupRuleOutsideSpelling() {
    let primary = OpAuthor.RuleSnapshot(
      id: "rp", version: 2,
      draft: OpAuthor.RuleDraft(patterns: ["tailscale.com", "kite studio"], match: .exact, category: "shopping", priority: 100, origin: "learned"))
    let other = OpAuthor.RuleSnapshot(
      id: "ro", version: 3,
      draft: OpAuthor.RuleDraft(patterns: ["kite studio", "lantern film club"], match: .exact, category: "dining", priority: 100, origin: "learned"))
    let plan = OpAuthor.groupRule(patterns: ["tailscale.com", "tailscale inc"], category: "subscriptions", existing: [primary, other])
    #expect(plan?.id == "rp" && plan?.parentVersion == 2)
    #expect(plan?.draft.patterns == ["tailscale.com", "tailscale inc", "kite studio"])
    #expect(plan?.trims.isEmpty == true)
  }

  @Test("a learned pattern never starts with a payment facilitator")
  func facilitator() {
    #expect(LearnedPattern.propose(merchantRaw: "PAYPAL *TAILSCALE", category: "subscriptions")! == (.exact, "paypal *tailscale"))
    #expect(LearnedPattern.propose(merchantRaw: "SQ *KITE STUDIO", category: "dining")! == (.exact, "sq *kite studio"))
    #expect(LearnedPattern.propose(merchantRaw: "TAILSCALE.COM", category: "subscriptions")! == (.contains, "tailscale.com"))
    #expect(MerchantGroup.isFacilitatorToken("paypal") && !MerchantGroup.isFacilitatorToken("tailscale"))
  }
}
