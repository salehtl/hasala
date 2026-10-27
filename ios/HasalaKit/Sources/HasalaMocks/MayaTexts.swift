import HasalaModels

public enum MayaTexts {
  static func text(_ time: String, _ raw: String) -> Provenance {
    Provenance(
      title: "Bank text from \(MayaLedger.dib)", readAt: "Received \(time) · read automatically", rawMerchant: raw, isText: true)
  }

  public static func apply(to s: inout LedgerState) {
    s.txns += [
      Txn(
        id: "text-debit", merchant: "Outgoing Fund Transfer", amount: .aed(4_321_09), postedAt: MayaLedger.oct(10, 12, 31),
        accountID: "dib", categoryID: "transfer", categorySource: .user, isTransfer: true,
        provenance: text("12:31", "OUTGOING DOMESTIC FUND TR")),
      Txn(
        id: "text-transfer", merchant: "MB Fund Transfer", amount: .aed(4_321_09), postedAt: MayaLedger.oct(10, 12, 40),
        accountID: "dib", needsReview: true, provenance: text("12:40", "MB FUND TRANSFER"),
        mayRepeat: MayRepeat(of: "text-debit", line: "This may be the same transfer as the bank text from DIB at 12:31.")),
      Txn(
        id: "text-grocer", merchant: "Sample Grocer", amount: .aed(120_00), postedAt: MayaLedger.oct(9, 10, 12),
        accountID: "dib", categoryID: "groceries", categorySource: .user, provenance: text("10:12", "SAMPLE GROCER")),
      Txn(
        id: "mail-twin", merchant: "Sample Grocer", amount: .aed(120_00), postedAt: MayaLedger.oct(9, 10, 15),
        accountID: "dib", needsReview: true, provenance: MayaLedger.alert(MayaLedger.dib, "10:15", "SAMPLE GROCER LLC"),
        mayRepeat: MayRepeat(of: "text-grocer", line: "This may be the same payment as a bank text from DIB on 9 October.")),
    ]
    s.unreadTexts = [
      UnreadText(id: "unread-text-dib", bank: MayaLedger.dib, receivedAt: MayaLedger.oct(10, 9, 58), accountID: "dib"),
      UnreadText(id: "unread-text-other", bank: nil, receivedAt: MayaLedger.oct(8, 19, 12)),
    ]
  }
}
