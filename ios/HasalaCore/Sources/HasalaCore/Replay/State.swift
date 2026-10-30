// The materialized state a fold produces (replay/state.ts, ported; spec 03c §11,
// 03a §4.1, 03b §3-§4 for the v4 additions).
//
// Every field is a deterministic function of (the ops, their positions) and
// nothing else: no clock, no randomness, no iteration over an unordered
// collection (every map is an `OrderedDictionary`, every set an `OrderedSet`;
// spec 04 §2.4 R3). Money is `Int64` minor units (critic A-21); every product
// goes through `Int128`.
//
// `serializeState` (Serialize.swift) is the witness: what it emits is the
// convergence claim, and on v1-v3 logs it is byte-identical to the TypeScript
// oracle's. v4 fields are emitted only when not at their default (03c §1.9), so
// a v3 log's witness is unchanged.
import CoreJSON
import HasalaText
import OrderedCollections

/// The implicit rate of the home currency against itself, 1.000000 in rate
/// micro units (spec §3.7:124).
public let homeIdentityMicro: Int64 = 1_000_000

/// The writer id the retired server ingest pipeline wrote under. Hasala has no
/// server ingest writer; the fold keeps the rule so v3 logs fold as they did.
public let ingestWriterID = "ingest"

// MARK: - Transactions

/// One part of a split. `note` is v4 (03c §3.3).
public struct Split: Sendable, Equatable, Codable {
  public var category: String
  public var amountMinor: Int64
  public var note: String?

  public init(
    category: String, amountMinor: Int64, note: String? = nil
  ) {
    self.category = category
    self.amountMinor = amountMinor
    self.note = note
  }
}

/// Who or what decided a transaction's category (03c §3.2.1).
public struct CategorySource: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Codable, CaseIterable {
    case none, user, held, rule, dictionary, model
  }
  public var kind: Kind
  /// `rule` (required) and `held` (optional).
  public var ruleID: String?
  /// `dictionary`.
  public var bundle: String?
  /// `dictionary`: `<match>:<pattern>`.
  public var entry: String?
  /// `model`.
  public var model: String?

  public init(kind: Kind, ruleID: String? = nil, bundle: String? = nil, entry: String? = nil, model: String? = nil) {
    self.kind = kind
    self.ruleID = ruleID
    self.bundle = bundle
    self.entry = entry
    self.model = model
  }

  public static let none = CategorySource(kind: .none)
  public static let user = CategorySource(kind: .user)

  /// The projection's `category_source_ref` (03c §3.9.1): the rule id, `<bundle>|<entry>`, the
  /// model tag, or nil.
  public var ref: String? {
    switch kind {
    case .rule, .held: ruleID
    case .dictionary: (bundle ?? "") + "|" + (entry ?? "")
    case .model: model
    case .none, .user: nil
    }
  }
}

/// The mailbox lane's gate verdicts, stored for display only (03c §3.1; never
/// trust). Unknown keys are not kept.
public struct TxnGates: Sendable, Equatable, Codable {
  public var ar: String?
  public var sender: String?
  public var template: String?
  public var card: String?
  public var forwarded: Bool?
  public var kind: String?

  public static let kinds = ["transfer_notice", "account_debit_alert"]

  public init(
    ar: String? = nil, sender: String? = nil, template: String? = nil, card: String? = nil, forwarded: Bool? = nil,
    kind: String? = nil
  ) {
    self.ar = ar
    self.sender = sender
    self.template = template
    self.card = card
    self.forwarded = forwarded
    self.kind = kind
  }

  public var verified: Bool { ar == "pass" && sender == "trusted" }
  public var senderUnverified: Bool { ar != nil && !verified }
}

