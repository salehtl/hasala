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

  @Test("each DIB whole-body wording drops its synthetic fixture as its kind, and never one with one more payment line")
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
        #expect(TextGate.neverAPayment(text + "\n" + Self.paymentLine) == .pass(marked: w.kind == .oneTimeCode || w.kind == .declined ? TextGate.neverAPayment(text + "\n" + Self.paymentLine) == .pass(marked: true) : false), "\(w.pattern)")
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
