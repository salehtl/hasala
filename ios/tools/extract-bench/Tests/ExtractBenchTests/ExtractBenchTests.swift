import Foundation
import Testing

@testable import ExtractBench

func reading(_ amount: Int64?, _ currency: String?, _ c: Double, direction: String? = "debit", merchant: String? = nil) -> Reading {
  Reading(
    isTransaction: true, amountMinor: amount, currency: currency, merchant: merchant, direction: direction, confidence: c)
}

@Suite struct GateTests {
  @Test func oneStrongReaderDoesNotLiftAWeakOne() {
    let out = Gate.combine(learned: reading(1000, "AED", 0.4), rules: reading(1000, "AED", 0.8))
    #expect(out.confidence < Gate.fileWithoutReview)
  }

  @Test func bothStrongReadersFile() {
    let out = Gate.combine(learned: reading(1000, "AED", 0.85), rules: reading(1000, "AED", 0.9))
    #expect(out.confidence >= Gate.fileWithoutReview)
    #expect(out.confidence == 0.85)
  }

  @Test func differentDirectionsAreHeld() {
    let out = Gate.combine(learned: reading(1000, "AED", 0.9, direction: "debit"), rules: reading(1000, "AED", 0.9, direction: "credit"))
    #expect(out.confidence < Gate.fileWithoutReview)
  }

  @Test func merchantComesFromTheLeadingReading() {
    let l = reading(1000, "AED", 0.82, merchant: "CURRENT ACCOUNT")
    let r = reading(1000, "AED", 0.9, merchant: "SAMPLE SHOP")
    #expect(Gate.combine(learned: l, rules: r).merchant == "SAMPLE SHOP")
    let r2 = reading(1000, "AED", 0.9, merchant: nil)
    #expect(Gate.combine(learned: l, rules: r2).merchant == "CURRENT ACCOUNT")
  }

  @Test func templateWithANonISOCurrencyIsHeld() {
    let t = reading(1000, "DHS", 1)
    #expect(Gate.checkTemplate(t, learned: .none, rules: .none).confidence < Gate.fileWithoutReview)
  }

  @Test func templateContradictedByAReaderIsHeld() {
    let t = reading(20000, "AED", 1)
    let out = Gate.checkTemplate(t, learned: reading(20000, "AED", 0.9), rules: reading(10000, "AED", 0.6))
    #expect(out.confidence < Gate.fileWithoutReview)
  }

  @Test func templateConfirmedOrUnreadStaysConfident() {
    let t = reading(20000, "AED", 1)
    #expect(Gate.checkTemplate(t, learned: reading(20000, "AED", 0.9), rules: .none).confidence == 1)
    #expect(Gate.checkTemplate(t, learned: .none, rules: .none).confidence == 1)
  }
}

@Suite struct PromoFilterTests {
  @Test(arguments: [
    "Purchase of AED 250.00 at SAMPLE DUTY FREE SHOP",
    "Purchase of AED 250.00 at SAMPLE LEARNING CENTRE",
    "Purchase of AED 250.00 at DARWIN SAMPLE CAFE",
    "AED 250.00 SAMPLE POINTSHOP",
    "شراء بمبلغ 250.00 درهم لدى معرض العينة",
    "Transaction of AED 99.00 debited at SAMPLE REWARDS CAFE",
  ])
  func keepsTransactionLines(_ line: String) {
    #expect(!PromoFilter.isPromo(line))
  }

  @Test(arguments: [
    "Earn AED 500 cashback when you shop with your card this month.",
    "Get up to AED 200 on your next booking.",
    "Win AED 1,000 in our monthly draw.",
    "Enjoy 20% off at partner stores.",
    "اربح استرداد نقدي بقيمة 500 درهم عند التسوق هذا الشهر.",
    "احصل على 300 نقطة عند التسوق.",
  ])
  func dropsPromoLines(_ line: String) {
    #expect(PromoFilter.isPromo(line))
  }
}

@Suite struct HundredthsTests {
  @Test func bothReadersAgreeOnIDR() {
    #expect(ITokenizer.minor("150,000.00", currency: "IDR") == 15_000_000)
    #expect(RuleMoneyParser.scan("IDR 150,000.00", line: 0, labelCurrency: nil).first?.minor == 15_000_000)
  }

