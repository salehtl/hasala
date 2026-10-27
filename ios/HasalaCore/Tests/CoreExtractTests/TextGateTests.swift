import Foundation
import Testing

@testable import CoreExtract

@Suite("TextGate: the bank-text drop lists and payment shapes")
struct TextGateTests {
  static let values: [String: String] = [
    "n": "123456", "amount": "20.00", "ccy": "AED", "card": "XX1234", "any": "SYNTHETIC SHOP", "date": "05-06-2026",
  ]

  static func synthetic(_ wording: String) -> String {
    var out = wording
    for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
    return out
  }

  static let paymentLine = "تم خصم مبلغ 20.00 في 05-06-2026 SYNTHETIC SHOP رصيدك 100.00"

  @Test("each DIB whole-body wording drops its synthetic fixture as its kind; with one more payment line it is no drop, and a code or decline goes on marked")
  func wholeBody() {
    #expect(DIBTexts.wholeBody.count >= 30)
    for w in TextGate.wholeBody {
      let text = Self.synthetic(w.pattern)
      #expect(w.matches(TextGate.Prepared(text)), "\(w.pattern)")
      #expect(!w.matches(TextGate.Prepared(text + "\n" + Self.paymentLine)), "\(w.pattern)")
      #expect(!w.matches(TextGate.Prepared(Self.paymentLine + "\n" + text)), "\(w.pattern)")
      switch w.kind {
      case .oneTimeCode, .declined:
        #expect(TextGate.neverAPayment(text) == .drop(w.kind), "\(w.pattern)")
        #expect(TextGate.neverAPayment(text + "\n" + Self.paymentLine) == .pass(marked: true), "\(w.pattern)")
        #expect(TextGate.neverAPayment(Self.paymentLine + "\n" + text) == .pass(marked: true), "\(w.pattern)")
      case .notice, .promotion:
        #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(w.pattern)")
        #expect(TextGate.notice(text) == w.kind, "\(w.pattern)")
        #expect(TextGate.notice(text + "\n" + Self.paymentLine) == nil, "\(w.pattern)")
      case .noPaymentShape:
        Issue.record("a whole-body wording of kind no_payment_shape")
      }
    }
  }

  @Test("a one-time-code marker is a code word beside 4 to 8 digits; a warning with no code is no marker")
  func codeMarker() {
    for text in ["Your OTP is 482913", "482913 is your code", "OTP 482913 for your purchase", "OTP: 4829", "رمز التحقق 482913", "482913 هو OTP"] {
      #expect(TextGate.neverAPayment(text) == .drop(.oneTimeCode), "\(text)")
    }
    for text in ["Never share your OTP with anyone", "Auth code 482913 for AED 20.00 at SHOP", "Card ending 1234 code", "OTP 12 is short"] {
      #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(text)")
    }
  }

  @Test("a code after its code word and a few words, quoted or in Arabic word order, is a one-time-code marker")
  func codeMarkerWordOrders() {
    for text in [
      "The One Time Password (OTP) for SAMPLE APP login is 482913, valid for 5 minutes", "The OTP for SAMPLE SHOP is \"482913\" valid for 5 minutes",
      "Your OTP for example.com purchase is 482913", "Passcode to sign in to SAMPLE APP: 482913", "482913 كلمة المرور الخاصة بك لمرة واحدة",
      "482913 كلمة السر لمرة واحدة", "إن كلمة السر لمرة واحدة الخاصة بك هي 482913", "رمز التحقق الخاص بك هو 482913", "482913 رمز التحقق الخاص بك",
    ] {
      #expect(TextGate.neverAPayment(text) == .drop(.oneTimeCode), "\(text)")
      #expect(TextGate.neverAPayment(text + "\n" + Self.paymentLine) == .pass(marked: true), "\(text)")
    }
    for text in [
      "Purchase of AED 20.00 at SAMPLE SHOP. Do not share your OTP for any reason. Available balance is 1234.56",
      "Never share your OTP for any reason. Your balance is 1,234.00", "رمز المتجر لدى SAMPLE SHOP هو 1234.56",
    ] {
      #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(text)")
    }
  }

