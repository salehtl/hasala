import Foundation
import Testing

@testable import CoreExtract

@Suite struct RuleReaderTests {
  @Test func labelledAmountWithBalanceIgnored() {
    let r = CombinedReader.readRules(Mails.cardPurchaseEN(amount: "1,234.50", merchant: "NORTHWIND CAFE"))
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == 123_450)
    #expect(r.currency == "AED")
    #expect(r.direction == .debit)
    #expect(r.merchant == "NORTHWIND CAFE")
  }

  @Test func arabicSentenceRefund() {
    let r = CombinedReader.readRules(
      Mails.input(subject: "إشعار", ["عزيزي المتعامل،", "تم إرجاع مبلغ 45.00 درهم على بطاقة الائتمان المنتهية ب 9012.", "مع اطيب التحيات"]))
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == 4_500)
    #expect(r.currency == "AED")
    #expect(r.direction == .credit)
    #expect(r.kind == .cardRefund)
    #expect(r.last4 == "9012")
  }

  @Test func oneTimePasswordIsNotATransaction() {
    let r = CombinedReader.readRules(
      Mails.input(subject: "Your OTP", ["Your one time password for the purchase of AED 300.00 at SAMPLE STORE is 482913."]))
    #expect(r.outcome == .notTransaction)
    #expect(r.amountMinor == nil)
  }

  @Test func arabicIndicDigits() {
    let r = CombinedReader.readRules(
      Mails.input(subject: "Card alert", ["Dear Customer,", "Your card ending 1111 was used for a purchase of AED ١٢٣٫٤٥ at SAMPLE SHOP."]))
    #expect(r.amountMinor == 12_345)
    #expect(r.merchant == "SAMPLE SHOP")
  }

  @Test func threeDecimalCurrencyHasNoAmountInHundredths() {
    let m = Mails.input(subject: "Debit alert", ["Your account has been debited with KWD 12.345 for a transfer."])
    let r = CombinedReader.readRules(m)
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == nil)
    #expect(r.currency == "KWD")
    #expect(!CombinedReader.read(m, LearnedLayouts()).0.meetsAgreementBar)
    #expect(RuleReader.read(m).amountMinor == 12_345)
  }
}

@Suite struct PromoFilterTests {
  @Test(arguments: [
    "Purchase of AED 45.00 at LEARNING HUB",
    "مبلغ 45.00 درهم لدى معرض السيارات",
    "الرصيد المتوفر 45.00 درهم",
    "Your card was used for AED 45.00 at FREE ZONE MART",
  ])
  func transactionLinesSurvive(_ line: String) {
    #expect(PromoFilter.strip(line) == line)
  }

  @Test(arguments: ["Earn 5% cashback up to AED 500 this month", "احصل على خصم 20% عند الدفع", "وفر 50 درهم مع عروضنا"])
  func promoLinesGo(_ line: String) {
    #expect(PromoFilter.strip(line) == "")
  }

  @Test func dropsOfferLinesWithNumbersButKeepsPostedLines() {
    let text = ["Earn 5% cashback up to AED 500 this month", "AED 20.00 cashback has been credited", "Plain line 12"].joined(
      separator: "\n")
    #expect(PromoFilter.strip(text) == ["AED 20.00 cashback has been credited", "Plain line 12"].joined(separator: "\n"))
  }

  @Test func promoAmountDoesNotWin() {
    let m = Mails.input(
      subject: "Card transaction alert",
      [
        "Your card ending 4242 was used for AED 75.00 at SAMPLE BOOKS.", "Win up to AED 10,000 with our exclusive offer!",
      ])
    let (r, _) = CombinedReader.read(m, LearnedLayouts())
    #expect(r.amountMinor == 7_500)
  }
}

@Suite struct PendingTests {
  @Test func submittedSuccessfullyButProcessingIsPending() {
    let m = Mails.input(
      subject: "Transfer request",
      ["Dear Customer,", "Your transfer request of AED 900.00 has been submitted successfully and is being processed."])
    #expect(CombinedReader.readRules(m).outcome == .pending)
  }

