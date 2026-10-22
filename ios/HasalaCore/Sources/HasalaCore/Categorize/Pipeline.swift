// The categorization pipeline (spec 03c §8.1-§8.4, §5.4; 04 §8.1):
// (1) user rules → (2) the bundled dictionary → (3) the model (suggestion,
// ModelTier) → (4) the review queue. Tiers 1-2 are deterministic and FILE a
// row; nothing here reads a clock or the network.
import HasalaText

/// Where a deterministic decision came from (03c §3.2.1, the `rule` and
/// `dictionary` kinds; `none` otherwise).
public enum DecisionSource: Sendable, Equatable {
  case none
  case rule(id: String)
  case dictionary(bundle: String, entry: String)
}

/// `decide`'s answer (03c §8.2).
public struct Decision: Sendable, Equatable {
  public let category: String?
  public let source: DecisionSource
  /// The dictionary display name of the entry that matched (03c §3.6 precedence).
  public let display: String?
  /// A spending decision on a credit: not filed (`none`), but the sheet pre-selects it.
  public let suggested: String?

  public static let none = Decision(category: nil, source: .none, display: nil, suggested: nil)

  public init(category: String?, source: DecisionSource, display: String?, suggested: String?) {
    self.category = category
    self.source = source
    self.display = display
    self.suggested = suggested
  }
}

public enum Direction: String, Sendable {
  case debit, credit
}

/// Rules and dictionary prepared once per sweep, against the effective category table.
public struct Categorizer: Sendable {
  public let prepared: PreparedRules
  public let bundle: String
  public let categories: any CategoryLookup

  public init(rules: [RuleInput], dictionary: MerchantDictionary, categories: any CategoryLookup) {
    prepared = Matcher.prepare(rules: rules, entries: dictionary.entries, categories: categories)
    bundle = dictionary.bundle
    self.categories = categories
  }

  /// 03c §8.2 `decide`: the first rule hit, else the first dictionary hit, whose
  /// category is active; a spending category on a credit is only a suggestion.
  public func decide(merchantRaw: String, direction: Direction) -> Decision {
    guard let hit = Matcher.firstHit(merchantRaw, prepared, accept: { categories.info($0.category)?.active == true }) else {
      return .none
    }
    if direction == .credit, categories.info(hit.category)?.kind == .spending {
      return Decision(category: nil, source: .none, display: hit.display, suggested: hit.category)
    }
    let source: DecisionSource =
      switch hit.source {
      case .rule: .rule(id: hit.id)
      case .dictionary: .dictionary(bundle: bundle, entry: MerchantDictionary.sourceEntry(hit))
      }
    return Decision(category: hit.category, source: source, display: hit.display, suggested: nil)
  }

  /// The dictionary display name for a merchant (03c §3.6: rename > dictionary `d` > prettify).
  public func dictionaryDisplay(merchantRaw: String) -> String? {
    let subject = Array(Canon.subject(merchantRaw).utf8)
    if subject.isEmpty { return nil }
    return prepared.entries.first { $0.hits(subject) }?.display
  }
}

// MARK: - Sweep (03c §8.4)

/// A projected row as the sweep reads it.
public struct SweepRow: Sendable, Equatable {
  public enum SourceKind: String, Sendable { case none, user, held, rule, dictionary, model }
  public let id: String
  public let merchantRaw: String
  public let direction: Direction?
  public let category: String?
  public let sourceKind: SourceKind
  /// `category_source_ref` (rule id, `<bundle>|<entry>`, model tag).
  public let sourceRef: String?
  public let needsReview: Bool
  /// Live, parsed, not archived and not split.
  public let candidate: Bool
  public let version: Int64?
  public let template: String?
  public let merchantGroup: String
  public let categorizedMs: Int64?

  public init(
    id: String, merchantRaw: String, direction: Direction?, category: String?, sourceKind: SourceKind, sourceRef: String?,
    needsReview: Bool, candidate: Bool, version: Int64? = nil, template: String? = nil, merchantGroup: String = "", categorizedMs: Int64? = nil
  ) {
    self.id = id
    self.merchantRaw = merchantRaw
    self.direction = direction
    self.category = category
    self.sourceKind = sourceKind
    self.sourceRef = sourceRef
    self.needsReview = needsReview
    self.candidate = candidate
    self.version = version
    self.template = template
    self.merchantGroup = merchantGroup
    self.categorizedMs = categorizedMs
  }
}