/// A transaction as the client shows it (state.ts `Txn`, plus 03c §11).
public struct Txn: Sendable, Equatable, Codable {
  public var id: String
  public var ingestID: String
  public var amountMinor: Int64
  public var currency: String
  /// `"debit"`, `"credit"`, or `""` only when unparsed.
  public var direction: String
  /// Canonical UTC instant.
  public var postedAt: String
  public var merchantRaw: String
  public var last4: String
  public var category: String?
  public var needsReview: Bool
  public var unparsed: Bool
  /// `"template"`, `"heuristic"` or `"none"`.
  public var tier: String
  public var parseError: String?
  /// `"ingest"` or `"user"`, from the writer, never the payload.
  public var provenance: String
  public var amountHomeMinor: Int64?
  public enum HomeSource: String, Sendable, Equatable, Codable {
    case identity, rate, stated
  }
  public var homeSource: HomeSource? = nil
  public var homeRateMicro: Int64? = nil
  public var splits: [Split]
  public var supersededBy: String?
  public var possibleDuplicateOf: String?
  public var verifiedOriginDomain: String?
  public var mailboxMessageID: String?
  public var duplicateDisposition: String?
  public var version: Int64

  // v4 (03c §11): omitted from the witness at their defaults.
  public var categorySource: CategorySource?
  public var entryMethod: String?
  public var location: String?
  public var postedPrecision: String?
  public var bank: String?
  public var gates: TxnGates?
  public var successorID: String?
  public var sourceMailbox: String?
  public var sourceProvider: String?
  public var retiredBy: String?
  public var dedupe: TxnDedupe?
  public var mergedInto: String?
  public var mergeKind: String?
  public var mergeOp: String?
  public var aliases: [TxnAlias] = []
  public var copyOf: String?
  public var copyDecision: String?
  public var channel: String? = nil
  public var receivedAt: String? = nil
  /// field → keyed value (03c §3.5); every value is a string or a clear.
  public var annotations: OrderedDictionary<String, Keyed<String?>> = [:]

  /// The annotation `field`'s current value, or nil when unset or cleared.
  public func annotation(_ field: String) -> String? { annotations[field]?.value ?? nil }

  /// state.ts `countsTowardMoney`.
  public var countsTowardMoney: Bool { !unparsed }
  public var isLive: Bool { supersededBy == nil && retiredBy == nil && mergedInto == nil }
  public var isHeldCopy: Bool { copyOf != nil && copyDecision == nil && isLive }
  public var verifiedSender: Bool { gates?.verified ?? false }
  public var isText: Bool { channel.map { utf8Equal($0, TxnChannel.sms) } ?? false }
}

public enum TxnChannel {
  public static let sms = "sms"
}

// MARK: - Rules, categories, configuration

/// A user rule, in its v3 shape (`pattern`, `match ∈ exact|contains|regex`) or,
/// once a v4 op wrote it, its v4 shape (03c §5.1).
public struct Rule: Sendable, Equatable, Codable {
  /// 3 for a rule last written by a v≤3 op, 4 otherwise.
  public var shape: Int
  /// v3: one pattern. v4: 1-8 alternatives.
  public var patterns: [String]
  public var match: String
  public var category: String
  public var priority: Int64
  public var enabled: Bool
  public var removed: Bool
  /// `"manual"`, `"learned"`, or `"legacy"` for a v3-shape rule.
  public var origin: String
  /// The create op's canonical `authored_at` (v4 shape); nil for a v3 rule.
  public var createdAt: String?
  public var version: Int64

  public init(
    shape: Int, patterns: [String], match: String, category: String, priority: Int64, enabled: Bool, removed: Bool, origin: String, createdAt: String? = nil, version: Int64
  ) {
    self.shape = shape
    self.patterns = patterns
    self.match = match
    self.category = category
    self.priority = priority
    self.enabled = enabled
    self.removed = removed
    self.origin = origin
    self.createdAt = createdAt
    self.version = version
  }
}

public struct BudgetSplit: Sendable, Equatable, Codable {
  public var need: Int64
  public var want: Int64
  public var saving: Int64

  public init(need: Int64, want: Int64, saving: Int64) {
    self.need = need
    self.want = want
    self.saving = saving
  }
}

