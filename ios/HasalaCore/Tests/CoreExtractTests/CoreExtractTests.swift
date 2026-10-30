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
    #expect(!json.contains("sample"))
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

@Suite struct TemplateVerdictTests {
  let foreign = Mails.input(
    "bank-c.example", subject: "Transaction advice",
    ["USD12.50 has been debited from your account 012XXX34XXX56. AED 45.91 debited in local currency."])

  @Test func aPendingStatusIsDisregardedBeforeTheReadersRun() {
    var ran = false
    let v = CombinedReader.templateVerdict(
      Mails.transferAR(amount: "500.00", status: "قيد التنفيذ"), amountMinor: 50_000, currency: "AED", direction: .debit
    ) {
      ran = true
      return nil
    }
    #expect(v == nil)
    #expect(!ran)
  }

  @Test func theAEDAmountIsHeldUnlessTheReadersConfirmIt() {
    let unconfirmed = CombinedReader.templateVerdict(foreign, amountMinor: 1_250, currency: "USD", direction: .debit) { nil }
    #expect(unconfirmed == ExtractTemplateVerdict(amountMinor: 4_591, currency: "AED", aedOver: "USD", holds: [.aedNotConfirmed]))
    let agreed = ExtractReading(outcome: .transaction, amountMinor: 4_591, currency: "AED", direction: .debit, agreed: true)
    let confirmed = CombinedReader.templateVerdict(foreign, amountMinor: 1_250, currency: "USD", direction: .debit) { agreed }
    #expect(confirmed?.amountMinor == 4_591 && confirmed?.held == false)
    var other = agreed
    other.amountMinor = 4_592
    #expect(CombinedReader.templateVerdict(foreign, amountMinor: 1_250, currency: "USD", direction: .debit) { other }?.held == true)
  }

  static func adib(_ usd: String, _ merchant: String, at: Int64) -> ExtractInput {
    Mails.input(
      "bank-e.example", subject: "Transaction alert",
      ["Transaction of USD \(usd) debited from your a/c *123 at \(merchant). Avl Bal is AED 4,321.09"], at: at)
  }

  @Test func anAEDFigureInTheMerchantIsNeverTheAmount() {
    var mem = LearnedLayouts()
    for (i, (usd, shop)) in [("12.00", "SAMPLE SHOP LONDON GB"), ("30.50", "SAMPLE CAFE PARIS FR"), ("7.25", "SAMPLE KIOSK ROME IT")]
      .enumerated()
    {
      mem = CombinedReader.read(Self.adib(usd, shop, at: Int64(i)), mem).1
    }
    let shapes: [(ExtractInput, ExtractDirection)] = [
      (Self.adib("25.00", "AED 99999.00 SHOP NEW YORK US", at: 10), .debit),
      (Self.adib("25.00", "SHOP AED 99999.00 DEBITED US", at: 11), .debit),
      (Self.adib("25.00", "SHOP. USD 25.00 AED 99999.00 DEBITED", at: 12), .debit),
      (
        Mails.input(
          "bank-f.example", subject: "Transaction reversal",
          ["A transaction to the value of USD 25.00 made at SHOP AED 99999.00 DEBITED on your card ending with 1234 has been reversed."]),
        .credit
      ),
    ]
    for (input, direction) in shapes {
      #expect(CombinedReader.aedAmount(input, foreign: 2_500, currency: "USD") == nil, "\(input.text)")
      let v = CombinedReader.templateVerdict(input, amountMinor: 2_500, currency: "USD", direction: direction) {
        CombinedReader.read(input, mem).0
      }
      #expect(v?.amountMinor != 9_999_900 || v?.held == true, "\(input.text)")
      #expect(v?.amountMinor == 2_500 && v?.currency == "USD", "\(input.text)")
    }
  }