  @Test(arguments: ["قيد التنفيذ", "قيد المعالجة", "جاري التنفيذ"])
  func arabicPendingStatus(_ status: String) {
    let (r, _) = CombinedReader.read(Mails.transferAR(amount: "500.00", status: status), LearnedLayouts())
    #expect(r.outcome == .pending)
    #expect(r.kind == .transferNotice)
    #expect(!r.meetsAgreementBar)
  }

  @Test func arabicCompletedStatus() {
    let (r, _) = CombinedReader.read(Mails.transferAR(amount: "500.00", status: "تمت بنجاح"), LearnedLayouts())
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == 50_000)
  }

  @Test(arguments: ["Pending", "In process", "In Progress", "Processing"])
  func englishPendingStatus(_ status: String) {
    let m = Mails.input(
      subject: "Money Transfer",
      [
        "Dear Customer,", "Your Domestic Fund Transfer request has been received.", "Amount", "AED 800.00", "To",
        "AE000000000000000000002", "Status", status,
      ])
    #expect(CombinedReader.readRules(m).outcome == .pending)
  }

  @Test func initiatedButStatusSaysCredited() {
    let m = Mails.input(
      subject: "Money Transfer",
      [
        "Dear Customer,", "Your Domestic Fund Transfer has been initiated with the details below.", "Amount", "800.00", "To",
        "AE000000000000000000002", "Beneficiary Bank", "Bank C", "Status", "Credited to beneficiary",
      ])
    let r = CombinedReader.readRules(m)
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == 80_000)
    #expect(r.kind == .transferNotice)
  }

  @Test func inlineStatusAfterColon() {
    let m = Mails.input(
      subject: "Transfer update", ["Dear Customer,", "Transfer Amount: AED 250.00", "Transaction Status: Pending"])
    #expect(CombinedReader.readRules(m).outcome == .pending)
  }

  @Test func initiatedWithNoStatusIsPending() {
    let m = Mails.input(
      subject: "Transfer request", ["Your transfer of AED 300.00 to SAMPLE TRADING has been initiated and will be processed shortly."])
    #expect(CombinedReader.readRules(m).outcome == .pending)
  }

  @Test func cardPurchaseIsNeverPending() {
    let m = Mails.input(
      subject: "Card transaction alert",
      ["Your credit card ending 7310 was used for a purchase of AED 60.00 at SAMPLE MART.", "Status: Pending"])
    #expect(CombinedReader.readRules(m).outcome == .transaction)
  }
}

@Suite struct TwoCurrencyTests {
  @Test func aedDebitAmountWinsOverTransferCurrency() {
    let m = Mails.input(
      "bank-d.example", subject: "Telegraphic Transfer",
      [
        "Dear Customer,", "Here is the status of your Telegraphic Transfer.", "Debit Amount:", "AED 3,673.00", "Transaction Amount:",
        "USD 1,000.00", "Beneficiary Name:", "SAMPLE BROKER LLC", "Status:", "Success",
      ])
    let (r, mem) = CombinedReader.read(m, LearnedLayouts())
    #expect(r.outcome == .transaction)
    #expect(r.amountMinor == 367_300)
    #expect(r.currency == "AED")
    #expect(r.kind == .transferNotice)
    #expect(!r.agreed)
    var again = m
    again.receivedAtMs += 1
    let (r2, _) = CombinedReader.read(again, mem)
    #expect(r2.amountMinor == 367_300)
    #expect(r2.agreed)
  }

  @Test(arguments: [
    ["Your card ending 4242 was used for USD 20.00 at SAMPLE SHOP. Cashback of AED 1.00 has been credited."],
    ["Your card ending 4242 was used for USD 20.00 at SAMPLE SHOP.", "Cashback of AED 1.00 has been credited."],
  ])
  func cashbackIsNotTheAEDAmount(_ lines: [String]) {
    let m = Mails.input(subject: "Card transaction alert", lines)
    let r = CombinedReader.readRules(m)
    #expect(r.amountMinor == 2_000)
    #expect(r.currency == "USD")
    let (c, _) = CombinedReader.read(m, LearnedLayouts())
    #expect(c.currency != "AED" || c.amountMinor != 100)
  }

