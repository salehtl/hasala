import Foundation

enum HeldOut {
  static let rewordEn: [(String, String)] = [
    ("Amount", "Figure"),
    ("Debit Amount", "Outflow"),
    ("Credit Amount", "Inflow"),
    ("Merchant", "Store"),
    ("Paid to", "Store"),
    ("Transaction Date", "When"),
    ("Date", "When"),
    ("Card Number", "Card used"),
    ("From Account", "Source"),
    ("Beneficiary Name", "Recipient"),
    ("Beneficiary Bank", "Recipient institution"),
    ("Status", "Result"),
    ("Reference Number", "Tracking ID"),
    ("Description", "Memo"),
    ("Details", "Info"),
  ]

  static let rewordEnPhrases: [(String, String)] = [
    ("has been debited", "left your account"),
    ("was debited", "left your account"),
    ("debited from", "taken from"),
    ("has been withdrawn", "came out"),
    ("has been credited", "landed"),
    ("was credited", "landed"),
    ("has been reversed", "is undone"),
    ("Transaction of", "A spend of"),
    ("Dear Customer", "Hi there"),
    ("Transaction Alert", "Account Update"),
    ("to the value of", "for"),
  ]

  static let rewordAr: [(String, String)] = [
    ("المبلغ", "المجموع"),
    ("الدفع الى", "المحل"),
    ("المعاملة", "البند"),
    ("الحالة", "النتيجة"),
    ("الرقم المرجعي", "رقم التتبع"),
  ]

  static let rewordArPhrases: [(String, String)] = [
    ("عزيزي المتعامل", "أهلا بك"),
    ("بالتفاصيل التالية", "كما يلي"),
  ]

  static let promoEn = [
    "Enjoy 10% back on dining, capped at AED {n} each month.",
    "Spend AED {n} this weekend and get a gift card on us.",
    "Book your next trip and we'll knock AED {n} off the fare.",
  ]

  static let promoAr = [
    "استمتع باسترجاع 10% على المطاعم بحد أقصى {n} درهم شهريا.",
    "أنفق {n} درهم هذا الأسبوع ونهديك بطاقة هدية.",
  ]
}