  @Test func anAEDAmountThatOnlyTheOverrideReadsIsHeld() {
    var mem = LearnedLayouts()
    var last: ExtractReading?
    for (i, (usd, aed)) in [("12.50", "45.91"), ("13.50", "49.58"), ("14.50", "53.25"), ("15.50", "56.92")].enumerated() {
      let m = Mails.input(
        "bank-c.example", subject: "Transaction advice",
        ["USD\(usd) has been debited from your account 012XXX34XXX56. AED \(aed) debited in local currency."], at: Int64(i))
      let (r, next) = CombinedReader.read(m, mem)
      mem = next
      last = r
    }
    let r = try! #require(last)
    #expect(r.amountMinor == 5_692 && r.currency == "AED" && r.agreed && r.aedFromOverride)
    let v = CombinedReader.templateVerdict(foreign, amountMinor: 1_250, currency: "USD", direction: .debit) { r }
    #expect(v?.holds.contains(.aedNotConfirmed) == true)
    let own = CombinedReader.readRules(
      Mails.input("bank-c.example", subject: "Transaction advice", ["Debited AED 45.91 in local currency for your card purchase."]))
    #expect(own.currency == "AED" && !own.aedFromOverride)
  }

  @Test func anAEDTemplateHitKeepsItsAmount() {
    let v = CombinedReader.templateVerdict(
      Mails.cardPurchaseEN(amount: "12.00", merchant: "SAMPLE SHOP"), amountMinor: 1_200, currency: "AED", direction: .debit
    ) { nil }
    #expect(v == ExtractTemplateVerdict(amountMinor: 1_200, currency: "AED"))
  }

  @Test func aPendingPhraseHoldsATemplateHit() {
    let input = Mails.input(
      "bank-c.example", subject: "Transaction advice",
      ["AED120.00 has been withdrawn from your account 012XXX34XXX56. Any remaining instalments will be processed as scheduled."])
    let v = CombinedReader.templateVerdict(input, amountMinor: 12_000, currency: "AED", direction: .debit) { nil }
    #expect(v?.holds == [.pendingPhrase])
  }
}

@Suite struct UsableReadingTests {
  @Test func aUsableReadingHasAnAmountInRangeACurrencyAndADirection() {
    let ok = ExtractReading(outcome: .transaction, amountMinor: 100, currency: "AED", direction: .debit)
    #expect(ok.isUsable)
    for bad in [
      ExtractReading(outcome: .transaction, amountMinor: 0, currency: "AED", direction: .debit),
      ExtractReading(outcome: .transaction, amountMinor: ExtractReading.maxAmountMinor + 1, currency: "AED", direction: .debit),
      ExtractReading(outcome: .transaction, amountMinor: 100, currency: "aed", direction: .debit),
      ExtractReading(outcome: .transaction, amountMinor: 100, currency: "AED"),
      ExtractReading(outcome: .transaction, currency: "AED", direction: .debit),
    ] {
      #expect(!bad.isUsable)
    }
    #expect(ExtractReading.usableAmount(ExtractReading.maxAmountMinor, currency: "USD"))
  }
}

@Suite struct ExtractLexiconTests {
  @Test func knowsItsOwnPhrases() {
    #expect(ExtractLexicon.contains("Merchant"))
    #expect(ExtractLexicon.contains("Transaction of"))
    #expect(ExtractLexicon.contains("  Dear "))
    #expect(ExtractLexicon.contains("الحالة"))
    #expect(!ExtractLexicon.contains("Dear Customer Service"))
    #expect(!ExtractLexicon.contains("Shopfront"))
  }

  @Test func knowsAPromoLine() {
    #expect(ExtractLexicon.isPromoLine("Enjoy 20% off dining, up to AED 50."))
    #expect(!ExtractLexicon.isPromoLine("AED 10.00 was debited."))
    #expect(!ExtractLexicon.isPromoLine(""))
  }
}

@Suite struct FilingGateTests {
  func reading(_ amount: Int64, _ conf: Int, _ cur: String = "AED", direction: String = "debit", guessed: Bool = false) -> Reading {
    Reading(
      isTransaction: true, amountMinor: amount, currency: cur, currencyExplicit: true, direction: direction,
      directionGuessed: guessed, fromLayout: true, confidence: conf)
  }

  func confirmed(rules: Int = 85, learned: Int = 85, agree: Bool = true) -> ExtractReading {
    ExtractReading(
      outcome: .transaction, amountMinor: 1_000, currency: "AED", direction: .debit, confidencePercent: 90, agreed: true,
      rulesConfidencePercent: rules, learnedConfidencePercent: learned, readersAgree: agree)
  }