  @Test("a wrong PIN or a wrong card verification code is a declined marker")
  func wrongPinMarker() {
    for text in [
      "تم ادخال رقم سري خاطئ لبطاقتك المنتهية بالرقم XX1234", "تم إدخال رمز تحقق غير صحيح لبطاقتك XX1234", "الرقم السري غير صحيح للبطاقة XX1234",
      "Incorrect PIN entered on your card ending 1234", "Wrong CVV entered for your card ending 1234",
    ] {
      #expect(TextGate.neverAPayment(text) == .drop(.declined), "\(text)")
      #expect(TextGate.neverAPayment(text + "\n" + Self.paymentLine) == .pass(marked: true), "\(text)")
    }
  }

  @Test("an authorisation or approval code line beside a payment is no one-time-code marker, in any spelling")
  func approvalCodes() {
    for line in [
      "Authorisation code 123456", "Authorization code: 123456", "Auth. code 123456", "AUTH CODE 123456", "Auth-code 123456",
      "Approval code 123456", "Appr. code: 123456", "Ref code 123456", "Ref. code 123456", "Reference code 123456",
      "Transaction code 123456", "Txn code 123456", "Trx code 123456", "Authorisation  code 123456",
    ] {
      let text = "Purchase of AED 50.00 at SAMPLE SHOP with card ending 1234. \(line)"
      #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(line)")
      #expect(TextGate.hasPaymentShape(text, lenient: true), "\(line)")
    }
    for text in ["Your code 123456", "Use code 123456 to log in", "Security code 123456", "PIN 1234 for your card"] {
      #expect(TextGate.neverAPayment(text) == .drop(.oneTimeCode), "\(text)")
    }
  }

  @Test("notice markers are phrases: registered, activated and registration alone in a payment text drop nothing")
  func noticePhrases() {
    for text in [
      "AED 250.00 spent on your registered card ending 1234 at SAMPLE SHOP on 05/06/2026. Avl bal AED 1,000.00",
      "AED 30.00 charged on your card ending 1234 at SAMPLE SHOP. Card activated for online use.",
      "Your card ending 1234 is registered. Purchase of AED 50.00 at SAMPLE SHOP",
      "Purchase of AED 20.00 at SAMPLE SHOP on your registered mobile wallet",
      "Card ending 1234 activated. AED 15.00 at SAMPLE CAFE",
      "Registration fee AED 100.00 for SAMPLE CLUB",
      "Your deactivated card ending 1234 was presented for AED 20.00 at SAMPLE SHOP",
    ] {
      #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(text)")
      #expect(TextGate.notice(text) == nil, "\(text)")
    }
    for text in [
      "Your card ending 1234 has been activated. Call 800 1234 for help.", "Your card ending 1234 is now active.",
      "Your card ending 1234 has been registered for Apple Pay.", "You are now registered for SMS alerts on 1234.",
      "Your registration request 12345 for online banking is received.", "Registration successful for card ending 1234.",
      "Your card ending 1234 has been deactivated.", "Card ending 1234 successfully activated for online purchases.",
    ] {
      #expect(TextGate.notice(text) == .notice, "\(text)")
    }
  }

  @Test("an amount followed by spent, charged, paid, used, sent or received is a transaction clause; to be or will be is not")
  func amountClauses() {
    for text in [
      "AED 250.00 spent on card 1234", "AED 30.00 charged on your card", "250.00 AED charged to card 1234", "USD 20 paid at SAMPLE SHOP",
      "AED 15.00 was used at SAMPLE CAFE", "AED 1,000.00 received from SAMPLE PERSON", "AED 5 has been sent to SAMPLE PERSON",
    ] {
      #expect(TextGate.hasTransactionClause(text), "\(text)")
    }
    for text in [
      "AED 20.00 to be charged on your card", "AED 20.00 will be charged on your card", "Spend AED 500 and earn points",
      "OTP 482913 for your purchase of USD 20.00 at SYNTHETIC SHOP", "Purchase of AED 50.00 at SAMPLE SHOP",
    ] {
      #expect(!TextGate.hasTransactionClause(text), "\(text)")
    }
    #expect(TextGate.neverAPayment("OTP 482913 for your purchase of USD 20.00 at SYNTHETIC SHOP. Do not share it.") == .drop(.oneTimeCode))
    #expect(TextGate.neverAPayment("AED 30.00 charged on your card ending 1234. Do not share OTP 482913.") == .pass(marked: true))
  }

