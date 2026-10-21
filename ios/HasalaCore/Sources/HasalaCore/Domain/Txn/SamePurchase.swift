import CoreJSON
import CoreMoney
import CoreReplay
import HasalaText

public enum SamePurchase {
  public static let windowMs: Int64 = 7 * 86_400_000
  public static let estimatePercent: Int64 = 5
  public static let statedPercent: Int64 = 1

  public struct Row: Sendable, Equatable {
    public var id: String
    public var live: Bool
    public var unparsed: Bool
    public var archived: Bool
    public var manual: Bool
    public var amountMinor: Int64
    public var currency: String
    public var amountHomeMinor: Int64?
    public var homeStated: Bool
    public var direction: String
    public var bank: String?
    public var last4: String
    public var postedMs: Int64
    public var merchantKey: String
    public var possibleDuplicateOf: String?
    public var duplicateDisposition: String?
    public var heldCopy: Bool

    public init(
      id: String, live: Bool = true, unparsed: Bool = false, archived: Bool = false, manual: Bool = false, amountMinor: Int64,
      currency: String, amountHomeMinor: Int64?, homeStated: Bool = false, direction: String, bank: String?, last4: String,
      postedMs: Int64, merchantKey: String, possibleDuplicateOf: String? = nil, duplicateDisposition: String? = nil,
      heldCopy: Bool = false
    ) {
      self.id = id
      self.live = live
      self.unparsed = unparsed
      self.archived = archived
      self.manual = manual
      self.amountMinor = amountMinor
      self.currency = currency
      self.amountHomeMinor = amountHomeMinor
      self.homeStated = homeStated
      self.direction = direction
      self.bank = bank
      self.last4 = last4
      self.postedMs = postedMs
      self.merchantKey = merchantKey
      self.possibleDuplicateOf = possibleDuplicateOf
      self.duplicateDisposition = duplicateDisposition
      self.heldCopy = heldCopy
    }
  }

  public struct Pair: Sendable, Equatable {
    public var foreign: String
    public var home: String
    public var merchantMissing: Bool

    public init(foreign: String, home: String, merchantMissing: Bool) {
      self.foreign = foreign
      self.home = home
      self.merchantMissing = merchantMissing
    }
  }

  public static func isForeign(_ f: Row, home: String) -> Bool {
    f.live && !f.unparsed && !f.archived && !f.heldCopy && !utf8Equal(f.currency, home) && (f.amountHomeMinor ?? 0) > 0
  }

  public static func isPosting(_ a: Row, home: String) -> Bool {
    a.live && !a.unparsed && !a.archived && !a.manual && !a.heldCopy && utf8Equal(a.currency, home)
      && a.possibleDuplicateOf == nil
  }

  public static func declined(_ f: Row, _ a: Row) -> Bool {
    a.possibleDuplicateOf.map { utf8Equal($0, f.id) } == true && a.duplicateDisposition == "different"
  }

  public static func qualifies(_ f: Row, _ a: Row, home: String) -> Bool {
    guard isForeign(f, home: home), isPosting(a, home: home), !declined(f, a), let estimate = f.amountHomeMinor else {
      return false
    }
    guard utf8Equal(f.direction, a.direction), let fb = f.bank, let ab = a.bank, utf8Equal(fb, ab) else { return false }
    guard !f.last4.isEmpty, utf8Equal(f.last4, a.last4) else { return false }
    guard a.postedMs >= f.postedMs, a.postedMs - f.postedMs <= windowMs else { return false }
    guard within(a.amountMinor, of: estimate, percent: f.homeStated ? statedPercent : estimatePercent) else { return false }
    return merchantsAgree(f.merchantKey, a.merchantKey)
  }

  public static func within(_ amount: Int64, of target: Int64, percent: Int64) -> Bool {
    let diff: Int128 = Int128(amount) - Int128(target)
    let gap: Int128 = 100 * (diff < 0 ? -diff : diff)
    let allowed: Int128 = Int128(percent) * Int128(target)
    return gap <= allowed
  }