  @Test func theReadersAgreeOnlyOnTheSameAmountCurrencyAndStatedDirection() {
    #expect(CombinedReader.readersAgree(reading(100, 90), reading(100, 85)))
    #expect(!CombinedReader.readersAgree(reading(100, 90), reading(101, 85)))
    #expect(!CombinedReader.readersAgree(reading(100, 90), reading(100, 85, "USD")))
    #expect(!CombinedReader.readersAgree(reading(100, 90), reading(100, 85, direction: "credit")))
    #expect(!CombinedReader.readersAgree(reading(100, 90), reading(100, 85, guessed: true)))
    #expect(!CombinedReader.readersAgree(reading(100, 90), .none))
  }

  @Test func eachReaderMustReachTheBarOnItsOwn() {
    #expect(confirmed().meetsFilingBar)
    #expect(confirmed(rules: 80, learned: 80).meetsFilingBar)
    #expect(!confirmed(rules: 79).meetsFilingBar)
    #expect(!confirmed(learned: 79).meetsFilingBar)
    #expect(!confirmed(agree: false).meetsFilingBar)
    var low = confirmed()
    low.confidencePercent = 70
    #expect(low.readersConfirm && !low.meetsFilingBar)
  }

  @Test func anOverriddenAmountOrAHeldPendingWordingNeverMeetsTheBar() {
    var overridden = confirmed()
    overridden.aedOverrideUsed = true
    #expect(overridden.readersConfirm && !overridden.meetsFilingBar)
    var held = confirmed()
    held.pendingWordingHeld = true
    #expect(held.readersConfirm && !held.meetsFilingBar)
  }

  @Test func aFirstMailOfAnUnlearnedLayoutNeverFiles() {
    var mem = LearnedLayouts()
    var readings: [ExtractReading] = []
    for (i, amt) in ["10.00", "20.00", "30.00", "40.00", "50.00", "60.00"].enumerated() {
      let (r, next) = CombinedReader.read(Mails.cardPurchaseAR(amount: amt, merchant: "SAMPLE \(i)", at: Int64(i)), mem)
      mem = next
      readings.append(r)
    }
    #expect(!readings[0].meetsFilingBar && readings[0].learnedConfidencePercent < ExtractReading.agreementBarPercent)
    #expect(readings[0].rulesConfidencePercent > 0)
    let last = readings[5]
    #expect(last.meetsFilingBar, "\(last)")
    #expect(last.readersAgree && last.rulesConfidencePercent >= 80 && last.learnedConfidencePercent >= 80)
  }

  @Test func aTemplateHitThatConfidentReadersContradictIsHeld() {
    let input = Mails.cardPurchaseEN(amount: "10.00", merchant: "SAMPLE SHOP")
    let sure = confirmed()
    let v = CombinedReader.templateVerdict(input, amountMinor: 100, currency: "AED", direction: .debit) { sure }
    #expect(v == ExtractTemplateVerdict(amountMinor: 100, currency: "AED", holds: [.readersDisagree]))
    var otherCurrency = sure
    otherCurrency.amountMinor = 100
    otherCurrency.currency = "SAR"
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 100, currency: "AED", direction: .debit) { otherCurrency }?.holds
        == [.readersDisagree])
    #expect(CombinedReader.templateVerdict(input, amountMinor: 1_000, currency: "AED", direction: .debit) { sure }?.held == false)
  }

  @Test func aTemplateDirectionThatConfidentReadersContradictIsHeld() {
    let input = Mails.cardPurchaseEN(amount: "10.00", merchant: "SAMPLE SHOP")
    var credit = confirmed()
    credit.direction = .credit
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_000, currency: "AED", direction: .debit) { credit }
        == ExtractTemplateVerdict(amountMinor: 1_000, currency: "AED", holds: [.readersDisagree]))
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_000, currency: "AED", direction: .credit) { credit }?.held
        == false)
    var unsure = credit
    unsure.learnedConfidencePercent = 79
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_000, currency: "AED", direction: .debit) { unsure }?.held
        == false)
  }

  @Test func readersThatDidNotCombineDoNotConfirm() {
    var unagreed = confirmed()
    unagreed.agreed = false
    #expect(!unagreed.readersConfirm)
    let input = Mails.cardPurchaseEN(amount: "10.00", merchant: "SAMPLE SHOP")
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_000, currency: "USD", direction: .debit) { unagreed }?.holds
        .contains(.readersDisagree) == false)
  }

  @Test func readersBelowTheBarDoNotOverruleATemplate() {
    let input = Mails.cardPurchaseEN(amount: "10.00", merchant: "SAMPLE SHOP")
    for unsure in [confirmed(rules: 70), confirmed(learned: 79), confirmed(agree: false)] {
      #expect(
        CombinedReader.templateVerdict(input, amountMinor: 100, currency: "AED", direction: .debit) { unsure }
          == ExtractTemplateVerdict(amountMinor: 100, currency: "AED"))
    }
  }
}