  @Test func bothReadersUseHundredthsForEveryCurrency() {
    #expect(ITokenizer.minor("1,200", currency: "JPY") == 120_000)
    #expect(RuleMoneyParser.scan("JPY 1,200", line: 0, labelCurrency: nil).first?.minor == 120_000)
  }

  @Test func aCurrencyNotInHundredthsIsHeld() {
    let out = Gate.combine(learned: reading(120_000, "JPY", 0.9), rules: reading(120_000, "JPY", 0.9))
    #expect(out.confidence < Gate.fileWithoutReview)
  }
}

@Suite struct ScoreTests {
  func score(_ r: Reading, _ t: Truth) -> Tally {
    var a = Tally()
    var m: [Miss] = []
    Score.add(r, t, into: &a, misses: &m, reader: "x", kind: "k", id: "i")
    return a
  }

  @Test func wrongDirectionIsConfidentlyWrong() {
    let t = Truth(isTransaction: true, amountMinor: 1000, currency: "AED", merchant: nil, direction: "credit")
    let a = score(reading(1000, "AED", 0.9, direction: "debit"), t)
    #expect(a.directionWrong == 1)
    #expect(a.confidentWrong == 1)
  }

  @Test func inventedMerchantIsCounted() {
    let t = Truth(isTransaction: true, amountMinor: 1000, currency: "AED", merchant: nil, direction: "debit")
    let a = score(reading(1000, "AED", 0.9, merchant: "Footer"), t)
    #expect(a.merchantNoneWrong == 1)
    #expect(a.confidentWrongMerchant == 1)
    #expect(a.confidentWrong == 0)
  }

  @Test func rightReadingIsNotWrong() {
    let t = Truth(isTransaction: true, amountMinor: 1000, currency: "AED", merchant: "SAMPLE SHOP", direction: "debit")
    let a = score(reading(1000, "AED", 0.9, merchant: "SAMPLE SHOP"), t)
    #expect(a.confidentWrong == 0 && a.confidentWrongMerchant == 0 && a.directionRight == 1)
  }
}

@Suite struct TemplateReaderTests {
  @Test func appliesTheAppsFieldGates() {
    #expect(TemplateReader.usable(amountMinor: 100, currency: "AED", direction: "debit", postedAt: ""))
    #expect(TemplateReader.usable(amountMinor: 100, currency: "AED", direction: "credit", postedAt: "2026-06-05T07:41:00Z"))
    #expect(!TemplateReader.usable(amountMinor: 0, currency: "AED", direction: "debit", postedAt: ""))
    #expect(!TemplateReader.usable(amountMinor: 100, currency: "AED", direction: "", postedAt: ""))
    #expect(!TemplateReader.usable(amountMinor: 100, currency: "aed", direction: "debit", postedAt: ""))
    #expect(!TemplateReader.usable(amountMinor: 100, currency: "AED", direction: "debit", postedAt: "not a date"))
  }

  @Test func lowercasesDomains() {
    #expect(TemplateReader.asciiLower("Alerts.Example.AE") == "alerts.example.ae")
  }
}

@Suite struct CorpusTests {
  @Test func pendingCasesAreNotTransactions() {
    #expect(Corpus.isNotTransaction("dib.transfer.v1/pending"))
    #expect(Corpus.isNotTransaction("dib.transfer.v1/rendered-pending"))
    #expect(Corpus.isNotTransaction("dib.account.v1/notice-rendered-in-progress"))
    #expect(Corpus.isNotTransaction("dib.money-transfer.v1/other-status"))
    #expect(!Corpus.isNotTransaction("adib.alert.v1/amount-without-decimals"))
  }

  @Test func syntheticLoadIncludesNonTransactions() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../conformance/templates")
      .standardizedFileURL.path
    let items = try Corpus.loadSynthetic(dir)
    #expect(items.contains { !$0.1.isTransaction })
    #expect(items.contains { $0.1.isTransaction })
  }

  @Test func badLabelsThrow() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("eb-labels-\(UUID().uuidString).json")
    try Data(#"{"a.eml":{"isTransaction":true,"amountMinor":"12"}}"#.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: (any Error).self) { try Corpus.loadLabels(url.path) }
  }
}
