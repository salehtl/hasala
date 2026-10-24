import Foundation
import Testing

@testable import CoreExtract

@Suite struct MerchantDateTests {
  static func en(_ tail: String) -> ExtractInput {
    Mails.input(subject: "Card alert", ["Dear Customer,", "Your card ending 4821 was used for AED 42.00 at \(tail)", "Thank you."])
  }

  static func ar(_ tail: String) -> ExtractInput {
    Mails.input(subject: "إشعار", ["عزيزي المتعامل،", "تم خصم مبلغ 42.00 درهم من بطاقتك المنتهية ب 4821 لدى \(tail)", "شكرا لكم"])
  }

  @Test(arguments: [
    "TALABAT on Mar 3, 2030.",
    "TALABAT on Mar 3",
    "TALABAT on March 3rd, 2030 at 14:05.",
    "TALABAT on 3 Mar 2030.",
    "TALABAT on 3 March",
    "TALABAT on 3-Mar-2030 14:05",
    "TALABAT on Sept. 12, 2030",
    "TALABAT on Monday.",
    "TALABAT on Mon, 3 Mar 2030 14:05.",
    "TALABAT on Fri 3 Mar",
    "TALABAT on 03/03/2030.",
    "TALABAT Mar 3, 2030.",
    "TALABAT 3 Mar 2030 14:05",
    "TALABAT 14:05",
  ])
  func englishDateEndsTheMerchant(_ tail: String) {
    #expect(CombinedReader.readRules(Self.en(tail)).merchant == "TALABAT")
  }

  @Test(arguments: [
    "TALABAT يوم 3 فبراير 2030.",
    "TALABAT يوم الاثنين.",
    "TALABAT تاريخ 03-02-2030.",
    "TALABAT بتاريخ 03-02-2030.",
    "TALABAT 3 فبراير 2030",
    "مطعم الشرق يوم 3 مارس",
  ])
  func arabicDateEndsTheMerchant(_ tail: String) {
    let want = tail.hasPrefix("TALABAT") ? "TALABAT" : "مطعم الشرق"
    #expect(CombinedReader.readRules(Self.ar(tail)).merchant == want)
  }

  @Test(arguments: [
    ("MONDAY CAFE on Mar 3, 2030.", "MONDAY CAFE"),
    ("MAR MIKHAEL BISTRO on 3 Mar 2030.", "MAR MIKHAEL BISTRO"),
    ("MAR MIKHAEL.", "MAR MIKHAEL"),
    ("SUN AND SAND SPORTS.", "SUN AND SAND SPORTS"),
    ("CAFE ON MAIN.", "CAFE ON MAIN"),
    ("MAY FLOWERS on May 5.", "MAY FLOWERS"),
    ("DUBAI MARINA MALL on Sat.", "DUBAI MARINA MALL"),
  ])
  func namesWithDateWordsStay(_ tail: String, _ want: String) {
    #expect(CombinedReader.readRules(Self.en(tail)).merchant == want)
  }

  @Test func arabicNameWithDayWordStays() {
    #expect(CombinedReader.readRules(Self.ar("مطعم اليوم الجميل.")).merchant == "مطعم اليوم الجميل")
  }

  @Test(arguments: ["Mar 3, 2030", "on Monday", "3 Mar 2030 14:05", "14:05", "3 فبراير 2030", "Mon, 3 Mar"])
  func dateOnlyIsNoMerchant(_ v: String) {
    #expect(RuleReader.validMerchant(v, banks: []) == nil)
  }

  @Test func trailingDateIsTrimmed() {
    #expect(RuleReader.validMerchant("TALABAT on Mar 3", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("TALABAT 3 Mar 2030, 14:05", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("TALABAT يوم 3 فبراير 2030", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("MONDAY CAFE", banks: []) == "MONDAY CAFE")
    #expect(RuleReader.validMerchant("CAFE SAT", banks: []) == "CAFE SAT")
  }
}