@Suite struct TemplateCurrencyTests {
  @Test func dhsReadsAsAED() {
    #expect(ExtractCurrency.iso("DHS") == "AED")
    #expect(ExtractCurrency.iso("AED") == "AED")
  }

  @Test func onlyActiveISOCodesAreKnown() {
    for s in ["USD", "SAR", "MOP", "BND", "KHR", "DZD", "XCD", "BAM", "RSD", "MNT", "BYN", "DOP"] {
      #expect(ExtractCurrency.iso(s) == s, "\(s)")
    }
    for s in ["XYZ", "CNH", "XAU", "XDR", "XTS", "XXX", "HRK", "sar", "US$", ""] {
      #expect(ExtractCurrency.iso(s) == nil, "\(s)")
    }
  }

  @Test func theRuleReadersCodesAreNotTheFilingList() {
    let notISO = RuleMoneyParser.codes.subtracting(ExtractCurrency.isoCodes)
    #expect(notISO == ["CNH"])
  }

  @Test func aTemplateCurrencyIsNormalizedOrHeld() {
    let input = Mails.cardPurchaseEN(amount: "12.00", merchant: "SAMPLE SHOP")
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_200, currency: "DHS", direction: .debit) { nil }
        == ExtractTemplateVerdict(amountMinor: 1_200, currency: "AED"))
    #expect(
      CombinedReader.templateVerdict(input, amountMinor: 1_200, currency: "XYZ", direction: .debit) { nil }
        == ExtractTemplateVerdict(amountMinor: 1_200, currency: "XYZ", holds: [.currencyNotISO]))
  }
}

@Suite struct LayoutPrivacyTests {
  static let markers = ["synthmarker99", "syntheticname", "4321987", "77.77", "sample bookshop", "bookshop"]

  static func mail(_ i: Int) -> ExtractInput {
    Mails.input(
      "bank-p.example", subject: "Account activity",
      [
        "Dear Syntheticname,", "AED \(10 + i).50 was debited at SAMPLE BOOKSHOP \(i).", "Reference SYNTHMARKER99 4321987",
        "Available balance AED 77.77",
      ], at: Int64(i))
  }

  static func encoded(_ mem: LearnedLayouts) throws -> String {
    String(decoding: try JSONEncoder().encode(mem), as: UTF8.self).lowercased()
  }

