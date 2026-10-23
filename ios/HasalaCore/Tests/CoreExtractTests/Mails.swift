import CoreExtract

enum Mails {
  static func input(_ sender: String = "alerts.example", subject: String, _ lines: [String], at: Int64 = 1_800_000_000_000, unsubscribe: Bool = false)
    -> ExtractInput
  {
    ExtractInput(sender: sender, subject: subject, text: lines.joined(separator: "\n"), receivedAtMs: at, listUnsubscribe: unsubscribe)
  }

  static func cardPurchaseAR(amount: String, merchant: String, at: Int64 = 1_800_000_000_000) -> ExtractInput {
    input(
      "bank-a.example", subject: "Bank A Notification",
      [
        "معاملة بطاقة ائتمان", "عزيزي المتعامل,", "إشعار مشتريات بتاريخ 01-02-2030 10:15 بالتفاصيل التالية.", "المبلغ",
        "AED \(amount)", "رقم البطاقة", "XXXX4821", "الدفع الى", merchant, "إجمالي الرصيد المتوفر", "AED 9,876.00",
        "مع اطيب التحيات،", "بنك أ",
      ], at: at)
  }

  static func cardPurchaseEN(amount: String, merchant: String, at: Int64 = 1_800_000_000_000) -> ExtractInput {
    input(
      "bank-b.example", subject: "Card transaction alert",
      [
        "Dear Customer,", "Your credit card ending with 7310 was used for a purchase.", "Amount", "AED \(amount)", "Merchant",
        merchant, "Available limit", "AED 12,000.00", "Regards,", "Bank B",
      ], at: at)
  }

  static func transferAR(amount: String, status: String, at: Int64 = 1_800_000_000_000) -> ExtractInput {
    input(
      "bank-a.example", subject: "Bank A Notification",
      [
        "تحويل الأموال", "عزيزي المتعامل,", "إشعار تحويل الأموال الى بنك آخر داخل الدولة بتاريخ 03-02-2030 09:00 بالتفاصيل التالية.",
        "المبلغ", "(يشمل 5% ضريبة القيمة المضافة)", "AED \(amount)", "من حساب", "001-222-333XXXX44", "الى",
        "AE000000000000000000001", "البنك المستفيد", "bank c", "الحالة", status, "مع اطيب التحيات،", "بنك أ",
      ], at: at)
  }

  static func accountDebitAR(amount: String, at: Int64 = 1_800_000_000_000) -> ExtractInput {
    input(
      "bank-a.example", subject: "Bank A Notification",
      [
        "إشعار خصم", "عزيزي المتعامل,", "خصم من الحساب بتاريخ 03-02-2030 09:01", "المبلغ", "AED \(amount)", "من حساب",
        "001-222-333XXXX44", "المعاملة", "FUND TRANSFER OUT", "الحالة", "تمت بنجاح", "مع اطيب التحيات،", "بنك أ",
      ], at: at)
  }
}
