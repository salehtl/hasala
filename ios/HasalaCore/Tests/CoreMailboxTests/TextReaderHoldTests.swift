import CoreExtract
import Foundation
import Testing

@testable import CoreMailbox

@Suite("bank texts: reader agreement holds and payment shapes")
struct TextReaderHoldTests {
  static func stream(_ make: (Int) -> String) -> [(BankTextReading, ExtractReading)] {
    var layouts = LearnedLayouts()
    var out: [(BankTextReading, ExtractReading)] = []
    for n in 0..<8 {
      let at = TextRig.t0 + Int64(n) * 3_600_000
      let text = make(n)
      let input = ExtractInput(
        sender: "sms:", subject: "", text: BankTextReader.normalized(text), receivedAtMs: at, listUnsubscribe: false)
      let (reading, _) = CombinedReader.read(input, layouts)
      let (r, next) = BankTextReader.read(BankTextArrival(text: text, sender: nil, receivedAtMs: at), templates: [], layouts: layouts)
      layouts = next
      out.append((r, reading))
    }
    return out
  }

  static func amount(_ n: Int) -> String { "\(40 + n * 11).\(String(format: "%02d", (n * 17) % 100))" }

  static func files(_ r: BankTextReading) -> Bool {
    guard let k = r.kept else { return false }
    return BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false)
  }

  @Test("a plain debit from the account files once the readers agree, so the holds below are not vacuous")
  func controlFiles() throws {
    let s = Self.stream { "AED \(Self.amount($0)) has been debited from your account XXX4321 at SAMPLE SHOP on 05-06-2026." }
    #expect(s.allSatisfy { $0.0.kept?.fields?.direction == "debit" })
    #expect(s.contains { Self.files($0.0) })
  }

  @Test("money transferred, credited or deposited to your account reads as a credit, never a debit")
  func transferredToYourAccountIsCredit() throws {
    let wordings = [
      { (n: Int) in "AED \(Self.amount(n)) has been transferred to your account XXX4321. The available balance is AED 9,876.00." },
      { (n: Int) in "AED \(Self.amount(n)) has been credited to your account XXX4321. Available balance AED 9,876.00." },
      { (n: Int) in "AED \(Self.amount(n)) has been deposited into your savings account XXX4321 on 05-06-2026." },
    ]
    for w in wordings {
      let s = Self.stream(w)
      for (r, reading) in s {
        let f = try #require(r.kept?.fields, "\(w(0))")
        #expect(f.direction == "credit", "\(w(0))")
        #expect(!reading.directionAmbiguous, "\(w(0))")
      }
    }
  }

  @Test("a debit that rests only on transfer, transferred or sent never files through reader agreement")
  func ambiguousDirectionHolds() throws {
    let wordings = [
      { (n: Int) in "AED \(Self.amount(n)) transferred to SAMPLE PERSON on 05-06-2026 10:15. Ref SYN\(3000 + n)." },
      { (n: Int) in "You sent AED \(Self.amount(n)) to SAMPLE PERSON on 05-06-2026. Ref SYN\(3100 + n)." },
      { (n: Int) in "Transfer of AED \(Self.amount(n)) to SAMPLE PERSON on 05-06-2026 done. Ref SYN\(3200 + n)." },
    ]
    for w in wordings {
      let s = Self.stream(w)
      #expect(s.contains { $0.1.directionAmbiguous && $0.1.direction == .debit }, "\(w(0))")
      for (r, reading) in s {
        #expect(!reading.meetsFilingBar, "\(w(0))")
        #expect(r.kept != nil && r.kept?.readerConfident == false && !Self.files(r), "\(w(0))")
      }
    }
  }

  @Test("a credit to your account elsewhere in the text does not turn a purchase into a credit")
  func cashbackLineKeepsPurchaseADebit() throws {
    let s = Self.stream {
      "Purchase of AED \(Self.amount($0)) at SAMPLE SHOP with card XXX4321 on 05-06-2026. Cashback of AED 1.20 will be credited to your account."
    }
    #expect(s.allSatisfy { $0.0.kept?.fields?.direction == "debit" && $0.1.direction == .debit })
  }

  @Test("an ambiguous direction keeps the readers' check on a template's amount")
  func ambiguousDirectionStillChecksTemplates() throws {
    let input = ExtractInput(
      sender: "sms:", subject: "", text: BankTextReader.normalized("AED 1,000.00 transferred to SAMPLE PERSON on 05-06-2026."),
      receivedAtMs: TextRig.t0, listUnsubscribe: false)
    var reading = ExtractReading(
      outcome: .transaction, amountMinor: 100_000, currency: "AED", direction: .debit, confidencePercent: 90, agreed: true,
      rulesConfidencePercent: 90, learnedConfidencePercent: 90, readersAgree: true)
    reading.directionAmbiguous = true
    #expect(reading.readersConfirm && !reading.meetsFilingBar)
    let verdict = try #require(
      CombinedReader.templateVerdict(input, amountMinor: 10_000, currency: "AED", direction: .debit) { reading })
    #expect(verdict.holds.contains(.readersDisagree))
  }

  @Test("a plain debit word beside the word transfers is no ambiguous debit")
  func transfersBesideAPlainDebit() throws {
    let s = Self.stream { "AED \(Self.amount($0)) was debited with card XXX4321 for transfers to SAMPLE WALLET on 05-06-2026." }
    #expect(s.allSatisfy { !$0.1.directionAmbiguous && $0.0.kept?.fields?.direction == "debit" })
    #expect(s.contains { Self.files($0.0) })
  }

  @Test("a transfer from your own account is no ambiguous debit")
  func transferFromYourAccountIsADebit() throws {
    let s = Self.stream { "AED \(Self.amount($0)) transferred from your account XXX4321 to SAMPLE PERSON on 05-06-2026." }
    #expect(s.allSatisfy { !$0.1.directionAmbiguous && $0.0.kept?.fields?.direction == "debit" })
  }

  @Test("a transfer from your own debit or credit card is no ambiguous debit")
  func transferFromYourCardIsADebit() throws {
    for card in ["debit", "credit"] {
      let s = Self.stream { "AED \(Self.amount($0)) transferred from your \(card) card XXX4321 to SAMPLE PERSON on 05-06-2026." }
      #expect(s.allSatisfy { !$0.1.directionAmbiguous && $0.0.kept?.fields?.direction == "debit" }, "\(card)")
    }
  }

  @Test("a move between two of your own accounts never files through reader agreement")
  func ownAccountMoveHolds() throws {
    let wordings = [
      { (n: Int) in "AED \(Self.amount(n)) has been credited to your loan account XXX2222 from your account XXX1111 on 05-06-2026." },
      { (n: Int) in "AED \(Self.amount(n)) has been transferred to your savings account XXX2222 from your current account XXX1111." },
    ]
    for w in wordings {
      let s = Self.stream(w)
      #expect(s.contains { $0.1.directionAmbiguous }, "\(w(0))")
      for (r, reading) in s {
        #expect(!reading.meetsFilingBar, "\(w(0))")
        #expect(r.kept != nil && !Self.files(r), "\(w(0))")
      }
    }
  }

  @Test("money transferred with the amount before to your account is a credit for both readers")
  func amountBeforeIntoYourAccountIsACredit() throws {
    let wordings = [
      { (n: Int) in "Transferred AED \(Self.amount(n)) to your account XXX4321 on 05-06-2026." },
      { (n: Int) in "Credited \(Self.amount(n)) AED to your account XXX4321 on 05-06-2026." },
    ]
    for w in wordings {
      let input = ExtractInput(sender: "sms:", subject: "", text: w(0), receivedAtMs: TextRig.t0, listUnsubscribe: false)
      #expect(CombinedReader.readRules(input).direction == .credit, "\(w(0))")
      #expect(CombinedReader.readLearned(input, LearnedLayouts()).0.direction == .credit, "\(w(0))")
      #expect(Self.stream(w).allSatisfy { !$0.1.directionAmbiguous && $0.0.kept?.fields.map { $0.direction == "credit" } ?? true })
    }
  }

  @Test("money from your account to your own card never files through reader agreement")
  func fromYourAccountToYourCardHolds() throws {
    let s = Self.stream { "AED \(Self.amount($0)) transferred from your account XXX1111 to your card XXX2222 on 05-06-2026." }
    #expect(s.allSatisfy { $0.1.directionAmbiguous && !$0.1.meetsFilingBar && !Self.files($0.0) })
  }

  @Test("money transferred to your beneficiary's account is no credit")
  func beneficiaryAccountIsNoCredit() throws {
    let s = Self.stream { "AED \(Self.amount($0)) has been transferred to your beneficiary account XXX2222 on 05-06-2026." }
    #expect(s.allSatisfy { $0.0.kept?.fields.map { $0.direction == "debit" } ?? true && $0.1.direction != .credit })
    #expect(s.allSatisfy { !Self.files($0.0) })
  }

  @Test("standing instructions, uncleared deposits and investment account moves never file through reader agreement")
  func notSettledHolds() throws {
    let wordings = [
      { (n: Int) in "Standing instruction of AED \(Self.amount(n)) has been debited from your account XXX4321 to SAMPLE PERSON." },
      { (n: Int) in "AED \(Self.amount(n)) has been deposited to your account XXX4321, to be confirmed after clearing." },
      { (n: Int) in "AED \(Self.amount(n)) has been withdrawn from your account XXX4321 to your Global Equities trading account." },
    ]
    for w in wordings {
      #expect(TextGate.holdsFiling(w(0)), "\(w(0))")
      for (r, _) in Self.stream(w) {
        #expect(r.kept != nil && r.kept?.readerConfident == false && !Self.files(r), "\(w(0))")
      }
    }
    #expect(!TextGate.holdsFiling("AED 40.00 has been debited from your account XXX4321 at SAMPLE SHOP."))
  }

  @Test("a bill pymt made using a card and an amount deducted for an issuance have the payment shape and reach Review")
  func pymtAndDeductedKept() throws {
    let texts = [
      "Bill Pymt for SAMPLE TELECOM of AED 120.00 has been made using Credit Card XXX1234 on 05-06-2026.",
      "AED 25.00 has been deducted from your account XXX1234 for issuance of SAMPLE CERTIFICATE.",
      "Payment for SAMPLE UTILITY of AED 80.00 made using card XXX1234.",
    ]
    for t in texts {
      #expect(TextGate.hasPaymentShape(t, lenient: true) && TextGate.hasPaymentShape(t, lenient: false), "\(t)")
      for sender in [nil, "EmiratesNBD", "+971500000000"] as [String?] {
        let (r, _) = BankTextReader.read(BankTextArrival(text: t, sender: sender, receivedAtMs: TextRig.t0), templates: [])
        let k = try #require(r.kept, "\(t) \(sender ?? "none")")
        #expect(!Self.files(r), "\(t)")
        if let f = k.fields { #expect(f.direction == "debit", "\(t)") }
      }
    }
  }
}