  @Test("a transfer, payment or purchase of an amount that completed is a transaction clause; a code beside it goes on marked")
  func completedClauses() {
    for text in [
      "Transfer of AED 300.00 to SAMPLE PERSON completed. Confirmation code 482913", "Your order payment of AED 99.00 is confirmed. Code 482913",
      "Payment of AED 20.00 to SAMPLE.SHOP has been processed. OTP 482913", "Purchase of AED 45.00 at SAMPLE SHOP has been approved. PIN 1234",
      "Your transfer of AED 300.00 to SAMPLE PERSON was successful. Security code 482913",
      "Your transfer of AED 300.00 to SAMPLE PERSON is complete. Code 482913", "Transfer of AED 300.00 to SAMPLE PERSON done. OTP 482913",
      "Payment of AED 20.00 to SAMPLE SHOP has been done. PIN 1234", "Your transfer of AED 300.00 is now complete. Code 482913",
    ] {
      #expect(TextGate.hasTransactionClause(text), "\(text)")
      #expect(TextGate.neverAPayment(text) == .pass(marked: true), "\(text)")
    }
    for text in [
      "Use OTP 482913 to confirm your transfer of AED 300.00 to SAMPLE PERSON. The transfer will be completed once confirmed.",
      "OTP 482913: your payment of AED 20.00 to SAMPLE SHOP will be completed after you enter it",
      "Your transfer of AED 300.00 to SAMPLE PERSON has not been completed. Code 482913", "Your payment of AED 20.00 wasn't successful. OTP 482913",
      "Purchase of AED 50.00 at SAMPLE SHOP. OTP 482913", "مشتريات بمبلغ 123.45 من بطاقة XX1234 رمز التحقق 482913",
      "Your transfer of AED 300.00 to SAMPLE PERSON is not complete. Code 482913",
      "OTP 482913 for your payment of AED 20.00 to SAMPLE SHOP, enter it to complete",
      "OTP 482913 for your transfer of AED 300.00 to SAMPLE PERSON, enter it and you are done", "Your transfer of AED 300.00 will be done after you enter OTP 482913",
    ] {
      #expect(!TextGate.hasTransactionClause(text), "\(text)")
      #expect(TextGate.neverAPayment(text) == .drop(.oneTimeCode), "\(text)")
    }
    for text in ["Transfer of AED 300.00 to SAMPLE PERSON could not be processed", "Purchase of AED 20.00 at SAMPLE SHOP was declined."] {
      #expect(TextGate.neverAPayment(text) == .drop(.declined), "\(text)")
    }
  }

  static let leadInStatements = [
    "Your purchase of AED 89.50 at SYNTHETIC SHOP with card XX1234 on 05-06-2026. T&C apply",
    "Dear Customer, Purchase of AED 89.50 at SYNTHETIC SHOP with card XX1234. T&C apply", "Card XX1234: Purchase of AED 89.50 at SYNTHETIC SHOP. T&C apply",
    "Thank you for your purchase of AED 89.50 at SYNTHETIC SHOP. Earn 5x points. T&C apply",
    "Dear Customer, your transfer of AED 300.00 to SAMPLE PERSON is complete. T&C apply", "AED 89.50 purchase at SYNTHETIC SHOP on card XX1234. T&C apply",
    "Purchase: AED 89.50 at SYNTHETIC SHOP card XX1234. T&C apply", "عزيزي العميل، شراء بمبلغ 89.50 لدى متجر. عرض خاص",
    "عزيزي العميل، مشتريات بمبلغ 89.50 لدى متجر عرض خاص", "Dear Customer your payment of AED 20.00 to SAMPLE SHOP. Offer valid till 30-06-2026",
    "عزيزي العميل شراء بمبلغ 89.50 لدى متجر. عرض خاص",
  ]

