import Foundation

enum Lexicon {
  static let labels: [(en: String, ar: String)] = [
    ("Amount", "المبلغ"),
    ("Debit Amount", "مبلغ الخصم"),
    ("Credit Amount", "مبلغ الإيداع"),
    ("Merchant", "التاجر"),
    ("Paid to", "الدفع الى"),
    ("Transaction", "المعاملة"),
    ("Transaction Date", "تاريخ المعاملة"),
    ("Date", "التاريخ"),
    ("Card Number", "رقم البطاقة"),
    ("From", "من"),
    ("From Account", "من حساب"),
    ("To", "الى"),
    ("Status", "الحالة"),
    ("Reference Number", "الرقم المرجعي"),
    ("Beneficiary Name", "اسم المستفيد"),
    ("Beneficiary Bank", "بنك المستفيد"),
    ("Description", "الوصف"),
    ("Available Balance", "الرصيد المتاح"),
    ("Details", "التفاصيل"),
  ]

  static let rewordEn: [(String, String)] = [
    ("Amount", "Transaction amount"),
    ("Debit Amount", "Amount debited"),
    ("Credit Amount", "Amount credited"),
    ("Merchant", "Paid to"),
    ("Paid to", "Merchant"),
    ("Transaction Date", "Date of transaction"),
    ("Date", "On"),
    ("Card Number", "Card no."),
    ("From Account", "Debited account"),
    ("Beneficiary Name", "Payee"),
    ("Beneficiary Bank", "Payee bank"),
    ("Status", "Outcome"),
    ("Reference Number", "Ref no."),
    ("Description", "Narrative"),
    ("Details", "Summary"),
  ]

  static let rewordEnPhrases: [(String, String)] = [
    ("has been debited", "was charged"),
    ("was debited", "was charged"),
    ("debited from", "charged to"),
    ("has been withdrawn", "was taken out"),
    ("has been credited", "was added"),
    ("was credited", "was added"),
    ("has been reversed", "was returned"),
    ("Dear Customer", "Hello valued customer"),
    ("Yours Sincerely", "Kind regards"),
    ("Best Regards", "Warm regards"),
    ("Transaction Alert", "Activity Notification"),
    ("Transaction of", "A payment of"),
    ("Available account balance", "Balance you can use"),
    ("Avl Bal", "Balance now"),
    ("Thank you for banking with", "We appreciate you choosing"),
    ("to the value of", "worth"),
  ]

  static let rewordAr: [(String, String)] = [
    ("المبلغ", "قيمة المعاملة"),
    ("الدفع الى", "المدفوع الى"),
    ("المعاملة", "تفاصيل المعاملة"),
    ("من حساب", "من الحساب رقم"),
    ("رقم البطاقة", "البطاقة رقم"),
    ("الحالة", "حالة العملية"),
    ("الرقم المرجعي", "رقم العملية"),
  ]

  static let rewordArPhrases: [(String, String)] = [
    ("بتاريخ", "في تاريخ"),
    ("عزيزي المتعامل", "عميلنا العزيز"),
    ("مع اطيب التحيات", "وتفضلوا بقبول فائق الاحترام"),
    ("تم إرجاع مبلغ", "تم رد مبلغ"),
    ("إشعار خصم", "تنبيه سحب"),
    ("إشعار إيداع", "تنبيه ايداع"),
    ("إشعار مشتريات", "تنبيه شراء"),
    ("بالتفاصيل التالية", "وفق البيانات التالية"),
    ("الخاصة بك", "العائدة لك"),
  ]