  @Test func aLayoutHoldsNoMailText() throws {
    var mem = LearnedLayouts()
    for i in 0..<6 {
      mem = CombinedReader.read(Self.mail(i), mem).1
      let json = try Self.encoded(mem)
      for marker in Self.markers { #expect(!json.contains(marker), "\(marker) after \(i + 1)") }
    }
  }

  @Test func aSavedLayoutReadsTheSameAsOneInMemory() throws {
    var live = LearnedLayouts()
    var saved = LearnedLayouts()
    for i in 0..<8 {
      let m = Mails.cardPurchaseEN(amount: "\(i + 3).00", merchant: "SAMPLE \(["A", "B", "C", "D"][i % 4])", at: Int64(i))
      let (a, nextLive) = CombinedReader.read(m, live)
      let (b, nextSaved) = CombinedReader.read(m, saved)
      #expect(a == b)
      live = nextLive
      saved = try JSONDecoder().decode(LearnedLayouts.self, from: try JSONEncoder().encode(nextSaved))
    }
    #expect(live == saved)
  }

  @Test func aSavedLayoutStillFilesAndNamesTheMerchantOfTheNewMail() throws {
    var mem = LearnedLayouts()
    for i in 0..<5 {
      mem = CombinedReader.read(Mails.cardPurchaseAR(amount: "\(i + 3).00", merchant: "SAMPLE \(["A", "B", "C", "D", "E"][i])", at: Int64(i)), mem).1
      mem = try JSONDecoder().decode(LearnedLayouts.self, from: try JSONEncoder().encode(mem))
    }
    let r = CombinedReader.read(Mails.cardPurchaseAR(amount: "9.00", merchant: "SAMPLE NEW", at: 9), mem).0
    #expect(r.meetsFilingBar && r.amountMinor == 900 && r.merchant == "SAMPLE NEW", "\(r)")
  }

  @Test func aMerchantThatNeverChangesStaysCapped() throws {
    var mem = LearnedLayouts()
    var last: ExtractReading?
    for i in 0..<6 {
      let (r, next) = CombinedReader.read(Mails.cardPurchaseEN(amount: "\(i + 3).00", merchant: "SAMPLE A", at: Int64(i)), mem)
      last = r
      mem = try JSONDecoder().decode(LearnedLayouts.self, from: try JSONEncoder().encode(next))
    }
    let once = CombinedReader.read(Mails.cardPurchaseEN(amount: "9.00", merchant: "SAMPLE A", at: 9), mem).0
    #expect(once.learnedConfidencePercent == last?.learnedConfidencePercent)
  }

  @Test func aWordTagIsStableAndWideEnoughToAlign() {
    #expect(LayoutCodec.shapeKey("bookshop", .word) == LayoutCodec.shapeKey(LayoutCodec.shapeKey("bookshop", .word), .word))
    #expect(LayoutCodec.shapeKey("amount", .word) == "amount")
    #expect(LayoutCodec.shapeKey("12.50", .money) == LayoutCodec.valueShape)
    #expect(LayoutCodec.isWordTag(LayoutCodec.wordTag("bookshop")))
    #expect(!LayoutCodec.isWordTag("#bookshop"))
  }
}

@Suite struct AmountBoundsTests {
  @Test func aTokenTooLargeForTheIntegerIsUnreadable() {
    #expect(ITokenizer.minor("92233720368547758.08", currency: "AED") == nil)
    #expect(ITokenizer.minor("9223372036854775.808", currency: "BHD") == nil)
    #expect(ITokenizer.minor("92233720368547758.07", currency: "AED") == Int64.max)
    #expect(ITokenizer.minor("92233720368547759.00", currency: "AED") == nil)
  }

  @Test func aReadingOfATooLargeTokenDoesNotStop() {
    let m = Mails.input("bank-t.example", subject: "", ["AED 92233720368547758.08 paid at SHOP."])
    #expect(CombinedReader.read(m, LearnedLayouts()).0.amountMinor != Int64.max)
  }
}

@Suite struct FilingAmountTests {
  static func thread(_ lines: (Int) -> [String], count: Int = 6) -> [ExtractReading] {
    var mem = LearnedLayouts()
    return (0..<count).map { i in
      let (r, next) = CombinedReader.read(Mails.input("bank-f.example", subject: "Account activity", lines(i), at: Int64(i)), mem)
      mem = next
      return r
    }
  }

  @Test func anAEDAmountFromTheOverrideDoesNotFile() throws {
    let last = try #require(
      Self.thread { ["USD\($0 + 12).50 has been debited from your account 012XXX34XXX56. AED \($0 + 45).91 debited in local currency."] }.last)
    #expect(last.currency == "AED" && last.aedOverrideUsed, "\(last)")
    #expect(!last.meetsFilingBar)
  }

  @Test func anAEDAmountBothReadersReadThemselvesFiles() throws {
    let last = try #require(Self.thread { ["Your purchase of AED \($0 + 45).91 was debited from your account 012XXX34XXX56.", "Thank you."] }.last)
    #expect(last.currency == "AED" && !last.aedOverrideUsed && last.meetsFilingBar, "\(last)")
  }