  @Test("a payment stated after a comma, a colon or a short lead-in keeps a text that has a promotion marker")
  func leadInStatements() {
    for text in Self.leadInStatements {
      #expect(TextGate.hasPaymentStatement(text), "\(text)")
      #expect(TextGate.notice(text) == nil, "\(text)")
      #expect(TextGate.neverAPayment(text) == .pass(marked: false), "\(text)")
      #expect(TextGate.hasPaymentShape(text, lenient: true), "\(text)")
    }
  }

  @Test("a payment stated at the start of a sentence or line keeps a text that has a notice or promotion marker; after other words, or of an amount or more, it is none")
  func statements() {
    for text in [
      "Purchase of AED 89.50 at SYNTHETIC GROCER with Credit Card ending 4321 on 05-JUN-2026 12:30. T&C apply",
      "Purchase of AED 50.00 at SAMPLE SHOP\nT&C apply", "Dear Customer. Payment of AED 20.00 to SAMPLE SHOP. Offer valid till 30-06-2026",
      "Paid AED 20.00 at SAMPLE SHOP. T&C apply", "Transfer of 300.00 to SAMPLE PERSON\nSMS STOP to 1234",
      "سحب نقدي 200.00 من صراف آلي في 05-06-2026 رصيدك 1,000.00\nعرض خاص على البطاقات",
      "مشتريات بقيمة 123.45 من بطاقة XX1234 لدى SAMPLE SHOP\nعرض لفترة محدودة",
      "تحويل بين حساباتك بمبلغ AED 4,321.09 في 05-06-2026. عروض البطاقات",
    ] {
      #expect(TextGate.hasPaymentStatement(text), "\(text)")
      #expect(TextGate.notice(text) == nil, "\(text)")
    }
    for text in [
      "OTP 482913 for your purchase of USD 20.00 at SYNTHETIC SHOP", "Get 5% cashback on every purchase above AED 100 with your card. T&C apply.",
      "Purchase of AED 100 or more earns 5% cashback. T&C apply.", "Spend AED 500 and earn points. T&C apply", "عرض خاص: خصم 20% على مشترياتك",
      "خصم 20% على مشترياتك. عرض لفترة محدودة", "شراء 2 واحصل على 1 مجانا. عرض لفترة محدودة",
      "Make a purchase of AED 100 to win a SAMPLE PRIZE. T&C apply", "Get AED 50 back, AED 500 purchase minimum. T&C apply",
      "Dear Customer, your purchase of AED 100 or more earns 5% cashback. T&C apply", "Get 5% cashback when you shop with your card for AED 100. T&C apply",
    ] {
      #expect(!TextGate.hasPaymentStatement(text), "\(text)")
    }
    #expect(TextGate.neverAPayment("Your purchase of AED 120.00 at SYNTHETIC STORE was declined. T&C apply") == .drop(.declined))
    #expect(TextGate.notice("Dear Customer, your purchase of AED 100 or more earns 5% cashback. T&C apply") == .promotion)
    #expect(TextGate.notice("Make a purchase of AED 100 to win a SAMPLE PRIZE. T&C apply") == .promotion)
    #expect(TextGate.notice("Purchase of AED 100 or more earns 5% cashback. T&C apply.") == .promotion)
    #expect(TextGate.notice("شراء 2 واحصل على 1 مجانا. عرض لفترة محدودة") == .promotion)
  }

  @Test("a promo, voucher or coupon code is no one-time-code marker")
  func promoCodes() {
    for line in ["Promo code 1234", "Promo code: 123456", "Voucher code 98765", "Coupon code 4321", "Discount code 5555"] {
      #expect(TextGate.neverAPayment("Paid AED 20.00 at SAMPLE SHOP. \(line) for 10% off") == .pass(marked: false), "\(line)")
    }
  }