  @Test func aedConversionAfterForeignAmount() {
    let m = Mails.input(
      subject: "Card transaction alert", ["Your card ending 5555 was used for USD 10.00 (AED 36.73) at SAMPLE ONLINE."])
    let r = CombinedReader.readRules(m)
    #expect(r.amountMinor == 3_673)
    #expect(r.currency == "AED")
  }

  @Test func foreignOnlyStaysForeign() {
    let m = Mails.input(
      subject: "Card transaction alert", ["Your card ending 5555 was used for USD 10.00 at SAMPLE ONLINE. Available balance AED 900.00"])
    let r = CombinedReader.readRules(m)
    #expect(r.amountMinor == 1_000)
    #expect(r.currency == "USD")
  }
}

@Suite struct KindTests {
  @Test func kinds() {
    #expect(CombinedReader.readRules(Mails.cardPurchaseAR(amount: "12.00", merchant: "SAMPLE")).kind == .cardPurchase)
    #expect(CombinedReader.readRules(Mails.cardPurchaseEN(amount: "12.00", merchant: "SAMPLE")).kind == .cardPurchase)
    #expect(CombinedReader.readRules(Mails.transferAR(amount: "12.00", status: "تمت بنجاح")).kind == .transferNotice)
    #expect(CombinedReader.readRules(Mails.accountDebitAR(amount: "12.00")).kind == .accountDebitAlert)
    let credit = Mails.input(
      subject: "Notification", ["إشعار إيداع", "عزيزي المتعامل,", "إشعار إيداع فى الحساب", "المبلغ", "AED 900.00", "الحالة", "تمت بنجاح"])
    #expect(CombinedReader.readRules(credit).kind == .accountCreditAlert)
    #expect(CombinedReader.readRules(credit).direction == .credit)
    let reversal = Mails.input(
      subject: "Transaction reversed",
      ["A transaction to the value of AED 15.00 made at SAMPLE RIDES on your card ending with XX4321 has been reversed."])
    let r = CombinedReader.readRules(reversal)
    #expect(r.kind == .cardRefund)
    #expect(r.direction == .credit)
    #expect(r.merchant == "SAMPLE RIDES")
    #expect(r.last4 == "4321")
  }

  @Test func transferInBodyBeatsAccountDebit() {
    let m = Mails.input(
      subject: "Notification",
      [
        "Dear Customer,", "Thank you for banking with us.", "Please see the details below.",
        "AED 500.00 has been debited from your account and transferred to SAMPLE TRADING.",
      ])
    #expect(CombinedReader.readRules(m).kind == .transferNotice)
  }

  @Test func last4FromMaskedCard() {
    #expect(CombinedReader.readRules(Mails.cardPurchaseAR(amount: "12.00", merchant: "SAMPLE")).last4 == "4821")
    #expect(CombinedReader.readRules(Mails.accountDebitAR(amount: "12.00")).last4 == nil)
  }
}

@Suite struct AgreementTests {
  func reading(
    _ amount: Int64, _ conf: Int, _ cur: String = "AED", merchant: String? = nil, direction: String = "debit",
    guessed: Bool = false, explicit: Bool = true, layout: Bool = true
  ) -> Reading {
    Reading(
      isTransaction: true, amountMinor: amount, currency: cur, currencyExplicit: explicit, merchant: merchant,
      direction: direction, directionGuessed: guessed, fromLayout: layout, confidence: conf)
  }

  @Test func directionConflictIsNotAgreement() {
    let (a, agreed) = CombinedReader.combine(learned: reading(100, 90), rules: reading(100, 90, direction: "credit"))
    #expect(!agreed)
    #expect(a.confidence == 50)
    let (b, ok) = CombinedReader.combine(learned: reading(100, 90, guessed: true), rules: reading(100, 85, direction: "credit"))
    #expect(ok)
    #expect(b.direction == "credit")
  }