  public static func merchantsAgree(_ x: String, _ y: String) -> Bool {
    if x.isEmpty || y.isEmpty { return true }
    return x.utf8.starts(with: y.utf8) || y.utf8.starts(with: x.utf8)
  }

  public static func pairs(_ rows: [Row], home: String) -> [Pair] {
    let foreign = rows.filter { isForeign($0, home: home) }
    let postings = rows.filter { isPosting($0, home: home) }
    var candidates: [(f: Row, a: Row)] = []
    for f in foreign {
      for a in postings where qualifies(f, a, home: home) { candidates.append((f, a)) }
    }
    candidates.sort { closer($0.f, $0.a, than: $1.f, $1.a) }
    var usedF = Set<String>()
    var usedA = Set<String>()
    var out: [Pair] = []
    for (f, a) in candidates where !usedF.contains(f.id) && !usedA.contains(a.id) {
      usedF.insert(f.id)
      usedA.insert(a.id)
      out.append(Pair(foreign: f.id, home: a.id, merchantMissing: f.merchantKey.isEmpty || a.merchantKey.isEmpty))
    }
    return out
  }

  static func closer(_ f1: Row, _ a1: Row, than f2: Row, _ a2: Row) -> Bool {
    let h1 = Int128(f1.amountHomeMinor ?? 0), h2 = Int128(f2.amountHomeMinor ?? 0)
    let d1 = Int128(a1.amountMinor) - h1, d2 = Int128(a2.amountMinor) - h2
    let l = Int128(d1.magnitude) * h2, r = Int128(d2.magnitude) * h1
    if l != r { return l < r }
    let t1 = a1.postedMs - f1.postedMs, t2 = a2.postedMs - f2.postedMs
    if t1 != t2 { return t1 < t2 }
    if !utf8Equal(f1.id, f2.id) { return utf8Less(f1.id, f2.id) }
    return utf8Less(a1.id, a2.id)
  }

  static func utf8Less(_ x: String, _ y: String) -> Bool { x.utf8.lexicographicallyPrecedes(y.utf8) }

  public static func note(foreignMinor: Int64, currency: String) -> String {
    "Settled the \(MoneyFormat.formatMoney(foreignMinor, currency: currency)) purchase"
  }
}

extension OpAuthor {
  public mutating func confirmSamePurchase(
    foreignID: String, foreignVersion: Int64, homeID: String, homeAmountMinor: Int64, foreignMinor: Int64, foreignCurrency: String
  ) {
    add(.txnEdited, entity: ("txn", foreignID), parent: foreignVersion, [("amount_home_minor", .string(String(homeAmountMinor)))])
    annotate(
      txnID: homeID,
      set: [("archived", "user"), ("note", SamePurchase.note(foreignMinor: foreignMinor, currency: foreignCurrency))])
  }

  public mutating func undoSamePurchase(
    foreignID: String, foreignVersion: Int64, previousHomeMinor: Int64?, homeID: String, previousNote: String?,
    refreeze: (currency: String, micro: Int64)? = nil
  ) {
    let home: JSONValue = refreeze == nil ? previousHomeMinor.map { .string(String($0)) } ?? .null : .null
    add(.txnEdited, entity: ("txn", foreignID), parent: foreignVersion, [("amount_home_minor", home)])
    if let r = refreeze, r.micro > 0 {
      add(.rateSet, [("currency", .string(r.currency)), ("rate_micro", .string(String(r.micro)))])
    }
    annotate(txnID: homeID, set: [("archived", nil), ("note", previousNote.flatMap { $0.isEmpty ? nil : $0 })])
  }

  public mutating func declineSamePurchase(homeID: String, homeVersion: Int64, foreignID: String) {
    add(.txnEdited, entity: ("txn", homeID), parent: homeVersion, [("possible_duplicate_of", .string(foreignID))])
    resolveDuplicate(txnID: homeID, parentVersion: homeVersion + 1, otherTxnID: foreignID, disposition: .different)
  }

  public mutating func undoDeclineSamePurchase(homeID: String, homeVersion: Int64) {
    add(.txnEdited, entity: ("txn", homeID), parent: homeVersion, [("possible_duplicate_of", .null)])
  }
}