  @Test("a marker drops a text only when it has no transaction clause; with one, the text goes on marked")
  func markersAndClauses() {
    #expect(TextGate.neverAPayment("Your purchase of AED 20.00 at SHOP was declined.") == .drop(.declined))
    #expect(TextGate.neverAPayment("AED 20.00 has been debited. Do not share OTP 482913.") == .pass(marked: true))
    #expect(TextGate.neverAPayment("تم خصم 20.00 من حسابك. رمز التحقق 482913") == .pass(marked: true))
    #expect(TextGate.neverAPayment("تم رفض عملية شراء بمبلغ 20.00") == .drop(.declined))
    #expect(TextGate.neverAPayment("AED 20.00 will be debited. OTP 482913") == .drop(.oneTimeCode))
    #expect(TextGate.notice("Get 5% cashback on every purchase above AED 100. T&C apply.") == .promotion)
    #expect(TextGate.notice("Purchase of AED 20.00 at SHOP was successful.\nT&C apply") == nil)
    #expect(TextGate.notice("Your card ending 1234 has been blocked. Call 800 1234") == .notice)
    #expect(TextGate.notice("Your card ending 1234 has been blocked after AED 20.00 was debited") == nil)
    #expect(TextGate.notice("عرض خاص: خصم 20% على مشترياتك") == .promotion)
  }

  @Test("the payment shape: a payment word and any number from a bank or no sender; an amount or a masked card otherwise")
  func shape() {
    #expect(TextGate.hasPaymentShape("خصم 200.00 في 05-06-2026", lenient: true))
    #expect(TextGate.hasPaymentShape("the transfer is 200", lenient: true))
    #expect(!TextGate.hasPaymentShape("the transfer is 200", lenient: false))
    #expect(TextGate.hasPaymentShape("I sent you AED 50", lenient: false))
    #expect(TextGate.hasPaymentShape("Purchase on card XX1234 done", lenient: false))
    #expect(TextGate.hasPaymentShape("دفعت 50 درهم", lenient: false))
    #expect(!TextGate.hasPaymentShape("See you at 7", lenient: true))
    #expect(!TextGate.hasPaymentShape("Transfer done", lenient: true))
    #expect(TextGate.maskedLast4("Card XX1234 used") == "1234" && TextGate.maskedLast4("card ending with 9876") == "9876")
    #expect(TextGate.maskedLast4("no card here 12") == nil)
  }

  @Test("the set-up test is the normalized body \"hasala test\", in any case, with a trailing stop")
  func setUpTest() {
    for t in ["Hasala test", "hasala test", "HASALA TEST", "Hasala test.", " Hasala test! "] { #expect(TextGate.isSetUpTest(t), "\(t)") }
    for t in ["Hasala test 2", "hasala", "Hasala testing", "test hasala"] { #expect(!TextGate.isSetUpTest(t), "\(t)") }
  }

  @Test("a merchant from a person's text comes only from a card-purchase label, first 4 words, at most 40 bytes")
  func merchant() {
    #expect(TextGate.cardPurchaseMerchant("Paid AED 20 at SAMPLE BAKERY ONE TWO THREE", merchant: "SAMPLE BAKERY ONE TWO THREE") == "SAMPLE BAKERY ONE TWO")
    #expect(TextGate.cardPurchaseMerchant("Merchant: SAMPLE SHOP", merchant: "SAMPLE SHOP") == "SAMPLE SHOP")
    #expect(TextGate.cardPurchaseMerchant("شراء 20 درهم لدى متجر مثال", merchant: "متجر مثال") == "متجر مثال")
    #expect(TextGate.cardPurchaseMerchant("Sent AED 20 to SAMPLE PERSON", merchant: "SAMPLE PERSON") == "")
    #expect(TextGate.cardPurchaseMerchant("Received AED 20 from SAMPLE PERSON", merchant: "SAMPLE PERSON") == "")
    #expect(TextGate.cardPurchaseMerchant("Paid at the gate", merchant: nil) == "")
    #expect(TextGate.limited(String(repeating: "x", count: 60)).utf8.count == 40)
  }
}