  @Test func defaultedCurrencyOnBothSidesIsNotAgreement() {
    let (a, agreed) = CombinedReader.combine(learned: reading(100, 90, explicit: false), rules: reading(100, 90, explicit: false))
    #expect(!agreed)
    #expect(a.confidence <= 60)
    #expect(CombinedReader.combine(learned: reading(100, 90, explicit: false), rules: reading(100, 90)).1)
  }

  @Test func unlearnedLayoutIsNotAVote() {
    let (a, agreed) = CombinedReader.combine(learned: reading(100, 40, layout: false), rules: reading(100, 90))
    #expect(!agreed)
    #expect(a.confidence == 60)
  }

  @Test func unknownCurrencyMarkIsNotAED() {
    #expect(ILex.currency("د.ا") == nil)
    #expect(ILex.currency("د.إ") == "AED")
    var mem = LearnedLayouts()
    var last: ExtractReading?
    for (i, amt) in ["150.00", "75.00", "20.00", "64.00"].enumerated() {
      let m = Mails.input(
        "bank-s.example", subject: "Card alert", ["Dear Customer,", "SR \(amt) spent at SAMPLE \(i) with your card ending 4242."],
        at: Int64(i))
      let (r, next) = CombinedReader.read(m, mem)
      mem = next
      last = r
    }
    #expect(last?.meetsAgreementBar == false)
  }

  @Test func agreeTakesTheHigherPlusFiveCappedAt95() {
    let (a, agreed) = CombinedReader.combine(learned: reading(100, 80), rules: reading(100, 70, merchant: "X"))
    #expect(agreed)
    #expect(a.confidence == 85)
    #expect(a.merchant == "X")
    #expect(CombinedReader.combine(learned: reading(100, 93), rules: reading(100, 95)).0.confidence == 95)
  }

  @Test func disagreeCapsAt50() {
    let (a, agreed) = CombinedReader.combine(learned: reading(100, 90), rules: reading(200, 80))
    #expect(!agreed)
    #expect(a.amountMinor == 100)
    #expect(a.confidence == 50)
    #expect(CombinedReader.combine(learned: reading(100, 90), rules: reading(100, 80, "USD")).0.confidence == 50)
  }

  @Test func oneReaderCapsAt60() {
    #expect(CombinedReader.combine(learned: reading(100, 90), rules: .none).0.confidence == 60)
    #expect(CombinedReader.combine(learned: .none, rules: reading(100, 95)).0.confidence == 60)
    #expect(!CombinedReader.combine(learned: .none, rules: .none).0.isTransaction)
  }
}

@Suite struct LearnedSequenceTests {
  @Test func learnsFromTwoReadsTheThirdThenRelearnsAfterALayoutChange() {
    var mem = LearnedLayouts()
    let first = [("12.50", "SAMPLE BAKERY"), ("230.00", "SAMPLE PHARMACY"), ("8.75", "SAMPLE KIOSK")]
    var readings: [ExtractReading] = []
    for (i, (amt, m)) in first.enumerated() {
      let (r, next) = CombinedReader.readLearned(Mails.cardPurchaseAR(amount: amt, merchant: m, at: Int64(i)), mem)
      mem = next
      readings.append(r)
    }
    #expect(readings[0].notes[0].hasPrefix("unlearned layout"))
    #expect(readings[2].amountMinor == 875)
    #expect(readings[2].merchant == "SAMPLE KIOSK")
    #expect(readings[2].notes[0].hasPrefix("layout n=3"))
    #expect(readings[2].confidencePercent > 60)

    let changed: [(String, String)] = [("40.00", "SAMPLE GARAGE"), ("19.99", "SAMPLE FLORIST"), ("5.25", "SAMPLE PARKING")]
    var after: [ExtractReading] = []
    for (i, (amt, m)) in changed.enumerated() {
      let (r, next) = CombinedReader.readLearned(Mails.cardPurchaseEN(amount: amt, merchant: m, at: Int64(10 + i)), mem)
      mem = next
      after.append(r)
    }
    #expect(after[0].notes[0].hasPrefix("unlearned layout"))
    #expect(after[2].notes[0].hasPrefix("layout n=3"))
    #expect(after[2].amountMinor == 525)
    #expect(after[2].merchant == "SAMPLE PARKING")
    #expect(mem.senders.count == 2)

    let (back, _) = CombinedReader.readLearned(Mails.cardPurchaseAR(amount: "61.00", merchant: "SAMPLE TAILOR", at: 20), mem)
    #expect(back.notes[0].hasPrefix("layout n=4"))
    #expect(back.amountMinor == 6_100)
    #expect(back.merchant == "SAMPLE TAILOR")
  }

