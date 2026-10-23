public struct ExtractInput: Sendable, Equatable {
  public var sender: String
  public var subject: String
  public var text: String
  public var receivedAtMs: Int64
  public var listUnsubscribe: Bool

  public init(sender: String, subject: String, text: String, receivedAtMs: Int64, listUnsubscribe: Bool) {
    self.sender = sender
    self.subject = subject
    self.text = text
    self.receivedAtMs = receivedAtMs
    self.listUnsubscribe = listUnsubscribe
  }
}

public enum ExtractOutcome: String, Sendable, Codable, CaseIterable {
  case transaction
  case pending
  case notTransaction = "not_transaction"
  case unknown
}

public enum ExtractDirection: String, Sendable, Codable, CaseIterable {
  case debit
  case credit
}

public enum ExtractMailKind: String, Sendable, Codable, CaseIterable {
  case cardPurchase = "card_purchase"
  case cardRefund = "card_refund"
  case transferNotice = "transfer_notice"
  case accountDebitAlert = "account_debit_alert"
  case accountCreditAlert = "account_credit_alert"
  case other
}

public struct ExtractReading: Sendable, Equatable {
  public static let agreementBarPercent = 80

  public var outcome: ExtractOutcome
  public var amountMinor: Int64?
  public var currency: String?
  public var direction: ExtractDirection?
  public var merchant: String?
  public var last4: String?
  public var kind: ExtractMailKind
  public var confidencePercent: Int
  public var agreed: Bool
  public var notes: [String]

  public init(
    outcome: ExtractOutcome, amountMinor: Int64? = nil, currency: String? = nil, direction: ExtractDirection? = nil,
    merchant: String? = nil, last4: String? = nil, kind: ExtractMailKind = .other, confidencePercent: Int = 0,
    agreed: Bool = false, notes: [String] = []
  ) {
    self.outcome = outcome
    self.amountMinor = amountMinor
    self.currency = currency
    self.direction = direction
    self.merchant = merchant
    self.last4 = last4
    self.kind = kind
    self.confidencePercent = confidencePercent
    self.agreed = agreed
    self.notes = notes
  }

  public var meetsAgreementBar: Bool {
    outcome == .transaction && agreed && amountMinor != nil && currency != nil
      && confidencePercent >= Self.agreementBarPercent
  }
}

struct Reading: Equatable {
  var isTransaction = false
  var amountMinor: Int64?
  var currency: String?
  var merchant: String?
  var direction: String?
  var confidence = 0
  var note = ""
  var negative = false

  static let none = Reading()
}
