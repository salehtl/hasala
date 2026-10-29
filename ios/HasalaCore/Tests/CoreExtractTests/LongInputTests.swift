import Foundation
import Testing

@testable import CoreExtract

@Suite("Long inputs: the readers and the text gate stay fast on long runs")
struct LongInputTests {
  static let budget = Duration.seconds(3)

  static func timed(_ body: () -> Void) -> Duration {
    ContinuousClock().measure(body)
  }

  static func mail(_ text: String, subject: String = "Card transaction alert") -> ExtractInput {
    ExtractInput(sender: "alerts.example", subject: subject, text: text, receivedAtMs: 1_800_000_000_000, listUnsubscribe: false)
  }

  @Test("a long mask run in the body or the subject reads in bounded time", arguments: ["x", "*"])
  func maskRun(_ c: String) {
    let run = String(repeating: c, count: 200_000)
    let body = Self.mail("Amount: AED 10.00 debited\n" + run)
    let subject = Self.mail("Amount: AED 10.00 debited", subject: run)
    for m in [body, subject] {
      var r: ExtractReading?
      let d = Self.timed { r = CombinedReader.read(m, LearnedLayouts()).0 }
      #expect(d < Self.budget, "\(d)")
      #expect(r?.amountMinor == 1_000 && r?.currency == "AED")
      #expect(Self.timed { _ = CombinedReader.pending(m, direction: .debit) } < Self.budget)
    }
  }

  @Test("one long line of amounts reads in bounded time")
  func manyAmounts() {
    let m = Self.mail("Amount debited " + String(repeating: "AED 1 ", count: 20_000))
    let d = Self.timed {
      _ = CombinedReader.read(m, LearnedLayouts())
      _ = CombinedReader.aedAmount(m, foreign: 100, currency: "USD")
    }
    #expect(d < Self.budget, "\(d)")
  }

  @Test("a long digit or mask run in a text is gated in bounded time")
  func textGate() {
    let digits = String(repeating: "1", count: 16_000)
    let cases: [(String, Bool)] = [
      ("paid. " + digits, false),
      ("paid. " + digits + " x aed 1", true),
      ("paid. " + digits + " x درهم 1", true),
      ("paid. " + String(repeating: "x", count: 16_000), false),
      ("paid. " + String(repeating: "x", count: 16_000) + " 1234", true),
      ("paid. " + String(repeating: "1.", count: 8_000), false),
    ]
    for (text, shape) in cases {
      var got = false
      let d = Self.timed {
        let t = TextGate.Prepared(text)
        _ = TextGate.neverAPayment(t)
        _ = TextGate.notice(t)
        got = TextGate.hasPaymentShape(t, lenient: false)
        _ = TextGate.maskedLast4(t)
      }
      #expect(d < Self.budget, "\(d)")
      #expect(got == shape)
    }
  }

  @Test("the amount and masked-card shapes keep their meaning")
  func shapes() {
    let yes = [
      "paid aed 20", "paid aed20.00", "paid aed .5", "paid 20 aed", "paid 1,200.50aed", "paid .5 aed", "paid 20 درهم", "paid درهم 20",
      "paid with card xx1234", "paid with card **** 1234", "paid with card ##123", "paid with card 1234xx", "paid with card ending in 1234",
    ]
    let no = ["paid aed", "paid ., aed", "paid 20aedx", "paid x1234", "paid with card ending 12", "paid 20 dollars"]
    for t in yes { #expect(TextGate.hasPaymentShape(t, lenient: false), "\(t)") }
    for t in no { #expect(!TextGate.hasPaymentShape(t, lenient: false), "\(t)") }
    #expect(TextGate.maskedLast4("paid with card xxxx1234") == "1234")
    #expect(TextGate.maskedLast4("paid with card ending 98765") == nil)
  }

  @Test("a capped line or mail keeps whole scalars")
  func caps() {
    let long = String(repeating: "😀", count: 3_000)
    let line = RuleText.cleanLines(long)[0]
    #expect(line.utf16.count <= RuleText.maxLineUTF16 && line.unicodeScalars.allSatisfy { $0 == "😀" })
    let m = CombinedReader.bounded(Self.mail(long + String(repeating: "a", count: 70_000), subject: long))
    #expect(m.text.utf16.count <= CombinedReader.maxTextUTF16 && m.subject.utf16.count <= CombinedReader.maxSubjectUTF16)
    #expect(m.subject.unicodeScalars.allSatisfy { $0 == "😀" })
  }

  @Test("a long punctuation run around a word tokenizes in bounded time")
  func punctuationRun() {
    let run = String(repeating: "(", count: 100_000) + "word" + String(repeating: ")", count: 100_000)
    var interner = IInterner()
    var toks: [IToken] = []
    let d = Self.timed { toks = ITokenizer.tokenize(subject: "", text: run, interner: &interner, cap: 300_000) }
    #expect(d < Self.budget, "\(d)")
    let body = toks.filter { $0.line == 1 && $0.cls != .nl }
    #expect(body.count == 200_001)
    #expect(body[100_000].raw == "word" && body[100_000].cls == .word)
    #expect(body.prefix(100_000).allSatisfy { $0.raw == "(" && $0.cls == .punct })
    #expect(body.suffix(100_000).allSatisfy { $0.raw == ")" && $0.cls == .punct })
    let wrapped = Self.mail("Amount: AED 10.00 debited\n" + String(repeating: "\"", count: 30_000) + "x" + String(repeating: ".", count: 30_000))
    let d2 = Self.timed { _ = CombinedReader.read(wrapped, LearnedLayouts()) }
    #expect(d2 < Self.budget, "\(d2)")
  }

  @Test("the tokenizer splits leading and trailing punctuation as before")
  func punctuationSplit() {
    var interner = IInterner()
    let toks = ITokenizer.tokenize(subject: "", text: "(\"Paid\"), AED 12.50 at {Shop}. (((( )))) x", interner: &interner)
    let body = toks.filter { $0.line == 1 && $0.cls != .nl }
    #expect(body.map(\.raw) == [
      "(", "\"", "Paid", "\"", ")", ",", "AED", "12.50", "at", "{", "Shop", "}", ".",
      "(", "(", "(", "(", ")", ")", ")", ")", "x",
    ])
    #expect(body.map(\.cls) == [
      .punct, .punct, .word, .punct, .punct, .punct, .cur, .money, .word, .punct, .word, .punct, .punct,
      .punct, .punct, .punct, .punct, .punct, .punct, .punct, .punct, .word,
    ])
    #expect(body.map(\.spaceBefore) == [
      true, false, false, false, false, false, true, true, true, true, false, false, false,
      true, false, false, false, true, false, false, false, true,
    ])
  }
}