  @Test func combinedAgreementClearsTheBarOnceLearned() {
    var mem = LearnedLayouts()
    var last: ExtractReading?
    for (i, amt) in ["10.00", "20.00", "30.00", "40.00"].enumerated() {
      let (r, next) = CombinedReader.read(Mails.cardPurchaseAR(amount: amt, merchant: "SAMPLE \(i)", at: Int64(i)), mem)
      mem = next
      last = r
    }
    #expect(last?.agreed == true)
    #expect(last?.meetsAgreementBar == true)
    #expect(last?.amountMinor == 4_000)
  }

  @Test func readingIsAPureFunctionOfStateAndMail() {
    var mem = LearnedLayouts()
    for i in 0..<3 {
      mem = CombinedReader.read(Mails.cardPurchaseEN(amount: "\(i + 1).00", merchant: "SAMPLE", at: Int64(i)), mem).1
    }
    let m = Mails.cardPurchaseEN(amount: "77.00", merchant: "SAMPLE NEW")
    let a = CombinedReader.read(m, mem)
    let b = CombinedReader.read(m, mem)
    #expect(a.0 == b.0)
    #expect(a.1 == b.1)
  }
}

@Suite struct LearnedStateTests {
  @Test func codableRoundTripKeepsReadingsIdentical() throws {
    var plain = LearnedLayouts()
    var trip = LearnedLayouts()
    let mails = (0..<6).map { Mails.cardPurchaseAR(amount: "\($0 + 1)1.00", merchant: "SAMPLE \($0)", at: Int64($0)) }
      + (0..<3).map { Mails.transferAR(amount: "\($0 + 2)00.00", status: "تمت بنجاح", at: Int64(10 + $0)) }
    for m in mails {
      let (a, na) = CombinedReader.read(m, plain)
      let (b, nb) = CombinedReader.read(m, trip)
      #expect(a == b)
      plain = na
      trip = try JSONDecoder().decode(LearnedLayouts.self, from: try JSONEncoder().encode(nb))
      #expect(trip == nb)
    }
  }

  @Test func boilerplateIsKeptOnceAsAnchorsNotPerExample() throws {
    var mem = LearnedLayouts()
    for i in 0..<5 {
      mem = CombinedReader.read(Mails.cardPurchaseEN(amount: "\(i + 3).00", merchant: "SAMPLE \(i)", at: Int64(i)), mem).1
    }
    let layout = try #require(mem.senders["bank-b.example"]?.layouts.first)
    #expect(layout.examples.count == 5)
    let json = String(decoding: try JSONEncoder().encode(mem), as: UTF8.self)
    #expect(json.components(separatedBy: "purchase").count - 1 == 1)
    #expect(json.contains("sample"))
  }

