public enum ENBDTexts {
  public static let wholeBody: [DIBTexts.Wording] = [
    DIBTexts.Wording(
      kind: .declined, wording: "Transaction of {ccy} {amount} on your Card ending {card} could not be completed. For Details, Please call {n}"),

    DIBTexts.Wording(kind: .notice, wording: "{ccy} {amount} has been withdrawn successfully from your {ccy} Global Equities {any}"),
    DIBTexts.Wording(
      kind: .notice,
      wording:
        "Dear {any}, You have set up a Standing Instruction through {any} from your Account {any} with amount of {ccy} {any}. Your Reference number is {n}"
    ),
    DIBTexts.Wording(
      kind: .notice,
      wording: "Dear {any}, your card ending {card} has been disabled from Apple Pay. If you did not initiate this transaction, please call {any}"),
    DIBTexts.Wording(
      kind: .notice,
      wording:
        "{n} cheque(s) has been deposited to your account {any} through the deposit machine. Deposit to be confirmed after successful cheque clearing"
    ),
    DIBTexts.Wording(
      kind: .notice, wording: "Your account number {any} will become {any}. Kindly initiate a debit transaction to avoid any inconvenience"),
    DIBTexts.Wording(kind: .notice, wording: "Dear {any}, from {any}, SMS alerts will be replaced by push notification on {any}"),

    DIBTexts.Wording(
      kind: .promotion,
      wording:
        "*Convert now* Pay as low as {ccy} {amount} per month for the purchase of {ccy} {amount} at {any} with credit card ending {card} via clicking {any}"
    ),
  ]
}
