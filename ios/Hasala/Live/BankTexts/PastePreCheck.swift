import Foundation
import HasalaModels

enum PastePreCheck {
  static let dayMs: Int64 = 86_400_000
  static let paymentWindowMs: Int64 = dayMs
  static let undatedWindowMs: Int64 = 7 * dayMs
  static let unparsedWindowMs: Int64 = 10 * 60_000

  static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }

  static func range(_ f: BankTextFields, pastedAt: Date) -> (from: Date, through: Date) {
    let anchor = f.postedAt ?? pastedAt
    let from = min(anchor, pastedAt).addingTimeInterval(-Double(undatedWindowMs + dayMs) / 1000)
    let through = max(anchor, pastedAt).addingTimeInterval(Double(dayMs) / 1000)
    return (from, through)
  }

  static func sameBank(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return true }
    return a.lowercased() == b.lowercased()
  }

  static func sameCard(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return true }
    return a == b
  }

  static func payment(_ f: BankTextFields, pastedAt: Date, row: BankTextRow) -> Bool {
    guard !row.unparsed, let amount = f.amount, let rowAmount = row.amount, rowAmount == amount,
      row.direction == (f.direction ?? .out), sameBank(f.bank, row.bank), sameCard(f.cardEnding, row.cardEnding)
    else { return false }
    let rowMs = ms(row.postedAt)
    if let posted = f.postedAt { return abs(rowMs - ms(posted)) <= paymentWindowMs }
    let pasteMs = ms(pastedAt)
    return rowMs <= pasteMs && pasteMs - rowMs <= undatedWindowMs
  }

  static func unreadText(_ f: BankTextFields, pastedAt: Date, row: BankTextRow) -> Bool {
    guard row.unparsed, row.fromText, f.amount != nil, let bank = f.bank, let rowBank = row.bank,
      bank.lowercased() == rowBank.lowercased(), sameCard(f.cardEnding, row.cardEnding)
    else { return false }
    let rowMs = ms(row.postedAt)
    if let posted = f.postedAt { return abs(rowMs - ms(posted)) <= unparsedWindowMs }
    let pasteMs = ms(pastedAt)
    return rowMs <= pasteMs && pasteMs - rowMs <= undatedWindowMs
  }

  static func match(_ f: BankTextFields, pastedAt: Date, rows: [BankTextRow]) -> BankTextMatch? {
    let anchor = ms(f.postedAt ?? pastedAt)
    let nearest: ([BankTextRow]) -> BankTextRow? = { rows in
      rows.min { abs(ms($0.postedAt) - anchor) < abs(ms($1.postedAt) - anchor) }
    }
    if let row = nearest(rows.filter { payment(f, pastedAt: pastedAt, row: $0) }) {
      return BankTextMatch(
        rowID: row.id, kind: .payment, merchant: row.merchant, amount: row.amount, postedAt: row.postedAt,
        fromText: row.fromText)
    }
    if let row = nearest(rows.filter { unreadText(f, pastedAt: pastedAt, row: $0) }) {
      return BankTextMatch(
        rowID: row.id, kind: .unreadText, merchant: row.merchant, amount: nil, postedAt: row.postedAt, fromText: true)
    }
    return nil
  }
}
