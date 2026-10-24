import CoreCategorize
import CoreReplay
import HasalaText

public enum RuleReach {
  public static let maxPatterns = 8

  public enum Scope: Sendable, Equatable {
    case waiting
    case ruled
  }

  public struct Row: Sendable, Equatable {
    public var id: String
    public var version: Int64
    public var merchantRaw: String
    public var merchantGroup: String?
    public var direction: String
    public var category: String?
    public var sourceKind: SweepRow.SourceKind
    public var sourceRef: String?
    public var needsReview: Bool
    public var lane: ReviewLane?
    public var unverified: Bool
    public var heldCopy: Bool
    public var copyOf: String?
    public var possibleDuplicateOf: String?
    public var archived: Bool
    public var transfer: Bool
    public var split: Bool
    public var unparsed: Bool
    public var postedMs: Int64
    public var categorizedMs: Int64?
    public var purchase: SamePurchase.Row

    public init(
      id: String, version: Int64, merchantRaw: String, merchantGroup: String?, direction: String, category: String?,
      sourceKind: SweepRow.SourceKind, sourceRef: String?, needsReview: Bool, lane: ReviewLane?, unverified: Bool = false,
      heldCopy: Bool = false, copyOf: String? = nil, possibleDuplicateOf: String? = nil, archived: Bool = false,
      transfer: Bool = false, split: Bool = false, unparsed: Bool = false, postedMs: Int64 = 0, categorizedMs: Int64? = nil,
      purchase: SamePurchase.Row
    ) {
      self.id = id
      self.version = version
      self.merchantRaw = merchantRaw
      self.merchantGroup = merchantGroup
      self.direction = direction
      self.category = category
      self.sourceKind = sourceKind
      self.sourceRef = sourceRef
      self.needsReview = needsReview
      self.lane = lane
      self.unverified = unverified
      self.heldCopy = heldCopy
      self.copyOf = copyOf
      self.possibleDuplicateOf = possibleDuplicateOf
      self.archived = archived
      self.transfer = transfer
      self.split = split
      self.unparsed = unparsed
      self.postedMs = postedMs
      self.categorizedMs = categorizedMs
      self.purchase = purchase
    }
  }

  public struct Target: Sendable, Equatable {
    public var txnID: String
    public var version: Int64
    public var category: String?
    public var sourceKind: SweepRow.SourceKind
    public var sourceRef: String?
    public var needsReview: Bool

    public init(
      txnID: String, version: Int64, category: String?, sourceKind: SweepRow.SourceKind, sourceRef: String?, needsReview: Bool
    ) {
      self.txnID = txnID
      self.version = version
      self.category = category
      self.sourceKind = sourceKind
      self.sourceRef = sourceRef
      self.needsReview = needsReview
    }

    public init(_ r: Row) {
      self.init(
        txnID: r.id, version: r.version, category: r.category, sourceKind: r.sourceKind, sourceRef: r.sourceRef,
        needsReview: r.needsReview)
    }
  }

  public static func paired(_ rows: [Row], home: String) -> Set<String> {
    var out: Set<String> = []
    for p in SamePurchase.pairs(rows.map(\.purchase), home: home) {
      out.insert(p.foreign)
      out.insert(p.home)
    }
    return out
  }

  public static func waiting(_ r: Row, samePurchase: Set<String>) -> Bool {
    guard r.lane == .needsReview || r.lane == .uncategorized else { return false }
    guard !r.unverified, !r.heldCopy, r.copyOf == nil, r.possibleDuplicateOf == nil else { return false }
    guard !r.archived, !r.transfer, !r.split, !samePurchase.contains(r.id) else { return false }
    switch r.sourceKind {
    case .user, .held: return false
    case .dictionary, .rule: return r.category == nil
    case .none, .model: return true
    }
  }

  public static func waiting(_ rows: [Row], home: String) -> [Row] {
    let pairs = paired(rows, home: home)
    return rows.filter { waiting($0, samePurchase: pairs) }
  }

  public static func ruled(_ r: Row, samePurchase: Set<String>) -> Bool {
    guard !r.unparsed, !r.unverified, !r.heldCopy, r.copyOf == nil, r.possibleDuplicateOf == nil else { return false }
    guard !r.archived, !r.transfer, !r.split, !samePurchase.contains(r.id) else { return false }
    switch r.sourceKind {
    case .user, .held: return false
    case .dictionary, .rule, .model, .none: return true
    }
  }

  public static func ruled(_ r: Row, category: String, samePurchase: Set<String>) -> Bool {
    ruled(r, samePurchase: samePurchase) && !settled(r, in: category)
  }

  public static func settled(_ r: Row, in category: String) -> Bool {
    !r.needsReview && r.category.map { utf8Equal($0, category) } == true
  }

  public static func eligible(rows: [Row], group: String, direction: String, home: String) -> [Row] {
    inGroup(rows, group: group, direction: direction, home: home, where: ruled(_:samePurchase:))
  }

  static func inGroup(
    _ rows: [Row], group: String, direction: String, home: String, where keep: (Row, Set<String>) -> Bool
  ) -> [Row] {
    guard !group.isEmpty else { return [] }
    let pairs = paired(rows, home: home)
    return rows.filter { r in r.merchantGroup == group && utf8Equal(r.direction, direction) && keep(r, pairs) }
  }

  public static func hits(_ rule: RuleInput, _ merchantRaw: String) -> Bool {
    let prepared = Matcher.prepare(rules: [rule], entries: []).rules
    return prepared.contains { Matcher.hits($0, merchantRaw: merchantRaw) }
  }

