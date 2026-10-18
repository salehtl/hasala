// The op model at schema 4: the type registry, the envelope fields and the
// structural rules every op obeys whatever its payload (wire/op.ts, ported;
// spec 00 §3 merged registry, 03c §2).
//
// What changed from the v3 oracle, and only this:
//   - `SchemaVersion.current` is 4, and `SchemaVersion.author` (what `OpAuthor`
//     stamps on every op and blob) is 4 too, always `<= current` (03c §2);
//   - 14 new types, each with `minVersion` 4 (the `SCHEMA_VERSION + 1` rule,
//     01 §6.6 R10), in the wire order of 00 §3;
//   - `profile_set` is RESERVED: no case here, so it decodes as an unknown type
//     and sets its whole blob aside (03c §2, §17; 01 T36).
//
// Payloads are not interpreted here (except the v3 duplicate-disposition shape,
// which the oracle checks at this layer); they belong to the fold.
import CoreJSON
import Foundation

public enum SchemaVersion {
  /// The highest op and blob `v` this build's decoder reads. A higher `v` is the
  /// hard stop "Update Hasala" (01 §6.6 R10).
  public static let current = 4
  /// The `v` `OpAuthor` stamps on every op it builds and on the blob that
  /// carries them (03c §2, `AUTHOR_VERSION`). Never above ``current``.
  public static let author = 4
}

/// Every op type at schema 4, in wire order (00 §3: the 14 v3 types in the
/// oracle's `OP_TYPES` order, then 03a's four, 03b's five and 03c's five).
public enum OpType: String, CaseIterable, Sendable, Hashable {
  // v3 (wire/op.ts OP_TYPES)
  case txnIngested = "txn_ingested"
  case txnSuperseded = "txn_superseded"
  case txnCategorized = "txn_categorized"
  case txnSplit = "txn_split"
  case txnEdited = "txn_edited"
  case txnDuplicateDisposition = "txn_duplicate_disposition"
  case ruleAdded = "rule_added"
  case rateSet = "rate_set"
  case rateUnset = "rate_unset"
  case homeCurrencySet = "home_currency_set"
  case bankDeclared = "bank_declared"
  case budgetSplitSet = "budget_split_set"
  case categoryDefined = "category_defined"
  case writerCheckpoint = "writer_checkpoint"
  // 03a
  case budgetSet = "budget_set"
  case budgetMoved = "budget_moved"
  case incomeSourceSet = "income_source_set"
  case categoryPlanRoleSet = "category_plan_role_set"
  // 03b
  case billSet = "bill_set"
  case billOccurrenceSet = "bill_occurrence_set"
  case accountSet = "account_set"
  case cardLinked = "card_linked"
  case accountCheckin = "account_checkin"
  // 03c
  case txnAnnotated = "txn_annotated"
  case merchantNamed = "merchant_named"
  case senderTrustSet = "sender_trust_set"
  case projectDefined = "project_defined"
  case goalDefined = "goal_defined"
  case mailboxRetired = "mailbox_retired"

  /// Type strings that are never registered and never reused. An op carrying
  /// one is an unknown type (03c §17).
  public static let reserved: [String] = ["profile_set"]

  /// The lowest schema `v` the type exists at (`MIN_VERSION`). An op whose `v`
  /// is below it is an envelope failure.
  public var minVersion: Int {
    switch self {
    case .txnDuplicateDisposition: 2
    case .bankDeclared, .budgetSplitSet, .categoryDefined: 3
    case .budgetSet, .budgetMoved, .incomeSourceSet, .categoryPlanRoleSet, .billSet, .billOccurrenceSet,
      .accountSet, .cardLinked, .accountCheckin, .txnAnnotated, .merchantNamed, .senderTrustSet,
      .projectDefined, .goalDefined, .mailboxRetired:
      4
    default: 1
    }
  }

  /// Parent-free ops name no entity and carry no `parent_version`; they fold by
  /// position (00 §3: rows 8-18 and 20-26).
  public var isParentFree: Bool { entityKind == nil }

  /// The entity kind a versioned op must name (03c §1.7 entity-kind registry);
  /// `nil` for a parent-free op.
  public var entityKind: String? {
    switch self {
    case .txnIngested, .txnSuperseded, .txnCategorized, .txnSplit, .txnEdited, .txnDuplicateDisposition: "txn"
    case .ruleAdded: "rule"
    case .billSet: "bill"
    case .projectDefined: "project"
    case .goalDefined: "goal"
    default: nil
    }
  }

  /// Whether the op carries an `ingest_id` (a 64-hex-character SHA-256).
  public var carriesIngestID: Bool { self == .txnIngested || self == .txnSuperseded }
}

public struct EntityRef: Sendable, Hashable {
  public let kind: String
  public let id: String

  package init(kind: String, id: String) {
    self.kind = kind
    self.id = id
  }
}

/// One operation. Its memberwise initializer is `package`: outside HasalaCore an
/// op comes only from a decoder or from `CoreDomain.OpAuthor` (spec 04 §2.4 R5).
public struct Op: Sendable, Hashable {
  public let v: Int
  public let type: OpType
  public let opID: String
  /// RFC 3339 UTC, millisecond precision, as canonicalized on decode and on
  /// encode. A fork tie-break only.
  public let authoredAt: String
  public let entity: EntityRef?
  /// A raw JSON number on the wire; `nil` writes `null`.
  public let parentVersion: Int64?
  /// Present only on `txn_ingested` and `txn_superseded`.
  public let ingestID: String?
  public let payload: JSONValue

  package init(
    v: Int, type: OpType, opID: String, authoredAt: String, entity: EntityRef? = nil, parentVersion: Int64? = nil,
    ingestID: String? = nil, payload: JSONValue
  ) {
    self.v = v
    self.type = type
    self.opID = opID
    self.authoredAt = authoredAt
    self.entity = entity
    self.parentVersion = parentVersion
    self.ingestID = ingestID
    self.payload = payload
  }
}