  @Test func aSecondLabelledAmountOnANewLayoutDoesNotFile() throws {
    let readings = Self.thread {
      ["AED \($0 + 1).00 has been credited to your account XXXX1234.", "Remarks: amount AED 5,000.00 debited"]
    }
    for r in readings { #expect(!r.meetsFilingBar, "\(r)") }
    #expect(try #require(readings.last).learnedConfidencePercent <= 60)
  }

  @Test func aDescriptorAmountBesideAForeignAmountDoesNotFile() {
    let readings = Self.thread { ["USD \($0 + 10).50 has been debited from your account 012XXX34XXX56 at AMOUNT DEBITED AED 1.00 SHOP.", "Thank you"] }
    for r in readings { #expect(!r.meetsFilingBar, "\(r)") }
  }

  @Test func aBalanceOrAFeeBesideTheAmountStillFiles() throws {
    let last = try #require(
      Self.thread { ["Your purchase of AED \($0 + 45).91 was debited from your account 012XXX34XXX56.", "Fee AED 2.00", "Available balance AED 900.00"] }.last)
    #expect(last.amountMinor != nil && last.meetsFilingBar, "\(last)")
  }

  @Test func theSameAmountStatedTwiceStillFiles() throws {
    let last = try #require(
      Self.thread { ["Amount AED \($0 + 45).91 debited from your account 012XXX34XXX56.", "Total debited amount AED \($0 + 45).91"] }.last)
    #expect(last.meetsFilingBar, "\(last)")
  }
}

@Suite struct PendingHoldTests {
  static let withdrawal = "AED 120.00 has been withdrawn from your account 012XXX34XXX56."

  @Test func aPendingPhraseOutsideATransferHoldsTheReading() {
    let m = Mails.input("bank-c.example", subject: "Advice", [Self.withdrawal + " Any remaining instalments will be processed as scheduled."])
    let r = CombinedReader.read(m, LearnedLayouts()).0
    #expect(r.outcome == .transaction && r.amountMinor == 12_000 && r.pendingWordingHeld && !r.meetsFilingBar)
  }

  @Test func aPendingStatusOutsideATransferHoldsTheReading() {
    let m = Mails.input("bank-c.example", subject: "Debit alert", [Self.withdrawal, "Status: Pending"])
    let r = CombinedReader.read(m, LearnedLayouts()).0
    #expect(r.outcome == .transaction && r.pendingWordingHeld && !r.meetsFilingBar)
  }

  @Test func aTransferWithTwoStatusesIsHeldNotSetAside() {
    let m = Mails.input("bank-c.example", subject: "Money Transfer", ["Transfer Amount: AED 250.00", "Status: Pending", "Transaction Status: Completed"])
    let r = CombinedReader.read(m, LearnedLayouts()).0
    #expect(r.outcome == .transaction && r.pendingWordingHeld)
    let v = CombinedReader.templateVerdict(m, amountMinor: 25_000, currency: "AED", direction: .debit) { nil }
    #expect(v?.holds == [.pendingStatus])
  }

  @Test func aPendingTransferStaysOut() {
    let m = Mails.input("bank-c.example", subject: "Money Transfer", ["Transfer Amount: AED 250.00", "Status: Pending"])
    #expect(CombinedReader.read(m, LearnedLayouts()).0.outcome == .pending)
    #expect(CombinedReader.templateVerdict(m, amountMinor: 25_000, currency: "AED", direction: .debit) { nil } == nil)
  }

  @Test func aStatusLineTheTemplateCapturedIsHeldNotSetAside() {
    let m = Mails.input("bank-c.example", subject: "Notification", ["Purchase of AED 25.00", "TRANSFER STATUS:QUEUED"])
    #expect(CombinedReader.templateVerdict(m, amountMinor: 2_500, currency: "AED", direction: .debit) { nil } == nil)
    let v = CombinedReader.templateVerdict(m, amountMinor: 2_500, currency: "AED", direction: .debit, captured: "TRANSFER STATUS:QUEUED") { nil }
    #expect(v?.holds == [.pendingStatus])
  }
}