/// A category definition (state.ts `CategoryDef`), v3 shape (`color`) or v4
/// shape (`icon`, 03c §4.2).
public struct CategoryDef: Sendable, Equatable, Codable {
  public var shape: Int
  public var id: String
  public var name: String
  /// `"spending"`, `"income"` or `"excluded"`.
  public var kind: String
  /// `"need"`, `"want"` or `"saving"` exactly when spending.
  public var bucket: String?
  public var color: String?
  public var icon: String?
  public var parent: String?
  public var active: Bool

  public init(
    shape: Int, id: String, name: String, kind: String, bucket: String? = nil, color: String? = nil, icon: String? = nil, parent: String? = nil,
    active: Bool
  ) {
    self.shape = shape
    self.id = id
    self.name = name
    self.kind = kind
    self.bucket = bucket
    self.color = color
    self.icon = icon
    self.parent = parent
    self.active = active
  }
}

// MARK: - Bookkeeping

/// The current head of one versioned entity, and the op that owns it.
public struct EntityHead: Sendable, Equatable, Codable {
  public var kind: String
  public var id: String
  public var version: Int64
  public var opID: String
  public var writerID: String
  public var authoredAtMs: Int64
  public var categorizedAtMs: Int64?

  public init(
    kind: String, id: String, version: Int64, opID: String, writerID: String, authoredAtMs: Int64, categorizedAtMs: Int64? = nil
  ) {
    self.kind = kind
    self.id = id
    self.version = version
    self.opID = opID
    self.writerID = writerID
    self.authoredAtMs = authoredAtMs
    self.categorizedAtMs = categorizedAtMs
  }
}

public struct ForkNotice: Sendable, Equatable, Codable {
  public var entityKind: String
  public var entityID: String
  public var winnerOp: String
  public var loserOp: String
  public var atSeq: Int64

  public init(
    entityKind: String, entityID: String, winnerOp: String, loserOp: String, atSeq: Int64
  ) {
    self.entityKind = entityKind
    self.entityID = entityID
    self.winnerOp = winnerOp
    self.loserOp = loserOp
    self.atSeq = atSeq
  }
}

/// Something the fold refused, recorded rather than dropped. `detail` is
/// Swift-canonical (A-21): only `kind` and `atSeq` are compared across executors.
public struct Anomaly: Sendable, Equatable, Codable {
  public var kind: String
  public var detail: String
  public var atSeq: Int64

  public init(
    kind: String, detail: String, atSeq: Int64
  ) {
    self.kind = kind
    self.detail = detail
    self.atSeq = atSeq
  }
}

/// A blob that could not be decoded, set aside with a visible warning.
public struct Unreadable: Sendable, Equatable, Codable {
  public var writerID: String
  public var stream: String
  public var writerCounter: Int64
  public var seq: Int64
  public var reason: String

  public init(
    writerID: String, stream: String, writerCounter: Int64, seq: Int64, reason: String
  ) {
    self.writerID = writerID
    self.stream = stream
    self.writerCounter = writerCounter
    self.seq = seq
    self.reason = reason
  }
}

public struct CheckpointEntry: Sendable, Equatable, Codable {
  public var writerID: String
  public var stream: String
  public var counter: Int64
  public var hash: String

  public init(
    writerID: String, stream: String, counter: Int64, hash: String
  ) {
    self.writerID = writerID
    self.stream = stream
    self.counter = counter
    self.hash = hash
  }
}

public struct Cursors: Sendable, Equatable, Codable {
  public var hot: Int64 = 0
  public var cold: Int64 = 0
}

public struct TxnDedupe: Sendable, Equatable, Codable {
  public var messageID: String?
  public var bankRef: String?

  public init(messageID: String? = nil, bankRef: String? = nil) {
    self.messageID = messageID
    self.bankRef = bankRef
  }

  public var keys: [String] {
    [messageID.map { "mid:" + $0 }, bankRef.map { "ref:" + $0 }].compactMap { $0 }
  }
}

