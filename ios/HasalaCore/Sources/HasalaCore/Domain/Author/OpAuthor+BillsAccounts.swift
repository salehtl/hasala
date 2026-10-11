// `OpAuthor`'s bills-and-accounts authors (03b §1.4, §3.2-§4.4): `account_set`,
// `card_linked`, `bill_set`, `bill_occurrence_set` and `account_checkin`. Each
// payload is exactly what `Replay/V4/BillsAccounts.swift` decodes, key for key,
// and passes that decoder in `build()` like every other op.
//
// Ids follow 03b §1.4's author grammar: an account created from a card is
// derived from (bank, last4), so two iPhones that confirm the same card
// converge on one account; cash is `ac_cash`; every other account, manual bill
// and check-in id is 128 random bits.
import CoreJSON
import CorePrimitives
import CoreTime
import CoreWire
import Foundation

extension OpAuthor {
  // MARK: Ids (03b §1.4)

  /// The cash account's constant id.
  public static let cashAccountID = "ac_cash"

  /// `ac_` + the first 32 hex of SHA-256("hasala/v1/account-id" ‖ 0x00 ‖ bank ‖ 0x00 ‖ last4);
  /// `bank` is `""` when the card names none.
  public static func cardAccountID(bank: String?, last4: String) -> String {
    var b = Array("hasala/v1/account-id".utf8)
    b.append(0)
    b += Array((bank ?? "").utf8)
    b.append(0)
    b += Array(last4.utf8)
    return "ac_" + String(Hex.encode(sha256(b)).prefix(32))
  }

  /// `bd_` + the first 32 hex of SHA-256("hasala/v1/bill-id" ‖ 0x00 ‖ key ‖ 0x00 ‖ direction ‖ 0x00 ‖
  /// currency ‖ 0x00 ‖ tail): tail `A` for a Pass A series, `B ‖ 0x00 ‖ first_ingest_id` for Pass B.
  public static func detectedBillID(key: String, direction: String, currency: String, firstIngestID: String? = nil) -> String {
    var b = Array("hasala/v1/bill-id".utf8)
    for part in [key, direction, currency] {
      b.append(0)
      b += Array(part.utf8)
    }
    b.append(0)
    if let first = firstIngestID {
      b += Array("B".utf8)
      b.append(0)
      b += Array(first.utf8)
    } else {
      b += Array("A".utf8)
    }
    return "bd_" + String(Hex.encode(sha256(b)).prefix(32))
  }

  /// A random `ac_` account id (an account not created from a card, not cash).
  public func newAccountID() throws(AuthorError) -> String { "ac_" + (try randomHex()) }

  /// A random `bm_` id for a bill the person added.
  public func newManualBillID() throws(AuthorError) -> String { "bm_" + (try randomHex()) }

  /// A random `ck_` check-in id.
  public func newCheckinID() throws(AuthorError) -> String { "ck_" + (try randomHex()) }

  func randomHex() throws(AuthorError) -> String {
    do { return Hex.encode(try context.random.bytes(16)) } catch { throw .random }
  }

  // MARK: Accounts and cards (03b §4.2-§4.3)

  public enum AccountKind: String, Sendable, Equatable, CaseIterable {
    case current, savings, creditCard = "credit_card", cash, loan, investment, property, other

    /// 03b §4.2's default for `in_plan`: everyday money (current, savings,
    /// credit card, cash) counts in the plan; the rest is tracked only.
    public var inPlanByDefault: Bool {
      switch self {
      case .current, .savings, .creditCard, .cash: true
      case .loan, .investment, .property, .other: false
      }
    }
  }

  /// A money account as the editor holds it. `closedOn` is required exactly
  /// when the account is inactive; `statementDueDay` only on a credit card.
  /// `inPlan` left nil takes the kind's default (`AccountKind.inPlanByDefault`).
  public struct AccountDraft: Sendable, Equatable {
    public var name: String
    public var institution: String?
    public var kind: AccountKind
    public var inPlan: Bool
    public var currency: String
    public var statementDueDay: Int64?
    public var active: Bool
    public var closedOn: CivilDate?
    public var color: String?

    public init(
      name: String, institution: String? = nil, kind: AccountKind, inPlan: Bool? = nil, currency: String = "AED",
      statementDueDay: Int64? = nil, active: Bool = true, closedOn: CivilDate? = nil, color: String? = nil
    ) {
      self.name = name
      self.institution = institution
      self.kind = kind
      self.inPlan = inPlan ?? kind.inPlanByDefault
      self.currency = currency
      self.statementDueDay = statementDueDay
      self.active = active
      self.closedOn = closedOn
      self.color = color
    }
  }