  @Test func boundsHold() {
    var mem = LearnedLayouts()
    for i in 0..<(LearnedLayouts.senderLimit + 5) {
      var m = Mails.cardPurchaseEN(amount: "1.00", merchant: "SAMPLE", at: Int64(i))
      m.sender = "bank-\(i).example"
      mem = CombinedReader.read(m, mem).1
    }
    #expect(mem.senders.count == LearnedLayouts.senderLimit)
    #expect(mem.senders["bank-0.example"] == nil)
    #expect(mem.senders["bank-\(LearnedLayouts.senderLimit + 4).example"] != nil)

    var one = LearnedLayouts()
    for i in 0..<(LearnedLayouts.exampleLimitPerLayout + 4) {
      one = CombinedReader.read(Mails.cardPurchaseEN(amount: "\(i + 1).00", merchant: "SAMPLE \(i)", at: Int64(i)), one).1
    }
    let layout = one.senders["bank-b.example"]?.layouts.first
    #expect(layout?.examples.count == LearnedLayouts.exampleLimitPerLayout)
    #expect(layout?.seen == LearnedLayouts.exampleLimitPerLayout + 4)

    var many = LearnedLayouts()
    for i in 0..<(LearnedLayouts.layoutLimitPerSender + 3) {
      let letters = Array("abcdefghij")
      let tag = String(String(i).map { letters[Int(String($0))!] })
      let words = (0..<12).map { "w" + tag + String(letters[$0 % 10]) + String(repeating: "q", count: $0) }
      let m = Mails.input(
        "bank-z.example", subject: "s\(i)", [words.joined(separator: " "), "Amount AED \(i + 1).00 debited"], at: Int64(i))
      many = CombinedReader.read(m, many).1
    }
    #expect(many.senders["bank-z.example"]?.layouts.count == LearnedLayouts.layoutLimitPerSender)
  }

  @Test func corruptAnchorIndexDoesNotTrap() throws {
    var mem = LearnedLayouts()
    for i in 0..<3 {
      mem = CombinedReader.read(Mails.cardPurchaseEN(amount: "\(i + 1).00", merchant: "SAMPLE \(i)", at: Int64(i)), mem).1
    }
    var sender = try #require(mem.senders["bank-b.example"])
    sender.layouts[0].examples[0].tokens[0] = .anchor(9_999, spaceBefore: false, raw: nil)
    sender.layouts[0].examples[1].tokens[0] = .anchor(9_999, spaceBefore: true, raw: "x")
    mem.senders["bank-b.example"] = sender
    let trip = try JSONDecoder().decode(LearnedLayouts.self, from: try JSONEncoder().encode(mem))
    let (r, _) = CombinedReader.read(Mails.cardPurchaseEN(amount: "9.00", merchant: "SAMPLE NEW", at: 9), trip)
    #expect(r.amountMinor == 900)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(FillerToken.self, from: Data("[-4, true, \"x\"]".utf8)) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(FillerToken.self, from: Data("-4".utf8)) }
  }

  @Test func senderTokenBudgetHolds() {
    var mem = LearnedLayouts()
    let letters = Array("abcdefghij")
    for i in 0..<120 {
      let tag = String(String(i).map { letters[Int(String($0))!] })
      let words = (0..<300).map { "w" + tag + String(letters[$0 % 10]) + String($0) }
      let m = Mails.input(
        "bank-z.example", subject: "s\(i)", [words.joined(separator: " "), "Amount AED \(i + 1).00 debited"], at: Int64(i))
      mem = CombinedReader.read(m, mem).1
    }
    let sender = mem.layouts(for: "bank-z.example")
    #expect(LearnedReader.tokenCount(sender) <= LearnedLayouts.tokenBudgetPerSender)
    #expect(!sender.layouts.isEmpty)
  }

  @Test func notATransactionLeavesMemoryAlone() {
    let m = Mails.input(subject: "Your OTP", ["Your one time password for the purchase of AED 300.00 at SAMPLE STORE is 482913."])
    let (r, next) = CombinedReader.read(m, LearnedLayouts())
    #expect(r.outcome == .notTransaction)
    #expect(next.isEmpty)
  }

  @Test func exponentTableMatchesMinorExponentV1() {
    #expect(Exponent.of("KWD") == 3)
    #expect(Exponent.of("JPY") == 0)
    #expect(Exponent.of("USD") == 2)
    #expect(Exponent.of("aed") == 2)
  }

  @Test func tokenLimitBoundsEachExample() {
    let long = (0..<2_000).map { "word\($0)" }.joined(separator: " ")
    let m = Mails.input(subject: "s", ["Amount AED 5.00 debited", long])
    let mem = CombinedReader.read(m, LearnedLayouts()).1
    let layout = mem.senders["alerts.example"]?.layouts.first
    #expect((layout?.anchors.count ?? 0) <= LearnedLayouts.tokenLimitPerMail)
  }
}
