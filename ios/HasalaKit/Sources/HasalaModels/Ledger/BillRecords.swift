extension BillCadence {
  public var maxEvery: Int {
    switch self {
    case .weekly: 52
    case .monthly: 24
    case .yearly: 10
    }
  }
}

public struct BillPayment: Sendable, Hashable, Codable {
  public enum Link: String, Sendable, Hashable, Codable { case linked, matched, marked }

  public var due: LocalDate
  public var txnID: TxnID?
  public var amount: Money?
  public var link: Link

  public init(due: LocalDate, txnID: TxnID? = nil, amount: Money? = nil, link: Link) {
    self.due = due
    self.txnID = txnID
    self.amount = amount
    self.link = link
  }
}

public struct BillNotice: Sendable, Hashable, Codable, Identifiable {
  public enum Kind: Sendable, Hashable, Codable {
    case priceChange(usual: Money, charged: Money, from: LocalDate)
    case chargedWhilePaused(charged: Money, on: LocalDate)
    case chargedAfterEnd(charged: Money, on: LocalDate)
    case changedOnTwoDevices(summary: String)
  }

  public var id: String
  public var kind: Kind
  public var txnID: TxnID?

  public init(id: String, kind: Kind, txnID: TxnID? = nil) {
    self.id = id
    self.kind = kind
    self.txnID = txnID
  }
}