  /// `account_set` (03b §4.2): the whole record, last write by position wins.
  public mutating func setAccount(id: String, _ d: AccountDraft) throws(AuthorError) {
    if d.active == (d.closedOn != nil) { throw .refused("a closed account needs its closing date, an open one none") }
    if d.statementDueDay != nil && d.kind != .creditCard { throw .refused("only a credit card has a statement day") }
    let name = label(d.name, "name")
    add(
      .accountSet,
      [
        ("id", .string(id)), ("name", .string(name)), ("institution", d.institution.map(JSONValue.string) ?? .null),
        ("kind", .string(d.kind.rawValue)), ("in_plan", .bool(d.inPlan)), ("currency", .string(d.currency)),
        ("statement_due_day", d.statementDueDay.map { .number(JSONNumber($0)) } ?? .null), ("active", .bool(d.active)),
        ("closed_on", d.closedOn.map { .string($0.wire) } ?? .null), ("color", d.color.map(JSONValue.string) ?? .null),
      ])
  }

  public enum CardLinkState: Sendable, Equatable {
    /// The card is this person's, paid from `account`.
    case mine(account: String)
    case notMine
    /// Drop the link (the card is unknown again).
    case forget
  }

  /// `card_linked {bank, last4, state, account}` (03b §4.3).
  public mutating func linkCard(bank: String?, last4: String, _ state: CardLinkState) {
    var p: [(String, JSONValue)] = [("bank", bank.map(JSONValue.string) ?? .null), ("last4", .string(last4))]
    switch state {
    case .mine(let account):
      p.append(("state", .string("mine")))
      p.append(("account", .string(account)))
    case .notMine:
      p.append(("state", .string("not_mine")))
    case .forget:
      p.append(("state", .string("forget")))
    }
    add(.cardLinked, p)
  }

  // MARK: Bills (03b §3.2-§3.3)

  public enum AmountMode: Sendable, Equatable {
    /// A fixed amount; a charge within `toleranceBp` basis points matches.
    case fixed(toleranceBp: Int64)
    /// A varying amount (the estimate is derived from history).
    case variable
  }

  public enum BillStatus: String, Sendable, Equatable { case active, cancelled, dismissed }
  public enum BillSource: String, Sendable, Equatable { case manual, detected }
  public enum CadenceUnit: String, Sendable, Equatable { case day, week, month, year }

  /// A bill as the editor holds it (03b §3.2). `end` is required when cancelled.
  public struct BillDraft: Sendable, Equatable {
    public var name: String
    /// 1-8 merchant keys the matcher compares (`Canon.merchantKey` form).
    public var keys: [String]
    public var direction: String
    public var currency: String
    public var mode: AmountMode
    public var amountMinor: Int64
    public var cadenceUnit: CadenceUnit
    public var cadenceEvery: Int64
    public var anchor: CivilDate
    public var start: CivilDate
    public var end: CivilDate?
    public var category: String?
    public var account: String?
    public var source: BillSource
    public var status: BillStatus

    public init(
      name: String, keys: [String], direction: String = "debit", currency: String = "AED", mode: AmountMode,
      amountMinor: Int64, cadenceUnit: CadenceUnit = .month, cadenceEvery: Int64 = 1, anchor: CivilDate, start: CivilDate,
      end: CivilDate? = nil, category: String? = nil, account: String? = nil, source: BillSource = .manual,
      status: BillStatus = .active
    ) {
      self.name = name
      self.keys = keys
      self.direction = direction
      self.currency = currency
      self.mode = mode
      self.amountMinor = amountMinor
      self.cadenceUnit = cadenceUnit
      self.cadenceEvery = cadenceEvery
      self.anchor = anchor
      self.start = start
      self.end = end
      self.category = category
      self.account = account
      self.source = source
      self.status = status
    }
  }