public struct TxnAlias: Sendable, Equatable, Codable {
  public var txnID: String
  public var ingestID: String
  public var sourceMailbox: String?
  public var sourceProvider: String?
  public var mailboxMessageID: String?
  public var kind: String

  public init(
    txnID: String, ingestID: String, sourceMailbox: String?, sourceProvider: String?, mailboxMessageID: String?,
    kind: String
  ) {
    self.txnID = txnID
    self.ingestID = ingestID
    self.sourceMailbox = sourceMailbox
    self.sourceProvider = sourceProvider
    self.mailboxMessageID = mailboxMessageID
    self.kind = kind
  }
}

public struct MailboxRetirement: Sendable, Equatable, Codable {
  public var opID: String
  public var grantID: String
  public var provider: String
  public var legacy: Bool
  public var atSeq: Int64
  public var txnIDs: [String]

  public init(opID: String, grantID: String, provider: String, legacy: Bool, atSeq: Int64, txnIDs: [String]) {
    self.opID = opID
    self.grantID = grantID
    self.provider = provider
    self.legacy = legacy
    self.atSeq = atSeq
    self.txnIDs = txnIDs
  }
}

// MARK: - Projects and goals (03c §6)

public struct Project: Sendable, Equatable, Codable {
  public var name: String
  public var startsOn: String?
  public var endsOn: String?
  public var budgetMinor: Int64?
  public var countInPlan: Bool
  /// `"active"`, `"completed"` or `"removed"`.
  public var status: String
  public var completedOn: String?
  public var icon: String?
  public var createdAt: String
  public var version: Int64

  public init(
    name: String, startsOn: String? = nil, endsOn: String? = nil, budgetMinor: Int64? = nil, countInPlan: Bool, status: String, completedOn: String? = nil, icon: String? = nil, createdAt: String, version: Int64
  ) {
    self.name = name
    self.startsOn = startsOn
    self.endsOn = endsOn
    self.budgetMinor = budgetMinor
    self.countInPlan = countInPlan
    self.status = status
    self.completedOn = completedOn
    self.icon = icon
    self.createdAt = createdAt
    self.version = version
  }
}

public struct GoalSource: Sendable, Equatable, Codable {
  /// `"category"` or `"account"`.
  public var kind: String
  public var categoryID: String?
  public var since: String?
  public var accountID: String?

  public init(
    kind: String, categoryID: String? = nil, since: String? = nil, accountID: String? = nil
  ) {
    self.kind = kind
    self.categoryID = categoryID
    self.since = since
    self.accountID = accountID
  }
}

public struct Goal: Sendable, Equatable, Codable {
  public var name: String
  public var targetMinor: Int64
  public var targetMonth: String?
  public var source: GoalSource
  public var startingMinor: Int64
  public var status: String
  public var completedOn: String?
  public var icon: String?
  public var createdAt: String
  public var version: Int64

  public init(
    name: String, targetMinor: Int64, targetMonth: String? = nil, source: GoalSource, startingMinor: Int64, status: String, completedOn: String? = nil, icon: String? = nil, createdAt: String, version: Int64
  ) {
    self.name = name
    self.targetMinor = targetMinor
    self.targetMonth = targetMonth
    self.source = source
    self.startingMinor = startingMinor
    self.status = status
    self.completedOn = completedOn
    self.icon = icon
    self.createdAt = createdAt
    self.version = version
  }
}

// MARK: - Plan (03a §4.1)

public struct PlanWrite: Sendable, Equatable, Codable {
  public var opID: String
  public var writerID: String
  public var atMs: Int64

  public init(
    opID: String, writerID: String, atMs: Int64
  ) {
    self.opID = opID
    self.writerID = writerID
    self.atMs = atMs
  }
}

public struct PlanCell: Sendable, Equatable, Codable {
  public var latestSet: Int64?
  public var onwardSet: Int64?
  public var movesAll: Int64 = 0
  public var movesSinceSet: Int64 = 0
  public var latestSetWrite: PlanWrite?

