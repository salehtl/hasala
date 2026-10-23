import Foundation
import CoreExtract
import Testing

@testable import ExtractBench

func reading(_ amount: Int64?, _ currency: String?, _ c: Double, direction: String? = "debit", merchant: String? = nil) -> Reading {
  Reading(
    isTransaction: true, amountMinor: amount, currency: currency, merchant: merchant, direction: direction, confidence: c)
}

func mail(_ lines: [String], subject: String = "Card transaction alert", sender: String = "bank-b.example", at: Int64 = 1_800_000_000_000) -> Mail {
  Mail(id: "m\(at)", origin: "synthetic", sender: sender, receivedAtMs: at, subject: subject, text: lines.joined(separator: "\n"), listUnsubscribe: false)
}

func purchase(_ amount: String, _ merchant: String, at: Int64) -> Mail {
  mail(
    [
      "Dear Customer,", "Your credit card ending with 7310 was used for a purchase.", "Amount", "AED \(amount)", "Merchant", merchant,
      "Available limit", "AED 12,000.00", "Regards,", "Bank B",
    ], at: at)
}

func purchaseAR(_ amount: String, _ merchant: String, at: Int64) -> Mail {
  mail(
    [
      "معاملة بطاقة ائتمان", "عزيزي المتعامل,", "إشعار مشتريات بتاريخ 01-02-2030 10:15 بالتفاصيل التالية.", "المبلغ", "AED \(amount)",
      "رقم البطاقة", "XXXX4821", "الدفع الى", merchant, "إجمالي الرصيد المتوفر", "AED 9,876.00", "مع اطيب التحيات،", "بنك أ",
    ], subject: "Bank A Notification", sender: "bank-a.example", at: at)
}

@Suite struct AdapterTests {
  @Test func rulesReadThroughCoreExtract() {
    let r = RulesReader().read(purchase("1,234.50", "SAMPLE SHOP", at: 1))
    #expect(r.isTransaction)
    #expect(r.amountMinor == 123_450)
    #expect(r.currency == "AED")
    #expect(r.direction == "debit")
    #expect(r.merchant == "SAMPLE SHOP")
  }

  @Test func chainHoldsAnUnlearnedLayoutAndFilesOnceLearned() {
    let c = ChainReader()
    let first = c.read(purchaseAR("10.00", "SAMPLE 0", at: 1))
    #expect(first.isTransaction)
    #expect(first.confidence < 0.8)
    var last = first
    for (i, amt) in ["20.00", "30.00", "40.00"].enumerated() { last = c.read(purchaseAR(amt, "SAMPLE \(i + 1)", at: Int64(i + 2))) }
    #expect(last.amountMinor == 4_000)
    #expect(last.confidence >= 0.8)
    c.reset()
    #expect(c.read(purchaseAR("50.00", "SAMPLE 5", at: 9)).confidence < 0.8)
  }

  @Test func chainDisregardsAPendingTransfer() {
    let m = mail(
      [
        "Dear Customer,", "Your fund transfer of AED 500.00 to SAMPLE PERSON is in process.", "Status", "Pending", "Regards,",
        "Bank B",
      ], subject: "Fund transfer")
    #expect(!ChainReader().read(m).isTransaction)
  }

  @Test func chainReadsTheAEDAmountOfATwoCurrencyMail() {
    let m = mail(
      [
        "Dear Customer,", "Here is the status of your Telegraphic Transfer.", "Debit Amount:", "AED 3,673.00", "Transaction Amount:",
        "USD 1,000.00", "Beneficiary Name:", "SAMPLE BROKER LLC", "Status:", "Success",
      ], subject: "Telegraphic Transfer", sender: "bank-d.example")
    let r = ChainReader().read(m)
    #expect(r.amountMinor == 367_300)
    #expect(r.currency == "AED")
  }

  @Test func aCurrencyNotInHundredthsHasNoAmount() {
    let r = RulesReader().read(mail(["Dear Customer,", "Your card ending 7310 was used for a purchase of JPY 1,200 at SAMPLE SHOP."]))
    #expect(r.currency == "JPY")
    #expect(r.amountMinor == nil)
  }
}

func enbdTransfer(status: String, at: Int64 = 1_800_000_000_000) -> Mail {
  mail(
    [
      "Dear Customer,", "Here is the status of your transfer.", "Debit Amount:", "AED 500.00", "Transaction Date:", "29/May/2026 06:29 PM",
      "Beneficiary Name:", "SAMPLE PERSON", "Status:", status,
    ], subject: "Fund transfer", sender: "emiratesnbd.com", at: at)
}

func enbd(_ line: String, at: Int64 = 1_800_000_000_000) -> Mail {
  mail([line], subject: "Transaction advice for your account ending with 8642", sender: "emiratesnbd.com", at: at)
}

func enbdForeign(usd: String = "12.50", aed: String = "45.91", at: Int64 = 1_800_000_000_000) -> Mail {
  enbd("USD\(usd) has been debited from your account 012XXX34XXX56. AED \(aed) debited in local currency.", at: at)
}

@Suite struct ChainTemplateTests {
  @Test func theFixturesHitATemplate() {
    let t = TemplateReader()
    #expect(t.read(enbdTransfer(status: "Pending")).isTransaction)
    #expect(t.read(enbdForeign()).isTransaction)
  }

  @Test func aPendingStatusTemplateHitIsDisregardedAndTeachesNothing() {
    let c = ChainReader()
    let r = c.read(enbdTransfer(status: "Pending"))
    #expect(!r.isTransaction)
    #expect(c.memory == LearnedLayouts())
    let done = c.read(enbdTransfer(status: "Success"))
    #expect(done.isTransaction && done.amountMinor == 50_000 && done.confidence == 1)
    #expect(c.memory != LearnedLayouts())
  }

  @Test func aPendingPhraseHoldsATemplateHit() {
    let c = ChainReader()
    let r = c.read(enbd("AED120.00 has been withdrawn from your account 012XXX34XXX56. Any remaining instalments will be processed as scheduled."))
    #expect(r.isTransaction && r.amountMinor == 12_000)
    #expect(r.confidence < 0.8)
    let plain = c.read(enbd("AED120.00 has been withdrawn from your account 012XXX34XXX56. Thank you.", at: 1_800_000_060_000))
    #expect(plain.confidence == 1)
  }

  @Test func theAEDAmountOfATemplateHitIsHeldUntilTheReadersConfirmIt() {
    let c = ChainReader()
    let first = c.read(enbdForeign())
    #expect(first.amountMinor == 4_591 && first.currency == "AED")
    #expect(first.confidence < 0.8)
    var last = first
    for i in 1..<6 { last = c.read(enbdForeign(usd: "\(12 + i).50", aed: "\(45 + i * 4).91", at: 1_800_000_000_000 + Int64(i) * 60_000)) }
    #expect(last.amountMinor == 6_591 && last.currency == "AED")
    #expect(last.confidence == 1)
  }
}

@Suite struct HeldOutTests {
  @Test func heldOutPhrasingsStayOutOfTheLexicons() {
    for (_, unseen) in HeldOut.rewordEn + HeldOut.rewordEnPhrases + HeldOut.rewordAr + HeldOut.rewordArPhrases {
      #expect(!ExtractLexicon.contains(unseen), "\(unseen)")
    }
  }

  @Test func heldOutPromoLinesStayOutOfThePromoFilter() {
    for line in HeldOut.promoEn + HeldOut.promoAr {
      #expect(!ExtractLexicon.isPromoLine(line.replacingOccurrences(of: "{n}", with: "250")), "\(line)")
    }
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