/// One `txn_categorized` the sweep wants authored (needs_review unchanged).
public struct SweepAction: Sendable, Equatable {
  public let txnID: String
  public let category: String
  public let source: DecisionSource
  public let needsReview: Bool
}

public enum Sweep {
  /// Max ops per blob (03c §8.4).
  public static let maxOpsPerBlob = 500

  /// Plans the sweep: re-files candidates whose deterministic decision changed,
  /// never un-files, never touches `user` or `held` rows; uncategorized debits
  /// with no decision join the model queue (by row id, newest first as given).
  public static func plan(_ rows: [SweepRow], _ categorizer: Categorizer) -> (actions: [SweepAction], modelQueue: [SweepRow]) {
    var actions: [SweepAction] = []
    var queue: [SweepRow] = []
    for r in rows where r.candidate {
      switch r.sourceKind {
      case .user, .held: continue
      default: break
      }
      guard let direction = r.direction else { continue }
      let d = categorizer.decide(merchantRaw: r.merchantRaw, direction: direction)
      guard let category = d.category else {
        if r.category == nil && direction == .debit { queue.append(r) }
        continue
      }
      let ref: String? =
        switch d.source {
        case .rule(let id): id
        case .dictionary(let b, let e): b + "|" + e
        case .none: nil
        }
      let kind: SweepRow.SourceKind =
        switch d.source {
        case .rule: .rule
        case .dictionary: .dictionary
        case .none: .none
        }
      if r.category == category && r.sourceKind == kind && r.sourceRef == ref { continue }
      actions.append(SweepAction(txnID: r.id, category: category, source: d.source, needsReview: r.needsReview))
    }
    return (actions, queue)
  }
}

// MARK: - Learned rules (03c §5.4)

public enum LearnedPattern {
  /// `learnedPattern(merchant_raw)`: `(contains, first token)` for a token of ≥ 4
  /// scalars with ≥ 3 letters, else `(starts_with, first two tokens)` of ≥ 3
  /// scalars, else `(exact, subject)` of ≥ 2, else nil. `userRows` are the
  /// live rows a person categorized: if the pattern would hit one whose
  /// category differs from `category`, fall back to exact (the overreach guard).
  /// A pattern over `maxScalars` (03c §5.1's rule-pattern limit) is nil: the
  /// "Always use" toggle is hidden rather than authoring a refused op.
  public static let maxScalars = 128

  public static func propose(merchantRaw: String, category: String, userRows: [(merchantRaw: String, category: String)] = [])
    -> (match: MatchKind, pattern: String)?
  {
    let s = Canon.subject(merchantRaw)
    let tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let t1 = tokens.first else { return nil }
    var candidate: (MatchKind, String)?
    let letters = t1.unicodeScalars.filter { $0.properties.isAlphabetic }.count
    if t1.unicodeScalars.count >= 4 && letters >= 3 {
      candidate = (.contains, t1)
    } else {
      let t12 = tokens.count > 1 ? t1 + " " + tokens[1] : t1
      if t12.unicodeScalars.count >= 3 {
        candidate = (.startsWith, t12)
      } else if s.unicodeScalars.count >= 2 {
        candidate = (.exact, s)
      }
    }
    guard let (match, pattern) = candidate else { return nil }
    let fits = { (p: String) in p.unicodeScalars.count <= maxScalars }
    if match != .exact {
      let p = PreparedPattern(id: "", pattern: pattern, match: match, category: category, priority: 100)
      if userRows.contains(where: { $0.category != category && Matcher.hits(p, merchantRaw: $0.merchantRaw) }) {
        return s.unicodeScalars.count >= 2 && fits(s) ? (.exact, s) : nil
      }
    }
    return fits(pattern) ? (match, pattern) : nil
  }
}
