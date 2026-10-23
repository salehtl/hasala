public struct ReviewTabRow: Sendable, Hashable, Identifiable {
  public enum Tone: Sendable, Hashable { case suggestion, decide, reason }

  public var id: TxnID
  public var identifier: String
  public var monogram: String
  public var title: String
  public var subtitle: String
  public var tone: Tone
  public var amount: MoneyPhrase
  public var isIncome: Bool
  public var detail: String
  public var spokenAmount: MoneyPhrase
  public var spokenDetail: String
  public var reason: TxnReviewReason? = nil

  public func spoken(hidden: Bool) -> String {
    [title, spokenDetail, spokenAmount.spoken(hidden: hidden), subtitle]
      .filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

extension ReviewEngine {
  public static func tabRow(_ c: ReviewCardModel, _ s: LedgerState) -> ReviewTabRow {
    let tone: ReviewTabRow.Tone = c.reviewReason != nil ? .reason : c.suggestion == nil ? .decide : .suggestion
    let date = s.txn(c.id)?.postedAt.date
    return ReviewTabRow(
      id: c.id, identifier: "review.tab.row.\(c.id)", monogram: c.monogram, title: c.merchant,
      subtitle: rowSupporting(c), tone: tone, amount: MoneyPhrase([.amount(c.amount)]), isIncome: c.isIncome,
      detail: date?.short ?? "", spokenAmount: MoneyPhrase([.text("\(c.amount.currency) "), .amount(c.amount)]),
      spokenDetail: c.spokenWhen, reason: c.reviewReason)
  }

  public static func rowSupporting(_ c: ReviewCardModel) -> String {
    if let reason = c.reviewReason { return "\(reason.label) · you decide" }
    if let s = c.suggestion { return "Looks like \(s.name)" }
    if c.isIncome { return "Income or a transfer?" }
    return c.isNewMerchant ? "New merchant · you decide" : "You decide"
  }
}