  static let phrases: [(en: String, ar: String)] = [
    ("Debit Transaction Alert", "تنبيه معاملة خصم"),
    ("Purchase Transaction Alert", "تنبيه معاملة شراء"),
    ("Money Transfer", "تحويل الأموال"),
    ("Dear Customer", "عزيزي المتعامل"),
    ("Yours Sincerely", "مع اطيب التحيات"),
    ("Best Regards", "مع أطيب التحيات"),
    ("was debited from your account", "تم خصمه من حسابك"),
    ("has been withdrawn from your account", "تم سحبه من حسابك"),
    ("debited from your a/c", "تم خصمه من حسابك"),
    ("Transaction of", "معاملة بمبلغ"),
    ("Avl Bal is", "الرصيد المتاح هو"),
    ("Your available account balance is", "رصيد حسابك المتاح هو"),
    ("has been reversed", "تم عكسها"),
    ("made at", "تمت في"),
    ("on your DIB card ending with", "على بطاقة بنك دبي الإسلامي المنتهية بالرقم"),
    ("Thank you for banking with", "شكرا لتعاملكم مع"),
    ("Emirates NBD", "بنك الإمارات دبي الوطني"),
    ("Abu Dhabi Islamic Bank", "مصرف أبوظبي الإسلامي"),
    ("Dubai Islamic Bank", "بنك دبي الإسلامي"),
    ("Credited to beneficiary", "تم الإيداع للمستفيد"),
    ("This is to notify you that", "نود إعلامكم بأن"),
    ("has been initiated on", "تم تنفيذه بتاريخ"),
    ("with the following details", "بالتفاصيل التالية"),
    ("a transaction", "معاملة"),
    ("A transaction", "معاملة"),
    ("to the value of", "بقيمة"),
    ("Debit Notice", "إشعار خصم"),
    ("Deposit Notice", "إشعار إيداع"),
    ("Purchase Notice", "إشعار مشتريات"),
    ("Funds Transfer", "تحويل الأموال"),
    ("Refunded amount", "تم إرجاع مبلغ"),
    ("to your card", "على بطاقتك"),
    ("ending with", "المنتهية بالرقم"),
    ("Successful", "تمت بنجاح"),
  ]

  static let arOnlyToEn: [(String, String)] = [
    ("إشعار خصم", "Debit Notice"),
    ("إشعار إيداع", "Deposit Notice"),
    ("إشعار مشتريات", "Purchase Notice"),
    ("تحويل الأموال", "Funds Transfer"),
    ("إشعار تحويل الأموال بين حساباتك بتاريخ", "Notice of transfer between your own accounts on"),
    ("بالتفاصيل التالية", "with the following details"),
    ("من الحساب بتاريخ", "from the account on"),
    ("تمت بنجاح", "Successful"),
    ("عزيزي المتعامل", "Dear Customer"),
    ("مع اطيب التحيات", "Best Regards"),
    ("مع أطيب التحيات", "Best Regards"),
    ("بنك دبي الإسلامي", "Dubai Islamic Bank"),
    ("تم إرجاع مبلغ", "Refunded amount"),
    ("درهم", "AED"),
    ("على بطاقة", "to card"),
    ("الخاصة بك والمنتهية بالرقم", "ending with"),
    ("المنتهية بالرقم", "ending with"),
    ("خصم", "debit"),
    ("إشعار", "Notice"),
    ("بتاريخ", "on"),
    ("حساب جاري", "Current account"),
  ]

  static let knownLabels: Set<String> = {
    var s = Set<String>()
    for l in labels { s.insert(l.en.lowercased()); s.insert(l.ar) }
    for (a, b) in rewordEn { s.insert(a.lowercased()); s.insert(b.lowercased()) }
    for (a, b) in rewordAr { s.insert(a); s.insert(b) }
    for x in ["amount:", "available balance", "الرصيد المتاح", "from account", "transaction date", "to account"] { s.insert(x) }
    s.remove("from account:")
    return s
  }()

  static var enToAr: [String: String] {
    Dictionary(labels.map { ($0.en.lowercased(), $0.ar) }, uniquingKeysWith: { a, _ in a })
  }
  static var arToEn: [String: String] {
    Dictionary(labels.map { ($0.ar, $0.en) }, uniquingKeysWith: { a, _ in a })
  }
}