  /// `bill_set`: create (`parentVersion` nil) or whole-record edit of bill `id`.
  public mutating func setBill(id: String, parentVersion: Int64? = nil, _ d: BillDraft) throws(AuthorError) {
    guard d.amountMinor > 0 else { throw .refused("the amount must be more than 0") }
    if let e = d.end, !(d.start < e) { throw .refused("the end date must be after the start date") }
    if d.status == .cancelled && d.end == nil { throw .refused("a cancelled bill needs an end date") }
    let name = label(d.name, "name")
    let tolerance: JSONValue
    let mode: String
    switch d.mode {
    case .fixed(let bp):
      mode = "fixed"
      tolerance = .number(JSONNumber(bp))
    case .variable:
      mode = "variable"
      tolerance = .null
    }
    add(
      .billSet, entity: ("bill", id), parent: parentVersion,
      [
        ("name", .string(name)), ("keys", .array(d.keys.map(JSONValue.string))), ("direction", .string(d.direction)),
        ("currency", .string(d.currency)), ("amount_mode", .string(mode)), ("amount_minor", .string(String(d.amountMinor))),
        ("tolerance_bp", tolerance),
        (
          "cadence",
          .object(JSONObject([("unit", .string(d.cadenceUnit.rawValue)), ("every", .number(JSONNumber(d.cadenceEvery)))]))
        ),
        ("anchor", .string(d.anchor.wire)), ("start", .string(d.start.wire)), ("end", d.end.map { .string($0.wire) } ?? .null),
        ("category", d.category.map(JSONValue.string) ?? .null), ("account", d.account.map(JSONValue.string) ?? .null),
        ("source", .string(d.source.rawValue)), ("status", .string(d.status.rawValue)),
      ])
  }

  public enum OccurrenceResolution: Sendable, Equatable {
    /// Paid, optionally by a transaction (a `TxnRef`: the txn's entity id).
    case paid(txn: String?)
    case skipped
    /// Not expected before `until`.
    case snoozed(until: CivilDate)
    /// Back to what the matcher decides.
    case clear
  }

  /// `bill_occurrence_set {bill, due, resolution, txn, until}` (03b §3.3).
  public mutating func setBillOccurrence(bill: String, due: CivilDate, _ r: OccurrenceResolution) {
    var resolution = ""
    var txn: JSONValue = .null
    var until: JSONValue = .null
    switch r {
    case .paid(let t):
      resolution = "paid"
      txn = t.map(JSONValue.string) ?? .null
    case .skipped: resolution = "skipped"
    case .snoozed(let u):
      resolution = "snoozed"
      until = .string(u.wire)
    case .clear: resolution = "clear"
    }
    add(
      .billOccurrenceSet,
      [("bill", .string(bill)), ("due", .string(due.wire)), ("resolution", .string(resolution)), ("txn", txn), ("until", until)])
  }

  // MARK: Check-ins (03b §4.4)

  public enum CheckinSource: String, Sendable, Equatable {
    /// A check-in against the derived balance (may carry a resolution).
    case checkin
    /// A plain balance update (tracking accounts).
    case update
  }

  public enum CheckinResolution: Sendable, Equatable {
    case addTxn
    /// The difference was booked as an adjustment (non-zero, signed minor units).
    case adjusted(Int64)
    case kept
  }

  /// `account_checkin`: the balance of `account` at `asOfMs`. Returns the check-in id
  /// (minted when `id` is nil; pass an existing id to void or correct it).
  @discardableResult
  public mutating func checkIn(
    id: String? = nil, account: String, asOfMs: Int64, balanceMinor: Int64, source: CheckinSource = .checkin,
    resolution: CheckinResolution? = nil, void: Bool = false
  ) throws(AuthorError) -> String {
    if resolution != nil && source == .update { throw .refused("an update carries no resolution") }
    if case .adjusted(let v)? = resolution, v == 0 { throw .refused("an adjustment cannot be zero") }
    guard let asOf = Instant.iso(asOfMs) else { throw .refused("date out of range") }
    let cid: String
    if let id { cid = id } else { cid = try newCheckinID() }
    var p: [(String, JSONValue)] = [
      ("id", .string(cid)), ("account", .string(account)), ("as_of", .string(asOf)),
      ("balance_minor", .string(String(balanceMinor))), ("source", .string(source.rawValue)),
    ]
    switch resolution {
    case .addTxn?: p.append(("resolution", .string("add_txn")))
    case .adjusted(let v)?:
      p.append(("resolution", .string("adjusted")))
      p.append(("adjustment_minor", .string(String(v))))
    case .kept?: p.append(("resolution", .string("kept")))
    case nil: break
    }
    p.append(("void", .bool(void)))
    add(.accountCheckin, p)
    return cid
  }
}