  public init(
    latestSet: Int64? = nil, onwardSet: Int64? = nil, movesAll: Int64 = 0, movesSinceSet: Int64 = 0, latestSetWrite: PlanWrite? = nil
  ) {
    self.latestSet = latestSet
    self.onwardSet = onwardSet
    self.movesAll = movesAll
    self.movesSinceSet = movesSinceSet
    self.latestSetWrite = latestSetWrite
  }
}

public struct PlanOverwrite: Sendable, Equatable, Codable {
  public var keyKind: String
  public var key: String
  public var replacedOp: String
  public var byOp: String
  public var atSeq: Int64
  public var replacedValue: String

  public init(
    keyKind: String, key: String, replacedOp: String, byOp: String, atSeq: Int64, replacedValue: String
  ) {
    self.keyKind = keyKind
    self.key = key
    self.replacedOp = replacedOp
    self.byOp = byOp
    self.atSeq = atSeq
    self.replacedValue = replacedValue
  }
}

public struct MoveRecord: Sendable, Equatable, Codable {
  public var opID: String
  public var position: OpPosition
  public var month: String
  public var from: String?
  public var to: String?
  public var amount: Int64
  /// `move`, `assign`, `auto_assign` or `undo`.
  public var reason: String
  public var batchID: String?
  public var undoes: String?
  public var undone: Bool

  public init(
    opID: String, position: OpPosition, month: String, from: String? = nil, to: String? = nil, amount: Int64, reason: String, batchID: String? = nil, undoes: String? = nil, undone: Bool
  ) {
    self.opID = opID
    self.position = position
    self.month = month
    self.from = from
    self.to = to
    self.amount = amount
    self.reason = reason
    self.batchID = batchID
    self.undoes = undoes
    self.undone = undone
  }
}

public struct IncomeSource: Sendable, Equatable, Codable {
  public var id: String
  public var name: String
  public var categoryID: String
  public var amountMinor: Int64
  public var payday: Int64
  public var active: Bool
  public var write: PlanWrite

  public init(
    id: String, name: String, categoryID: String, amountMinor: Int64, payday: Int64, active: Bool, write: PlanWrite
  ) {
    self.id = id
    self.name = name
    self.categoryID = categoryID
    self.amountMinor = amountMinor
    self.payday = payday
    self.active = active
    self.write = write
  }
}

public struct PlanRoleRecord: Sendable, Equatable, Codable {
  /// `"everyday"` or `"bills"`.
  public var role: String
  public var write: PlanWrite

  public init(
    role: String, write: PlanWrite
  ) {
    self.role = role
    self.write = write
  }
}

public struct PlanState: Sendable, Equatable, Codable {
  /// category → month (`YYYY-MM`) → cell.
  public var cells: OrderedDictionary<String, OrderedDictionary<String, PlanCell>> = [:]
  /// op id → move, in position order.
  public var moves: OrderedDictionary<String, MoveRecord> = [:]
  public var incomeSources: OrderedDictionary<String, IncomeSource> = [:]
  public var roles: OrderedDictionary<String, PlanRoleRecord> = [:]
  public var overwrites: [PlanOverwrite] = []

  public init() {}

  public var isEmpty: Bool {
    cells.isEmpty && moves.isEmpty && incomeSources.isEmpty && roles.isEmpty && overwrites.isEmpty
  }
}

// MARK: - Bills and accounts (03b §3-§4; minimal for the beta)

public struct BillCadence: Sendable, Equatable, Codable {
  public var unit: String
  public var every: Int64

  public init(
    unit: String, every: Int64
  ) {
    self.unit = unit
    self.every = every
  }
}

public struct BillChange: Sendable, Equatable, Codable {
  public var from: String
  public var amountMode: String
  public var amountMinor: Int64
  public var toleranceBp: Int64?

  public init(
    from: String, amountMode: String, amountMinor: Int64, toleranceBp: Int64? = nil
  ) {
    self.from = from
    self.amountMode = amountMode
    self.amountMinor = amountMinor
    self.toleranceBp = toleranceBp
  }
}

