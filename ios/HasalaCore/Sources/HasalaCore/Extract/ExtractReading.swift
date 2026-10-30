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

public enum ExtractPending: String, Sendable, Equatable {
  case none
  case phrase
  case status
}

public struct ExtractStatedDate: Sendable, Equatable {
  public var year: Int
  public var month: Int
  public var day: Int
  public var minuteOfDay: Int?

  public init(year: Int, month: Int, day: Int, minuteOfDay: Int? = nil) {
    self.year = year
    self.month = month
    self.day = day
    self.minuteOfDay = minuteOfDay
  }
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

  var isCard: Bool { self == .cardPurchase || self == .cardRefund }
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
  public var rulesConfidencePercent: Int
  public var learnedConfidencePercent: Int
  public var readersAgree: Bool
  public var aedFromOverride: Bool
  public var directionAmbiguous = false
  public var aedOverrideUsed = false
  public var pendingWordingHeld = false

  public init(
    outcome: ExtractOutcome, amountMinor: Int64? = nil, currency: String? = nil, direction: ExtractDirection? = nil,
    merchant: String? = nil, last4: String? = nil, kind: ExtractMailKind = .other, confidencePercent: Int = 0,
    agreed: Bool = false, notes: [String] = [], rulesConfidencePercent: Int = 0, learnedConfidencePercent: Int = 0,
    readersAgree: Bool = false, aedFromOverride: Bool = false
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
    self.rulesConfidencePercent = rulesConfidencePercent
    self.learnedConfidencePercent = learnedConfidencePercent
    self.readersAgree = readersAgree
    self.aedFromOverride = aedFromOverride
  }

  public var meetsAgreementBar: Bool {
    outcome == .transaction && agreed && amountMinor != nil && currency != nil
      && confidencePercent >= Self.agreementBarPercent
  }

  public var readersConfirm: Bool {
    outcome == .transaction && agreed && readersAgree && amountMinor != nil && currency != nil && direction != nil
      && rulesConfidencePercent >= Self.agreementBarPercent && learnedConfidencePercent >= Self.agreementBarPercent
  }

  public var meetsFilingBar: Bool {
    meetsAgreementBar && readersConfirm && !directionAmbiguous && !aedOverrideUsed && !pendingWordingHeld
  }

  public static let maxAmountMinor: Int64 = 9_999_999_999_999

  public static func usableAmount(_ amountMinor: Int64, currency: String) -> Bool {
    amountMinor > 0 && amountMinor <= maxAmountMinor && currency.utf8.count == 3
      && currency.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5a }
  }

  public var isUsable: Bool {
    guard let amountMinor, let currency, direction != nil else { return false }
    return Self.usableAmount(amountMinor, currency: currency)
  }
}

public enum ExtractHold: String, Sendable, Equatable {
  case aedNotConfirmed = "aed_not_confirmed"
  case pendingPhrase = "pending_phrase"
  case pendingStatus = "pending_status"
  case readersDisagree = "readers_disagree"
  case currencyNotISO = "currency_not_iso"
}

public struct ExtractTemplateVerdict: Sendable, Equatable {
  public var amountMinor: Int64
  public var currency: String
  public var aedOver: String?
  public var holds: [ExtractHold]

  public init(amountMinor: Int64, currency: String, aedOver: String? = nil, holds: [ExtractHold] = []) {
    self.amountMinor = amountMinor
    self.currency = currency
    self.aedOver = aedOver
    self.holds = holds
  }

  public var held: Bool { !holds.isEmpty }
}

struct Reading: Equatable {
  var isTransaction = false
  var amountMinor: Int64?
  var currency: String?
  var currencyExplicit = false
  var merchant: String?
  var direction: String?
  var directionGuessed = false
  var directionAmbiguous = false
  var fromLayout = false
  var confidence = 0
  var note = ""
  var negative = false
  var merchantTrimmed = false
  var aedOverride = false

  static let none = Reading()
}
