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
    "TALABAT on Weds 3 Mar",
    "TALABAT on 03-MAR-30.",
    "TALABAT 03-MAR-30",
    "TALABAT on Mar 3, 2030 at 2:05 p.m.",
    "TALABAT 3 Mar 2030 at 2:05 pm",
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
    "TALABAT يوم الاثنين 3 فبراير 2030.",
    "TALABAT تاريخ 3 فبراير 2030 الساعة 10:15 م",
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
    ("CAFE 24 MARCH.", "CAFE 24 MARCH"),
    ("MAY 21.", "MAY 21"),
    ("CAFE SAT.", "CAFE SAT"),
  ])
  func namesWithDateWordsStay(_ tail: String, _ want: String) {
    #expect(CombinedReader.readRules(Self.en(tail)).merchant == want)
  }

  @Test(arguments: ["مطعم اليوم الجميل", "مخبز كل يوم", "مخبز كل يوم جديد", "متجر تاريخ العرب"])
  func arabicNameWithDayWordStays(_ name: String) {
    #expect(CombinedReader.readRules(Self.ar(name + ".")).merchant == name)
  }

  static func label(_ value: String) -> ExtractInput {
    Mails.input(
      subject: "Card transaction alert",
      ["Dear Customer,", "Your card ending 4821 was used for a purchase.", "Amount: AED 42.00", "Merchant: \(value)", "Thank you."])
  }

  @Test(arguments: [
    ("TALABAT يوم الاثنين", "TALABAT"),
    ("TALABAT الاثنين، 3 فبراير 2030", "TALABAT"),
    ("TALABAT بتاريخ 03-02-2030 الساعة 10:15 م", "TALABAT"),
    ("CARREFOUR Feb 2, 2030", "CARREFOUR"),
    ("CARREFOUR 2030-02-02 10:15", "CARREFOUR"),
    ("CARREFOUR 03-MAR-30", "CARREFOUR"),
    ("CARREFOUR 3 Mar 2030 2:05 p.m.", "CARREFOUR"),
    ("ENOC STATION 1023/12/345", "ENOC STATION 1023/12/345"),
    ("ENOC STATION 45/13/2030", "ENOC STATION 45/13/2030"),
    ("ENOC STATION 12/40/1880", "ENOC STATION 12/40/1880"),
    ("CAFE 24 MARCH", "CAFE 24 MARCH"),
  ])
  func labelPath(_ value: String, _ want: String) {
    #expect(CombinedReader.readRules(Self.label(value)).merchant == want)
  }

  @Test func learnedSenderNeverKeepsTheDate() {
    var mem = LearnedLayouts()
    let dates = ["Feb 2, 2030", "Feb 9, 2030", "Mar 14, 2030", "Apr 1, 2030", "Apr 20, 2030 10:15", "May 3, 2030"]
    let names = ["CARREFOUR", "LULU", "SPINNEYS", "WAITROSE", "UNION COOP", "CARREFOUR"]
    for i in dates.indices {
      let m = Mails.input(
        "bank-k.example", subject: "Card transaction alert",
        [
          "Dear Customer,", "Your card ending 4821 was used for a purchase.", "Amount: AED \(20 + i).00",
          "Merchant: \(names[i]) \(dates[i])", "Thank you.",
        ], at: 1_900_000_000_000 + Int64(i) * 86_400_000)
      let (r, next) = CombinedReader.read(m, mem)
      mem = next
      #expect(r.merchant == names[i], "mail \(i)")
    }
  }

  @Test func learnedSenderWithOneMerchant() {
    var mem = LearnedLayouts()
    let dates = ["Feb 2, 2030", "Feb 9, 2030", "Mar 14, 2030", "Apr 1, 2030", "Apr 20, 2030"]
    for i in dates.indices {
      let m = Mails.input(
        "bank-k.example", subject: "Card transaction alert",
        [
          "Dear Customer,", "Your card ending 4821 was used for a purchase.", "Amount: AED \(20 + i).00",
          "Merchant: CARREFOUR \(dates[i])", "Thank you.",
        ], at: 1_900_000_000_000 + Int64(i) * 86_400_000)
      let (r, next) = CombinedReader.read(m, mem)
      mem = next
      #expect(r.merchant == "CARREFOUR", "mail \(i)")
    }
  }

  @Test func invalidTimesStay() {
    #expect(MerchantWhen.trim("GATE 25:30") == "GATE 25:30")
    #expect(MerchantWhen.trim("GATE 12:75") == "GATE 12:75")
    #expect(MerchantWhen.trim("GATE 12:30") == "GATE")
  }

  @Test func reconcile() {
    #expect(MerchantWhen.reconcile(learned: "SPINNEYS Mar", rules: "SPINNEYS", text: "Merchant: SPINNEYS Mar 14, 2030") == "SPINNEYS")
    #expect(MerchantWhen.reconcile(learned: "Apr", rules: "CARREFOUR", text: "Merchant: CARREFOUR Apr 1, 2030") == "CARREFOUR")
    #expect(MerchantWhen.reconcile(learned: "SPINNEYS MARINA", rules: "SPINNEYS", text: "SPINNEYS MARINA 3") == "SPINNEYS MARINA")
    #expect(MerchantWhen.reconcile(learned: "TALABAT 3 Mar 2030", rules: nil) == "TALABAT")
    #expect(MerchantWhen.reconcile(learned: nil, rules: "TALABAT") == "TALABAT")
    #expect(
      MerchantWhen.reconcile(learned: "PHARMACY Mar", rules: "SAMPLE PHARMACY", text: "Merchant: SAMPLE PHARMACY Mar 14, 2030")
        == "PHARMACY")
    #expect(MerchantWhen.reconcile(learned: "MAY FLOWERS May", rules: "MAY FLOWERS", text: "at MAY FLOWERS May 5, 2030") == "MAY FLOWERS")
    #expect(MerchantWhen.reconcile(learned: "CAFE MAY", rules: "CAFE MAY", text: "at CAFE MAY.") == "CAFE MAY")
    #expect(MerchantWhen.reconcile(learned: "CAFE 24", rules: "CAFE", text: "at CAFE 24 on 3 Mar") == "CAFE 24")
    #expect(MerchantWhen.reconcile(learned: "CAFE DEL MAR", rules: "CAFE DEL", text: "at CAFE DEL MAR.") == "CAFE DEL MAR")
    #expect(MerchantWhen.reconcile(learned: "CAFE DEL MAR", rules: "CAFE DEL MAR", text: "at CAFE DEL MAR on 3 Mar") == "CAFE DEL MAR")
    #expect(MerchantWhen.reconcile(learned: "مخبز كل يوم", rules: "مخبز كل", text: "لدى مخبز كل يوم.") == "مخبز كل يوم")
  }

  @Test(arguments: [
    ("RISING SUN Mar 3, 2030", "RISING SUN"),
    ("RISING SUN 3 Mar 2030", "RISING SUN"),
    ("RISING SUN on Sun, 3 Mar 2030", "RISING SUN"),
    ("CAFE ON SUN", "CAFE ON SUN"),
    ("CAFE ON MONDAY", "CAFE"),
    ("SHOP Monday", "SHOP Monday"),
    ("SHOP Mar", "SHOP Mar"),
    ("SHOP يوم", "SHOP يوم"),
    ("مخبز كل يوم", "مخبز كل يوم"),
    ("CAFE DEL MAR", "CAFE DEL MAR"),
    ("GATE 24:30", "GATE 24:30"),
    ("GATE 24:00", "GATE 24:00"),
    ("GATE 23:59", "GATE"),
    ("GATE 13:05 pm", "GATE 13:05 pm"),
    ("GATE 1:05 pm", "GATE"),
    ("SHOP 45/13/2030 14:05", "SHOP 45/13/2030"),
    ("SHOP 1023/12/345", "SHOP 1023/12/345"),
    ("SHOP 2030-02-30", "SHOP"),
    ("SHOP 3-Mar-2030", "SHOP"),
    ("TALABAT 3 ايار 2030", "TALABAT"),
    ("TALABAT 3 أيار 2030", "TALABAT"),
    ("TALABAT 3 اذار 2030", "TALABAT"),
    ("TALABAT 3 ايلول 2030", "TALABAT"),
    ("TALABAT 3 تشرين الاول 2030", "TALABAT"),
    ("TALABAT 3 تشرين الأول 2030", "TALABAT"),
    ("TALABAT يوم الأثنين", "TALABAT"),
    ("TALABAT يوم الاثنين", "TALABAT"),
    ("TALABAT ٣ فبراير ٢٠٣٠", "TALABAT"),
    ("Mar 3, 2030", "Mar 3, 2030"),
    ("MAY 21", "MAY 21"),
  ])
  func tokenTrim(_ v: String, _ want: String) {
    #expect(MerchantWhen.trim(v) == want)
  }

  @Test func trimIsLinear() {
    let digits = String(String(repeating: "1 22 333 4 ", count: 20).prefix(200))
    let mixed = String(String(repeating: "12 3 Mar 2030 14:05 ", count: 12).prefix(200))
    let start = Date()
    for v in [digits, mixed, "SHOP " + digits, String(repeating: "1", count: 200)] {
      _ = MerchantWhen.trim(v)
      _ = MerchantWhen.isDateOnly(v)
      _ = MerchantWhen.reconcile(learned: v, rules: "SHOP", text: v + " " + v)
      _ = RuleReader.validMerchant(v, banks: [])
    }
    #expect(Date().timeIntervalSince(start) < 0.05)
  }

  @Test func readLearnedHasNoDate() {
    var mem = LearnedLayouts()
    let dates = ["Feb 2, 2030", "Feb 9, 2030", "Mar 14, 2030", "Apr 1, 2030", "Apr 20, 2030 10:15", "May 3, 2030"]
    let names = ["CARREFOUR", "LULU", "SPINNEYS", "WAITROSE", "UNION COOP", "CARREFOUR"]
    for i in dates.indices {
      let m = Mails.input(
        "bank-k.example", subject: "Card transaction alert",
        [
          "Dear Customer,", "Your card ending 4821 was used for a purchase.", "Amount: AED \(20 + i).00",
          "Merchant: \(names[i]) \(dates[i])", "Thank you.",
        ], at: 1_900_000_000_000 + Int64(i) * 86_400_000)
      let (r, next) = CombinedReader.readLearned(m, mem)
      mem = next
      if let got = r.merchant {
        #expect(!got.contains("2030") && !got.hasSuffix(" Feb") && !got.hasSuffix(" Mar") && !got.hasSuffix(" Apr"), "mail \(i): \(got)")
      }
    }
  }


  @Test(arguments: [
    "Mar 3, 2030", "on Monday", "3 Mar 2030 14:05", "14:05", "3 فبراير 2030", "Mon, 3 Mar", "on Weds 3 Mar", "03-MAR-30",
    "يوم الاثنين", "الاثنين 3 فبراير 2030", "10:15 م", "2:05 p.m.",
  ])
  func dateOnlyIsNoMerchant(_ v: String) {
    #expect(RuleReader.validMerchant(v, banks: []) == nil)
  }

  @Test func trailingDateIsTrimmed() {
    #expect(RuleReader.validMerchant("TALABAT on Mar 3", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("TALABAT 3 Mar 2030, 14:05", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("TALABAT يوم 3 فبراير 2030", banks: []) == "TALABAT")
    #expect(RuleReader.validMerchant("MONDAY CAFE", banks: []) == "MONDAY CAFE")
    #expect(RuleReader.validMerchant("CAFE SAT", banks: []) == "CAFE SAT")
    #expect(RuleReader.validMerchant("CAFE 24 MARCH", banks: []) == "CAFE 24 MARCH")
    #expect(RuleReader.validMerchant("MAY 21", banks: []) == "MAY 21")
    #expect(RuleReader.validMerchant("CAFE 24 MARCH 2030", banks: []) == "CAFE")
    #expect(RuleReader.validMerchant("CAFE on 24 MARCH", banks: []) == "CAFE")
  }
}