public struct BillPause: Sendable, Equatable, Codable {
  public var from: String
  public var until: String?

  public init(
    from: String, until: String? = nil
  ) {
    self.from = from
    self.until = until
  }
}

public struct Bill: Sendable, Equatable, Codable {
  public var name: String
  public var keys: [String]
  public var direction: String
  public var currency: String
  public var amountMode: String
  public var amountMinor: Int64
  public var toleranceBp: Int64?
  public var cadence: BillCadence
  public var anchor: String
  public var start: String
  public var end: String?
  public var category: String?
  public var account: String?
  public var source: String
  public var status: String
  public var changes: [BillChange]
  public var pauses: [BillPause]
  public var createdAt: String?
  public var firstSeq: Int64
  public var version: Int64

  public init(
    name: String, keys: [String], direction: String, currency: String, amountMode: String, amountMinor: Int64, toleranceBp: Int64? = nil, cadence: BillCadence, anchor: String, start: String, end: String? = nil, category: String? = nil, account: String? = nil, source: String, status: String, changes: [BillChange] = [], pauses: [BillPause] = [], createdAt: String? = nil, firstSeq: Int64, version: Int64
  ) {
    self.name = name
    self.keys = keys
    self.direction = direction
    self.currency = currency
    self.amountMode = amountMode
    self.amountMinor = amountMinor
    self.toleranceBp = toleranceBp
    self.cadence = cadence
    self.anchor = anchor
    self.start = start
    self.end = end
    self.category = category
    self.account = account
    self.source = source
    self.status = status
    self.changes = changes
    self.pauses = pauses
    self.createdAt = createdAt
    self.firstSeq = firstSeq
    self.version = version
  }
}

public struct BillResolution: Sendable, Equatable, Codable {
  public var bill: String
  public var due: String
  public var resolution: String
  public var txn: String?
  public var until: String?
  public var atSeq: Int64

  public init(
    bill: String, due: String, resolution: String, txn: String? = nil, until: String? = nil, atSeq: Int64
  ) {
    self.bill = bill
    self.due = due
    self.resolution = resolution
    self.txn = txn
    self.until = until
    self.atSeq = atSeq
  }
}

public struct Account: Sendable, Equatable, Codable {
  public var id: String
  public var name: String
  public var institution: String?
  public var kind: String
  public var inPlan: Bool
  public var currency: String
  public var statementDueDay: Int64?
  public var active: Bool
  public var closedOn: String?
  public var color: String?
  public var firstSeq: Int64

  public init(
    id: String, name: String, institution: String? = nil, kind: String, inPlan: Bool, currency: String, statementDueDay: Int64? = nil, active: Bool, closedOn: String? = nil, color: String? = nil, firstSeq: Int64
  ) {
    self.id = id
    self.name = name
    self.institution = institution
    self.kind = kind
    self.inPlan = inPlan
    self.currency = currency
    self.statementDueDay = statementDueDay
    self.active = active
    self.closedOn = closedOn
    self.color = color
    self.firstSeq = firstSeq
  }
}

public struct CardLink: Sendable, Equatable, Codable {
  public var bank: String?
  public var last4: String
  /// `"mine"` or `"not_mine"`.
  public var state: String
  public var account: String?
  public var atSeq: Int64

  public init(
    bank: String? = nil, last4: String, state: String, account: String? = nil, atSeq: Int64
  ) {
    self.bank = bank
    self.last4 = last4
    self.state = state
    self.account = account
    self.atSeq = atSeq
  }
}

public struct Checkin: Sendable, Equatable, Codable {
  public var id: String
  public var account: String
  public var asOf: String
  public var balanceMinor: Int64
  public var source: String
  public var resolution: String?
  public var adjustmentMinor: Int64?
  public var void: Bool
  public var atSeq: Int64