  public static func plan(
    rows: [Row], rule: RuleInput, group: String, direction: String, home: String, except: Set<String> = [],
    scope: Scope = .ruled
  ) -> [Target] {
    guard rule.enabled, !rule.removed, !group.isEmpty else { return [] }
    let prepared = Matcher.prepare(rules: [rule], entries: []).rules
    guard !prepared.isEmpty else { return [] }
    let pairs = paired(rows, home: home)
    return rows.filter { r in
      guard r.merchantGroup == group, utf8Equal(r.direction, direction), !except.contains(r.id) else { return false }
      let open =
        switch scope {
        case .waiting: waiting(r, samePurchase: pairs)
        case .ruled: ruled(r, category: rule.category, samePurchase: pairs)
        }
      return open && prepared.contains { Matcher.hits($0, merchantRaw: r.merchantRaw) }
    }.map(Target.init)
  }

  public static func members(rows: [Row], group: String, direction: String, home: String) -> [Row] {
    inGroup(rows, group: group, direction: direction, home: home, where: waiting(_:samePurchase:))
  }

  public static func pattern(_ merchantRaw: String) -> String? {
    let s = Canon.subject(merchantRaw)
    return Grammar.isRulePattern(s) && s.unicodeScalars.count >= MatchKind.exact.minRunes ? s : nil
  }

  static func ranked(_ rows: [Row]) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for r in rows {
      guard let s = pattern(r.merchantRaw) else { continue }
      if counts[s] == nil { order.append(s) }
      counts[s, default: 0] += 1
    }
    return order.enumerated().sorted { a, b in
      let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
      return ca == cb ? a.offset < b.offset : ca > cb
    }.map(\.element)
  }

  public static func patterns(filed: String?, members: [Row], then rest: [Row] = []) -> [String] {
    var out: [String] = []
    if let filed, let s = pattern(filed) { out.append(s) }
    for s in ranked(members) + ranked(rest) where out.count < maxPatterns && !out.contains(where: { utf8Equal($0, s) }) {
      out.append(s)
    }
    return out
  }

  public static func patterns(filed: String?, members: [Row], filing category: String) -> [String] {
    patterns(
      filed: filed, members: members.filter { !settled($0, in: category) }, then: members.filter { settled($0, in: category) })
  }

  public static func items(_ targets: [Target], ruleID: String, category: String) -> [OpAuthor.Categorization] {
    targets.map { ($0.txnID, $0.version, category, false, CategorySource(kind: .rule, ruleID: ruleID)) }
  }
}

extension OpAuthor {
  public typealias GroupRulePlan = (
    id: String?, parentVersion: Int64?, draft: RuleDraft, unchanged: Bool, trims: [RuleSnapshot]
  )

  public static func groupRule(patterns: [String], category: String, existing: [RuleSnapshot]) -> GroupRulePlan? {
    guard !patterns.isEmpty, patterns.count <= RuleReach.maxPatterns else { return nil }
    let wanted = Set(patterns)
    let exact = existing.filter { !$0.draft.removed && $0.draft.match == .exact }
    let overlapping = exact.filter { !Set($0.draft.patterns).isDisjoint(with: wanted) }
    func shared(_ r: RuleSnapshot) -> Int { Set(r.draft.patterns).intersection(wanted).count }
    let primary = overlapping.enumerated().max { a, b in
      let sa = shared(a.element), sb = shared(b.element)
      if sa != sb { return sa < sb }
      let fa = a.element.draft.patterns.contains(patterns[0]), fb = b.element.draft.patterns.contains(patterns[0])
      if fa != fb { return !fa }
      if a.element.draft.enabled != b.element.draft.enabled { return !a.element.draft.enabled }
      if a.element.draft.patterns.count != b.element.draft.patterns.count {
        return a.element.draft.patterns.count < b.element.draft.patterns.count
      }
      return a.offset > b.offset
    }?.element
    var id: String?
    var parentVersion: Int64?
    var draft = RuleDraft(patterns: patterns, match: .exact, category: category, priority: 100, origin: "learned")
    var unchanged = false
    var trims: [RuleSnapshot] = []
    if let primary {
      let own = Set(primary.draft.patterns)
      let covers = wanted.isSubset(of: own)
      if primary.draft.category == category && primary.draft.enabled && covers {
        id = primary.id
        parentVersion = primary.version
        draft = primary.draft
        unchanged = true
      } else if wanted.union(own).count <= RuleReach.maxPatterns {
        id = primary.id
        parentVersion = primary.version
        draft = primary.draft
        draft.category = category
        draft.enabled = true
        if !covers { draft.patterns = patterns + primary.draft.patterns.filter { !wanted.contains($0) } }
      } else {
        var d = primary.draft
        d.patterns = primary.draft.patterns.filter { !wanted.contains($0) }
        if d.patterns.isEmpty { d.removed = true }
        trims.append(RuleSnapshot(id: primary.id, version: primary.version, draft: d))
      }
    }
    for r in exact where r.id != id && r.id != primary?.id && r.draft.enabled && r.draft.category != category {
      let left = r.draft.patterns.filter { !wanted.contains($0) }
      guard left.count != r.draft.patterns.count else { continue }
      var d = r.draft
      if left.isEmpty { d.removed = true } else { d.patterns = left }
      trims.append(RuleSnapshot(id: r.id, version: r.version, draft: d))
    }
    return (id, parentVersion, draft, unchanged, trims)
  }
}
