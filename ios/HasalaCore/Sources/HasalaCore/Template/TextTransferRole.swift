public enum TextTransferRole: String, Sendable, Equatable, CaseIterable {
  case notice
  case alert

  public static let byTemplate: [String: TextTransferRole] = [
    "dib.sms.own-transfer.v1": .notice,
    "dib.sms.debit.v1": .alert,
  ]

  public static let withoutRole: Set<String> = [
    "dib.sms.card-payment.v1", "dib.sms.credit.v1", "dib.sms.purchase.v1", "dib.sms.refund.v1", "dib.sms.reversal.v1",
    "dib.sms.salary.v1",
  ]

  public static func of(templateRef ref: String) -> TextTransferRole? {
    byTemplate[String(ref.prefix { $0 != "@" })]
  }

  public var counterpart: TextTransferRole { self == .notice ? .alert : .notice }
}