  public init(
    id: String, account: String, asOf: String, balanceMinor: Int64, source: String, resolution: String? = nil, adjustmentMinor: Int64? = nil, void: Bool, atSeq: Int64
  ) {
    self.id = id
    self.account = account
    self.asOf = asOf
    self.balanceMinor = balanceMinor
    self.source = source
    self.resolution = resolution
    self.adjustmentMinor = adjustmentMinor
    self.void = void
    self.atSeq = atSeq
  }
}

public struct MerchantRejection: Sendable, Equatable, Codable {
  public var merchantKey: String
  public var category: String
  public var rejected: Bool
  public var opID: String

  public init(merchantKey: String, category: String, rejected: Bool, opID: String) {
    self.merchantKey = merchantKey
    self.category = category
    self.rejected = rejected
    self.opID = opID
  }
}

// MARK: - State

public struct State: Sendable, Equatable, Codable {
  // v3 (witnessed)
  public var txns: OrderedDictionary<String, Txn> = [:]
  /// ingest_id → the one live txn id.
  public var liveByIngestID: OrderedDictionary<String, String> = [:]
  /// fingerprint → live txn ids in fold order (order is load-bearing).
  public var byFingerprint: OrderedDictionary<ExactKey, [String]> = [:]
  public var rules: OrderedDictionary<String, Rule> = [:]
  public var homeCurrency: String?
  /// The head rate per currency; a present nil is a live `rate_unset`.
  public var rates: OrderedDictionary<String, Int64?> = [:]
  public var rateUpdatedAt: OrderedDictionary<String, String> = [:]
  /// bank → declared; insertion order is first-declaration order.
  public var banks: OrderedDictionary<ExactKey, Bool> = [:]
  public var budgetSplit: BudgetSplit?
  public var budgetMonthlyTotal: Int64?
  /// id → definition; insertion order is first-definition order (03c §4.4 `ord`).
  public var categories: OrderedDictionary<ExactKey, CategoryDef> = [:]
  public var pendingByCurrency: OrderedDictionary<String, OrderedSet<String>> = [:]
  public var checkpoints: [CheckpointEntry] = []
  public var forks: [ForkNotice] = []
  public var anomalies: [Anomaly] = []
  public var unreadable: [Unreadable] = []
  public var cursors = Cursors()
  /// `kind\0id` → head. Never pruned.
  public var heads: OrderedDictionary<String, EntityHead> = [:]

  // v4 (witnessed when non-empty, 03c §1.9)
  public var merchantNames: OrderedDictionary<ExactKey, Keyed<String?>> = [:]
  public var merchantRejections: OrderedDictionary<String, MerchantRejection> = [:]
  public var senderTrust: OrderedDictionary<String, Keyed<Bool>> = [:]
  public var projects: OrderedDictionary<String, Project> = [:]
  public var goals: OrderedDictionary<String, Goal> = [:]
  public var plan = PlanState()
  public var bills: OrderedDictionary<String, Bill> = [:]
  /// `bill\0due` → resolution.
  public var billResolutions: OrderedDictionary<String, BillResolution> = [:]
  public var accounts: OrderedDictionary<String, Account> = [:]
  /// `bank\0last4` → link.
  public var cards: OrderedDictionary<String, CardLink> = [:]
  public var checkins: OrderedDictionary<String, Checkin> = [:]
  public var mailboxRetirements: [MailboxRetirement] = []
  public var byDedupeKey: OrderedDictionary<String, String> = [:]
  public var copyCandidates: OrderedDictionary<ExactKey, [String]> = [:]
  public var mergedIngest: OrderedDictionary<String, String> = [:]

  // Not witnessed: delivery bookkeeping and derived values.
  /// The op ids applied at `cursors.hot` (the duplicate-delivery guard).
  public var appliedAtCursor: OrderedSet<String> = []
  /// Per-writer largest `authored_at` (ms) over every op visited (03c §1.8.2).
  public var maxAuthored: OrderedDictionary<String, Int64> = [:]

  public init() {}

  /// The key a head is filed under: NUL-joined, so no kind/id pair collides.
  public static func entityKey(_ kind: String, _ id: String) -> String { kind + "\u{0}" + id }
}
