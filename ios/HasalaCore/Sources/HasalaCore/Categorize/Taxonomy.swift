// Taxonomy v1 (spec 03c §4.1): the 18 built-in categories, implicit constants
// that every account has with no op. A `category_defined` with a built-in id
// overrides it. The taxonomy is applied by readers and the pipeline, never by
// the fold (03c §1.11 rule 3).
//
// It lives in CoreCategorize, the lowest module that needs it (the dictionary
// gate and `decide`); CoreDomain's `TaxonomyView` and the projection build on it.
import HasalaText

public enum CategoryKind: String, Sendable, Codable, CaseIterable {
  case spending, income, excluded
}

public enum Bucket: String, Sendable, Codable, CaseIterable {
  case need, want, saving
}

public enum Hue: String, Sendable, Codable {
  case sand, lilac, mint, sky, grey

  /// 03c §4.1: hue is a function of kind and bucket, never data.
  public static func of(_ kind: CategoryKind, _ bucket: Bucket?) -> Hue {
    switch (kind, bucket) {
    case (.spending, .need?): .sand
    case (.spending, .want?): .lilac
    case (.spending, .saving?): .mint
    case (.income, _): .sky
    default: .grey
    }
  }
}

/// One category as readers see it: a built-in, a built-in overridden, or a
/// user category.
public struct CategoryInfo: Sendable, Equatable {
  public let id: String
  public let name: String
  public let kind: CategoryKind
  public let bucket: Bucket?
  public let icon: String
  public let active: Bool
  public let builtin: Bool
  /// `category.ord`: the taxonomy ord for a built-in, `100 + first-definition index` for a user id.
  public let sortKey: Int

  public init(id: String, name: String, kind: CategoryKind, bucket: Bucket?, icon: String, active: Bool, builtin: Bool, sortKey: Int) {
    self.id = id
    self.name = name
    self.kind = kind
    self.bucket = bucket
    self.icon = icon
    self.active = active
    self.builtin = builtin
    self.sortKey = sortKey
  }

  public var hue: Hue { Hue.of(kind, bucket) }
}

public enum TaxonomyV1 {
  public static let version = 1

  /// The 18 built-ins in Paper order (03c §4.1).
  public static let builtins: [CategoryInfo] = [
    b(1, "rent", "Rent", .spending, .need, "house"),
    b(2, "utilities", "Utilities", .spending, .need, "bolt"),
    b(3, "groceries", "Groceries", .spending, .need, "basket"),
    b(4, "transport", "Transport", .spending, .need, "car"),
    b(5, "healthcare", "Healthcare", .spending, .need, "cross"),
    b(6, "insurance", "Insurance", .spending, .need, "shield_check"),
    b(7, "dining", "Dining", .spending, .want, "fork_knife"),
    b(8, "entertainment", "Entertainment", .spending, .want, "ticket"),
    b(9, "shopping", "Shopping", .spending, .want, "bag"),
    b(10, "travel", "Travel", .spending, .want, "plane"),
    b(11, "subscriptions", "Subscriptions", .spending, .want, "repeat"),
    b(12, "savings", "Savings", .spending, .saving, "jar"),
    b(13, "investments", "Investments", .spending, .saving, "trend"),
    b(14, "debt", "Debt", .spending, .saving, "card"),
    b(15, "salary", "Salary", .income, nil, "briefcase"),
    b(16, "freelance", "Freelance", .income, nil, "laptop"),
    b(17, "transfer", "Transfer", .excluded, nil, "arrows_swap"),
    b(18, "refunds", "Refunds", .excluded, nil, "receipt"),
  ]

  private static func b(_ ord: Int, _ id: String, _ name: String, _ kind: CategoryKind, _ bucket: Bucket?, _ icon: String) -> CategoryInfo {
    CategoryInfo(id: id, name: name, kind: kind, bucket: bucket, icon: icon, active: true, builtin: true, sortKey: ord)
  }

  public static func builtin(_ id: String) -> CategoryInfo? { builtins.first { utf8Equal($0.id, id) } }

  /// The default icon of a user category (03c §4.2).
  public static let userIcon = "tag"

  /// 03c §4.1 section labels.
  public static func sectionLabel(kind: CategoryKind, bucket: Bucket?) -> String {
    switch (kind, bucket) {
    case (.spending, .need?): "Needs"
    case (.spending, .want?): "Wants"
    case (.spending, .saving?): "Savings"
    case (.income, _): "Income"
    default: "Not spending"
    }
  }

  /// The model-tier hints of 03c §8.6.4.
  public static let modelHints: [(id: String, hint: String)] = [
    ("rent", "rent and housing payments"), ("utilities", "electricity, water, gas, telecom, internet"),
    ("groceries", "supermarkets and grocery stores"), ("transport", "taxis, ride-hailing, fuel, parking, tolls, public transport"),
    ("healthcare", "pharmacies, clinics, hospitals"), ("insurance", "insurance premiums"),
    ("dining", "restaurants, cafes, food delivery"), ("entertainment", "cinemas, events, games, leisure"),
    ("shopping", "retail, clothing, electronics, online marketplaces"), ("travel", "airlines, hotels, travel agencies"),
    ("subscriptions", "recurring digital services and memberships"),
  ]
}

/// The effective category table a decision is made against: the taxonomy
/// overlaid with the account's definitions. Built by CoreDomain's
/// `TaxonomyView` or the projection; the pipeline only reads it.
public protocol CategoryLookup: Sendable {
  func info(_ id: String) -> CategoryInfo?
}

/// The built-ins alone (no account definitions).
public struct BuiltinCategories: CategoryLookup {
  public init() {}
  public func info(_ id: String) -> CategoryInfo? { TaxonomyV1.builtin(id) }
}
