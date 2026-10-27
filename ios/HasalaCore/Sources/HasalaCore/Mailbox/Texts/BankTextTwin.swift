import CoreProjection
import CoreTime
import Foundation

public struct TextTwinMail: Sendable, Equatable {
  public var bank: String?
  public var last4: String
  public var amountMinor: Int64
  public var currency: String
  public var direction: String
  public var postedMs: Int64

  public init(bank: String?, last4: String, amountMinor: Int64, currency: String, direction: String, postedMs: Int64) {
    self.bank = bank
    self.last4 = last4
    self.amountMinor = amountMinor
    self.currency = currency
    self.direction = direction
    self.postedMs = postedMs
  }
}

public enum BankTextTwin {
  public static let windowMs: Int64 = 86_400_000

  public static func matches(_ t: BankTextRow, _ m: TextTwinMail) -> Bool {
    guard abs(t.postedMs - m.postedMs) <= windowMs else { return false }
    guard t.unparsed || t.direction == m.direction else { return false }
    let tb = t.bank ?? ""
    guard tb.isEmpty || tb == (m.bank ?? "") else { return false }
    guard t.last4.isEmpty || m.last4.isEmpty || t.last4 == m.last4 else { return false }
    return t.unparsed || t.currency != m.currency || t.amountMinor == m.amountMinor
  }

  public static func twin(of m: TextTwinMail, among rows: some Collection<BankTextRow>) -> BankTextRow? {
    var best: (row: BankTextRow, gap: Int64)?
    for t in rows where matches(t, m) {
      let gap = abs(t.postedMs - m.postedMs)
      if best.map({ gap < $0.gap || (gap == $0.gap && t.id < $0.row.id) }) ?? true { best = (t, gap) }
    }
    return best?.row
  }

  public static func sorted(_ rows: [BankTextRow]) -> [BankTextRow] {
    rows.sorted { $0.postedMs == $1.postedMs ? $0.id < $1.id : $0.postedMs < $1.postedMs }
  }

  public static func window(_ sorted: [BankTextRow], around ms: Int64, _ width: Int64) -> ArraySlice<BankTextRow> {
    func first(_ bound: Int64, after: Bool) -> Int {
      var lo = 0
      var hi = sorted.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if after ? sorted[mid].postedMs <= bound : sorted[mid].postedMs < bound { lo = mid + 1 } else { hi = mid }
      }
      return lo
    }
    let lo = first(ms - width, after: false)
    return sorted[lo..<max(lo, first(ms + width, after: true))]
  }
}

public struct TextOverlap: Sendable, Equatable {
  public let fromMs: Int64
  public let toMs: Int64
  public let rows: [BankTextRow]

  public init(span: TextRowSpan, rows: [BankTextRow]) {
    fromMs = span.oldestPostedMs - BankTextTwin.windowMs
    toMs = span.newestPostedMs + BankTextTwin.windowMs
    self.rows = BankTextTwin.sorted(rows)
  }

  public func covers(_ ms: Int64) -> Bool { ms >= fromMs && ms <= toMs }

  public func twin(of m: ParsedMail) -> BankTextRow? {
    guard let f = m.fields else { return nil }
    let posted = (try? parseInstantMs(f.postedAt)) ?? m.internalDateMs
    guard covers(posted) || covers(m.internalDateMs) else { return nil }
    let mail = TextTwinMail(
      bank: m.bank, last4: f.last4, amountMinor: f.amountMinor, currency: f.currency, direction: f.direction, postedMs: posted)
    return BankTextTwin.twin(of: mail, among: BankTextTwin.window(rows, around: posted, BankTextTwin.windowMs))
  }
}
