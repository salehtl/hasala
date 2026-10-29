import CoreCategorize
import CoreDomain
import CoreExtract
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreReplay
import CoreTemplate
import CoreTestSupport
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreMailbox

@Suite("bank texts: filing with no review (D1)")
struct BankTextFilingTests {
  @Test("a template hit from its sms_sender files with no card link; the op is a v4 txn_ingested with the text fields")
  func filesOnTemplateHit() async throws {
    let rig = try TextRig()
    let added = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    #expect(added.filed && !added.unparsed && added.bank == "dib" && added.repeatNumber == 0 && added.keptAtMs == TextRig.t0)
    let p = try rig.payload(added.txnID)
    #expect(p["needs_review"]?.boolValue == false)
    #expect(p["entry_method"]?.stringValue == "mailbox" && p["tier"]?.stringValue == "template" && p["unparsed"]?.boolValue == false)
    #expect(p["channel"]?.stringValue == "sms" && p["received_at"]?.stringValue == "2026-06-05T08:00:00.000Z")
    #expect(p["amount_minor"]?.stringValue == "12345" && p["currency"]?.stringValue == "AED" && p["direction"]?.stringValue == "debit")
    #expect(p["posted_at"]?.stringValue == "2026-06-05T06:11:00.000Z" && p["posted_precision"]?.stringValue == "time")
    #expect(p["merchant_raw"]?.stringValue == "SAMPLE SHOP" && p["last4"]?.stringValue == "1234" && p["bank"]?.stringValue == "dib")
    #expect(p["provenance"] == nil && p["dedupe"] == nil)
    let g = try #require(p["gates"]?.objectValue)
    #expect(g["ar"] == nil && g["kind"] == nil && g["reader"] == nil)
    #expect(g["sender"]?.stringValue == "trusted" && g["card"] == nil && g["forwarded"]?.boolValue == false)
    #expect(g["template"]?.stringValue == "dib.sms.purchase.v1@1")
    let ingest = try #require(try rig.ingests().first)
    #expect(ingest.v == 4 && ingest.ingestID?.utf8.count == 64)
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty)
    let t = try #require(s.txns[added.txnID])
    #expect(t.channel == "sms" && t.receivedAt == "2026-06-05T08:00:00.000Z" && t.isText && !t.needsReview && !t.verifiedSender)
    let row = try #require(try rig.row(added.txnID))
    #expect(row.isText && row.receivedMs == TextRig.t0 && row.templateRef == "dib.sms.purchase.v1@1")
  }

  @Test("a template hit files from no sender, another sender or a number, with any card or none; a paste goes to Review")
  func templateHitsFileWithNoSenderOrCardCheck() async throws {
    let purchase = try TextCase.named("dib-purchase-credit-card")
    let cases: [(String, TextCase, String)] = [
      ("no sender", try TextCase.named("dib-purchase-no-sender"), "untrusted"),
      ("other sender", try TextCase.named("dib-purchase-other-bank-sender"), "untrusted"),
      ("numeric sender", try TextCase.named("dib-purchase-numeric-sender"), "untrusted"),
      ("debit card", try TextCase.named("dib-purchase-debit-card"), "trusted"),
    ]
    for (why, c, sender) in cases {
      let rig = try TextRig()
      let added = try #require(await rig.add(c).added, "\(why)")
      #expect(added.filed, "\(why)")
      let p = try rig.payload(added.txnID)
      #expect(p["needs_review"]?.boolValue == false && p["tier"]?.stringValue == "template", "\(why)")
      #expect(p["gates"]?["card"] == nil && p["gates"]?["sender"]?.stringValue == sender, "\(why)")
      #expect(try rig.fold().anomalies.isEmpty, "\(why)")
    }
    let rig = try TextRig()
    let pasted = try #require(await rig.author.paste(purchase.text, atMs: TextRig.t0, secret: TextRig.secret, link: .notLinked).added)
    #expect(!pasted.filed)
    let p = try rig.payload(pasted.txnID)
    #expect(p["needs_review"]?.boolValue == true && p["gates"]?["sender"]?.stringValue == "untrusted")
  }

  static func novel(_ n: Int) -> TextCase {
    let amount = "\(10 + n * 7).\(String(format: "%02d", (n * 13) % 100))"
    let merchant = ["SYNTHETIC BAKERY", "SAMPLE PHARMACY", "EXAMPLE CINEMA", "SYNTHETIC GARAGE", "SAMPLE FLORIST"][n % 5]
    return TextCase(
      name: "novel-\(n)", sender: nil,
      text: "Purchase alert: AED \(amount) spent at \(merchant) using card ending 4321 on 05-06-2026. Ref SYN\(1000 + n).",
      receivedAtMs: TextRig.t0 + Int64(n) * 3_600_000)
  }

  @Test("with no template, a text the two readers agree on at 0.8 or more files with no sender; before they agree it goes to Review")
  func readerAgreementFiles() async throws {
    let rig = try TextRig()
    var outcomes: [Bool] = []
    for n in 0..<8 {
      let added = try #require(await rig.add(Self.novel(n)).added, "\(n)")
      let p = try rig.payload(added.txnID)
      #expect(p["tier"]?.stringValue == "heuristic" && p["gates"]?["template"]?.stringValue == "none", "\(n)")
      #expect(p["needs_review"]?.boolValue == !added.filed, "\(n)")
      outcomes.append(added.filed)
    }
    #expect(outcomes.first == false, "\(outcomes)")
    #expect(outcomes.last == true, "\(outcomes)")
    #expect(try rig.fold().anomalies.isEmpty)
  }

  @Test("a text with no bank that the readers would file waits in Review when it repeats a text row of the last 10 minutes")
  func banklessRepeatWaits() async throws {
    let rig = try TextRig()
    for n in 0..<8 { _ = try #require(await rig.add(Self.novel(n)).added, "\(n)") }
    let c = Self.novel(8)
    let first = try #require(await rig.add(c).added)
    #expect(first.filed && first.bank == nil)
    let same = try #require(await rig.add(c).added)
    #expect(!same.filed && same.repeatNumber == 1)
    let later = try #require(await rig.add(c, at: c.receivedAtMs + 120_000).added)
    #expect(!later.filed && later.repeatNumber == 0)
    #expect(try rig.payload(later.txnID)["needs_review"]?.boolValue == true)
    let apart = try #require(await rig.add(c, at: c.receivedAtMs + 86_400_000).added)
    #expect(apart.filed)
  }

  @Test("a text that a mail row of the last 24 hours may already hold waits in Review; another amount files")
  func mailTwinWaits() async throws {
    let c = try TextCase.named("dib-purchase-credit-card")
    let k = try #require(BankTextReader.read(c.arrival).reading.kept?.timed(arrivalMinuteMs: c.arrival.arrivalMinuteMs))
    let f = try #require(k.fields)
    let posted = try parseInstantMs(f.postedAt)
    let twin = TextTwinMail(
      bank: "dib", last4: "", amountMinor: f.amountMinor, currency: f.currency, direction: f.direction, postedMs: posted - 3_600_000)
    let held = try #require(await BankTextAuthor(ledger: FakeTextLedger(mail: [twin])).add(c.arrival, secret: TextRig.secret, link: { .notLinked }).added)
    #expect(!held.filed)
    var other = twin
    other.amountMinor += 1
    let filed = try #require(await BankTextAuthor(ledger: FakeTextLedger(mail: [other])).add(c.arrival, secret: TextRig.secret, link: { .notLinked }).added)
    #expect(filed.filed)
  }

  @Test("the ledger's mail rows are the live, parsed mailbox rows that are no text, in the window")
  func ledgerMailRows() async throws {
    let rig = try TextRig()
    let text = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    let mail = JSONObject([
      ("amount_minor", .string("4200")), ("currency", .string("AED")), ("direction", .string("debit")),
      ("posted_at", .string("2026-06-05T07:00:00.000Z")), ("posted_precision", .string("time")),
      ("merchant_raw", .string("SYNTHETIC SHOP")), ("last4", .string("")), ("category", .null), ("needs_review", .bool(false)),
      ("tier", .string("template")), ("entry_method", .string("mailbox")), ("bank", .string("dib")),
      ("gates", .object(JSONObject([("ar", .string("pass")), ("sender", .string("trusted")), ("template", .string("none")), ("forwarded", .bool(false))]))),
      ("provenance", .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string("g1")), ("message_id", .string("m1"))]))),
    ])
    let manual = JSONObject([
      ("amount_minor", .string("4200")), ("currency", .string("AED")), ("direction", .string("debit")),
      ("posted_at", .string("2026-06-05T07:00:00.000Z")), ("merchant_raw", .string("SYNTHETIC SHOP")), ("last4", .string("")),
      ("category", .null), ("needs_review", .bool(false)), ("entry_method", .string("manual")),
    ])
    try await rig.ledger.author { a throws(AuthorError) in
      _ = try a.ingest(payload: mail, ingestID: String(repeating: "a", count: 64))
      _ = try a.ingest(payload: manual, ingestID: String(repeating: "b", count: 64))
    }
    let posted = try parseInstantMs("2026-06-05T07:00:00.000Z")
    let rows = await rig.ledger.mailRows(postedFromMs: posted - 86_400_000, toMs: posted + 86_400_000)
    #expect(rows == [TextTwinMail(bank: "dib", last4: "", amountMinor: 4200, currency: "AED", direction: "debit", postedMs: posted)])
    #expect(await rig.ledger.mailRows(postedFromMs: posted + 1, toMs: posted + 86_400_000).isEmpty)
    #expect(try rig.row(text.txnID)?.isText == true)
  }

  static func novelTransfer(_ n: Int) -> TextCase {
    let amount = "\(200 + n * 11).\(String(format: "%02d", (n * 17) % 100))"
    let payee = ["SYNTHETIC PAYEE", "SAMPLE LANDLORD", "EXAMPLE TRADING", "SYNTHETIC SCHOOL", "SAMPLE CLINIC"][n % 5]
    return TextCase(
      name: "novel-transfer-\(n)", sender: nil,
      text: "Fund transfer of AED \(amount) to \(payee) from your account ending 4321 on 05-06-2026 was completed. Ref SYN\(2000 + n).",
      receivedAtMs: TextRig.t0 + Int64(n) * 3_600_000)
  }

  @Test("with no template, a text the readers agree is a transfer notice never files: pairing reads only template rows")
  func readerTransferNoticeWaits() async throws {
    let rig = try TextRig()
    var layouts = LearnedLayouts()
    var agreed = false
    for n in 0..<8 {
      let c = Self.novelTransfer(n)
      let (r, next) = BankTextReader.read(c.arrival, templates: BankTextReader.templates, layouts: layouts)
      layouts = next
      let k = try #require(r.kept, "\(n)")
      #expect(k.template == nil && !k.readerConfident, "\(n)")
      let input = ExtractInput(
        sender: "sms:", subject: "", text: BankTextReader.normalized(c.text), receivedAtMs: c.receivedAtMs, listUnsubscribe: false)
      let (reading, _) = CombinedReader.read(input, layouts)
      if reading.kind == .transferNotice && reading.meetsFilingBar { agreed = true }
      let added = try #require(await rig.add(c).added, "\(n)")
      #expect(!added.filed, "\(n)")
      #expect(try rig.payload(added.txnID)["needs_review"]?.boolValue == true, "\(n)")
    }
    #expect(agreed)
  }

  @Test("a template-free reading the readers do not both confirm goes to Review")
  func readersDisagreeGoesToReview() throws {
    let (r, _) = BankTextReader.read(Self.novel(0).arrival)
    var k = try #require(r.kept)
    #expect(k.template == nil && k.fields != nil && !k.readerConfident)
    #expect(!BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false))
    k.readerConfident = true
    #expect(BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false))
    k.fields = nil
    #expect(!BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false))
  }

  @Test("a marker beside a transaction clause never files, even on a template hit from its sender with a known card")
  func markedNeverFiles() async throws {
    let rig = try TextRig()
    let added = try #require(await rig.add(try TextCase.named("dib-template-hit-with-code-and-clause")).added)
    #expect(!added.filed)
    #expect(try rig.payload(added.txnID)["needs_review"]?.boolValue == true)
    let generic = try #require(await rig.add(try TextCase.named("generic-code-with-clause")).added)
    #expect(!generic.filed)
  }

  @Test("a one-time code and a declined purchase that the purchase template would read are dropped before it, with a known card")
  func codesAndDeclinesNeverReachTheTemplates() async throws {
    let rig = try TextRig()
    for name in ["dib-otp-worded-as-purchase", "dib-declined-worded-as-purchase"] {
      let c = try TextCase.named(name)
      let template = try #require(BankTextReader.templates.first { $0.definition.id == "dib.sms.purchase.v1" })
      #expect(try template.execute(subject: "", normalizedBody: BankTextReader.normalized(c.text)).matched, "\(name)")
      let calls = LinkCalls(.notLinked)
      let out = await rig.author.add(c.arrival, secret: TextRig.secret, link: { calls.call() })
      guard case .dropped(let k, let counted, let bank) = out else {
        Issue.record("\(name): \(out)")
        continue
      }
      #expect(k == (name.contains("otp") ? .oneTimeCode : .declined) && counted && bank == "dib")
      #expect(calls.count == 0)
    }
    #expect(try rig.ingests().isEmpty)
  }

  @Test("a row from a filing template with a transfer partner never files")
  func transferPartnerHolds() throws {
    let (r, _) = BankTextReader.read(try TextCase.named("dib-purchase-credit-card").arrival)
    let k = try #require(r.kept)
    #expect(BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false))
    #expect(!BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: true))
    #expect(!BankTextPayload.filesItself(k, link: .unknownUnanswered, origin: .automation, transferPartner: false))
    #expect(!BankTextPayload.filesItself(k, link: .linked, origin: .automation, transferPartner: false))
    #expect(!BankTextPayload.filesItself(k, link: .notLinked, origin: .paste, transferPartner: false))
    #expect(!BankTextPayload.filesItself(k, link: .notLinked, origin: .automation, transferPartner: false, mayRepeat: true))
    var held = k
    held.held = true
    #expect(!BankTextPayload.filesItself(held, link: .notLinked, origin: .automation, transferPartner: false))
    var marked = k
    marked.marked = true
    #expect(!BankTextPayload.filesItself(marked, link: .notLinked, origin: .automation, transferPartner: false))
  }
}

@Suite("bank texts: one source and the link copy")
struct BankTextLinkTests {
  @Test("while linked nothing is authored; template hits and bank or no-sender payment shapes count as ignored, others do not")
  func linkedIgnores() async throws {
    let rig = try TextRig()
    let want: [(String, Bool, String?)] = [
      ("dib-purchase-credit-card", true, "dib"), ("dib-purchase-numeric-sender", true, "dib"), ("dib-english-purchase", true, "dib"),
      ("dib-arabic-cash-no-template-no-sender", true, nil), ("person-sent-money", false, nil), ("unknown-sender-payment", false, nil),
    ]
    for (name, counted, bank) in want {
      let out = await rig.add(try TextCase.named(name), link: .linked)
      #expect(out == .ignored(counted: counted, bank: bank), "\(name): \(out)")
    }
    for name in ["dib-otp-purchase", "bank-no-payment-word", "person-chat"] {
      guard case .dropped = await rig.add(try TextCase.named(name), link: .linked) else {
        Issue.record("\(name) was not dropped")
        continue
      }
    }
    #expect(try rig.pendingOps().isEmpty)
    #expect(try rig.pendingOps().isEmpty)
  }

  @Test("while linked the paste refuses, whatever the text, and is not counted as ignored; not linked or unknown, it adds")
  func pasteRefusedWhileLinked() async throws {
    let rig = try TextRig()
    for name in ["dib-purchase-credit-card", "dib-english-purchase", "person-chat", "dib-otp-purchase"] {
      let out = await rig.author.paste(try TextCase.named(name).text, atMs: TextRig.t0, secret: TextRig.secret, link: .linked)
      #expect(out == .pasteRefused, "\(name): \(out)")
    }
    #expect(try rig.pendingOps().isEmpty)
    let unread = try #require(await rig.add(try TextCase.named("dib-arabic-no-amount")).added)
    let refused = await rig.author.paste(
      try TextCase.named("dib-purchase-credit-card").text, atMs: TextRig.t0, secret: TextRig.secret, link: .linked, replacing: unread.txnID)
    #expect(refused == .pasteRefused)
    #expect(try rig.pendingOps().count == 1)
    for link in [BankTextLink.notLinked, .unknownUnanswered] {
      let out = await rig.author.paste(try TextCase.named("dib-english-purchase").text, atMs: TextRig.t0, secret: TextRig.secret, link: link)
      #expect(out.added?.filed == false, "\(link): \(out)")
    }
  }

  @Test("with no answer about the link, a kept text is authored for Review and never files; a dropped text never asks")
  func unknownLinkNeverFiles() async throws {
    let rig = try TextRig()
    let calls = LinkCalls(.unknownUnanswered)
    let out = await rig.author.add(try TextCase.named("dib-purchase-credit-card").arrival, secret: TextRig.secret, link: { calls.call() })
    let added = try #require(out.added)
    #expect(!added.filed && calls.count == 1)
    #expect(try rig.payload(added.txnID)["needs_review"]?.boolValue == true)
    for name in ["dib-otp-purchase", "person-chat", "no-sender-chat", "set-up-test-bank", "dib-promotion"] {
      _ = await rig.author.add(try TextCase.named(name).arrival, secret: TextRig.secret, link: { calls.call() })
    }
    #expect(calls.count == 1)
  }

  @Test("the set-up test marks the test passed and authors nothing, from any sender; outside the window it leaves no trace")
  func setUpTest() async throws {
    let rig = try TextRig()
    for name in ["set-up-test-person", "set-up-test-unknown", "set-up-test-bank", "set-up-test-no-sender"] {
      let c = try TextCase.named(name)
      #expect(await rig.add(c) == .testPassed, "\(name)")
      let (r, _) = BankTextReader.read(c.arrival)
      #expect(!r.countsAsPayment, "\(name)")
    }
    for name in ["set-up-test-outside-window", "set-up-test-outside-window-no-sender"] {
      #expect(await rig.add(try TextCase.named(name)) == .dropped(.noPaymentShape, counted: false, bank: nil), "\(name)")
    }
    #expect(try rig.pendingOps().isEmpty)
  }
}

@Suite("bank texts: the key for each text")
struct BankTextKeyTests {
  @Test("the key is 64 hex digits of HMAC-SHA256 over length-prefixed fields; any change in any field changes it")
  func key() throws {
    let s = TextRig.secret
    let k = try #require(BankTextKey.ingestID(secret: s, sender: "dib-sms", normalizedText: "abc", arrivalMinuteMs: 60_000, n: 0))
    #expect(k.utf8.count == 64 && k.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
    var variants: Set<String> = [k]
    for v in [
      BankTextKey.ingestID(secret: s, sender: "dib-sm", normalizedText: "sabc", arrivalMinuteMs: 60_000, n: 0),
      BankTextKey.ingestID(secret: s, sender: "", normalizedText: "abc", arrivalMinuteMs: 60_000, n: 0),
      BankTextKey.ingestID(secret: s, sender: nil, normalizedText: "dib-smsabc", arrivalMinuteMs: 60_000, n: 0),
      BankTextKey.ingestID(secret: s, sender: "dib-sms", normalizedText: "abc", arrivalMinuteMs: 120_000, n: 0),
      BankTextKey.ingestID(secret: s, sender: "dib-sms", normalizedText: "abc", arrivalMinuteMs: 60_000, n: 1),
      BankTextKey.ingestID(secret: Data(repeating: 1, count: 32), sender: "dib-sms", normalizedText: "abc", arrivalMinuteMs: 60_000, n: 0),
      BankTextKey.ingestID(secret: s, sender: "dib-sms", normalizedText: "abc1", arrivalMinuteMs: 6_000, n: 0),
    ] {
      #expect(variants.insert(try #require(v)).inserted)
    }
    #expect(BankTextKey.ingestID(secret: s, sender: "dib-sms", normalizedText: "abc", arrivalMinuteMs: 60_000, n: 0) == k)
    #expect(BankTextKey.ingestID(secret: Data(count: 31), sender: nil, normalizedText: "x", arrivalMinuteMs: 0, n: 0) == nil)
    #expect(BankTextKey.ingestID(secret: Data(count: 33), sender: nil, normalizedText: "x", arrivalMinuteMs: 0, n: 0) == nil)
  }

  @Test("equal texts in the same minute get n 0 and 1; the fold holds the second as a probable copy; the same key again is duplicate_ingest")
  func sameMinute() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-purchase-credit-card")
    let a = try #require(await rig.add(c, at: TextRig.t0 + 5_000).added)
    let b = try #require(await rig.add(c, at: TextRig.t0 + 50_000).added)
    #expect(a.repeatNumber == 0 && b.repeatNumber == 1 && a.txnID != b.txnID)
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty)
    #expect(s.txns[b.txnID]?.copyOf == a.txnID && s.txns[b.txnID]?.isHeldCopy == true && s.txns[a.txnID]?.copyOf == nil)
    let first = try #require(try rig.ingests().first)
    var a2 = OpAuthor(AuthorContext(writerID: TextRig.writer.string, nowMs: TextRig.t0 + 86_400_000, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "again")))
    try a2.ingest(payload: try #require(first.payload.objectValue), ingestID: try #require(first.ingestID))
    var again = s
    try Replay.foldOps(try a2.build().ops, seq: 999, writerID: TextRig.writer.string, into: &again)
    #expect(again.anomalies.map(\.kind) == ["duplicate_ingest"])
  }

  @Test("an automation that runs twice across a minute boundary gives two rows, the second held")
  func acrossMinutes() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-purchase-credit-card")
    let a = try #require(await rig.add(c, at: TextRig.t0 + 59_000).added)
    let b = try #require(await rig.add(c, at: TextRig.t0 + 61_000).added)
    #expect(a.repeatNumber == 0 && b.repeatNumber == 0)
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns[b.txnID]?.copyOf == a.txnID)
  }

  @Test("two runs of equal texts started together get n 0 and 1 and two rows; neither is refused as duplicate_ingest")
  func concurrent() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-reversal")
    let outcomes = await withTaskGroup(of: BankTextOutcome.self) { g in
      for _ in 0..<2 { g.addTask { await rig.add(c) } }
      var out: [BankTextOutcome] = []
      for await o in g { out.append(o) }
      return out
    }
    #expect(outcomes.compactMap(\.added).map(\.repeatNumber).sorted() == [0, 1])
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns.count == 2)
    #expect(Set(try rig.ingests().compactMap(\.ingestID)).count == 2)
  }

  @Test("two authors on one ledger share its serial: equal texts started together get n 0 and 1, and neither is a duplicate_ingest")
  func twoAuthorsOneLedger() async throws {
    let c = try TextCase.named("dib-reversal")
    for _ in 0..<4 {
      let rig = try TextRig()
      let authors = [rig.author, BankTextAuthor(ledger: rig.ledger), BankTextAuthor(ledger: rig.ledger)]
      let outcomes = await withTaskGroup(of: BankTextOutcome.self) { g in
        for a in authors { g.addTask { await a.add(c.arrival, secret: TextRig.secret, link: { .notLinked }) } }
        var out: [BankTextOutcome] = []
        for await o in g { out.append(o) }
        return out
      }
      #expect(outcomes.compactMap(\.added).map(\.repeatNumber).sorted() == [0, 1, 2])
      let s = try rig.fold()
      #expect(s.anomalies.isEmpty && s.txns.count == 3)
      #expect(Set(try rig.ingests().compactMap(\.ingestID)).count == 3)
    }
  }

  @Test("a key whose op is still in the outbox counts as taken")
  func outboxCountsAsTaken() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-reversal")
    _ = try #require(await rig.add(c).added)
    let text = BankTextReader.normalized(c.text)
    let key0 = try #require(BankTextKey.ingestID(secret: TextRig.secret, sender: "dib-sms", normalizedText: text, arrivalMinuteMs: TextRig.t0, n: 0))
    #expect(try rig.store.hasPendingIngest(key0))
    #expect(await rig.ledger.isIngested(key0))
    let fake = FakeTextLedger(outbox: [key0])
    let out = await BankTextAuthor(ledger: fake).add(c.arrival, secret: TextRig.secret, link: { .notLinked })
    #expect(out.added?.repeatNumber == 1)
  }

  @Test("equal texts on different days are two rows with no hold")
  func differentDays() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-reversal")
    let a = try #require(await rig.add(c).added)
    let b = try #require(await rig.add(c, at: TextRig.t0 + 86_400_000).added)
    #expect(a.repeatNumber == 0 && b.repeatNumber == 0)
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns[b.txnID]?.copyOf == nil && s.txns[a.txnID]?.copyOf == nil)
  }

  @Test("a repeat the fold cannot hold as a copy (no bank) is a second row in Review, beside the first as a possible duplicate")
  func noBankRepeat() async throws {
    let rig = try TextRig()
    let c = try TextCase.named("dib-english-purchase-no-sender")
    let a = try #require(await rig.add(c).added)
    let b = try #require(await rig.add(c).added)
    #expect(!a.filed && !b.filed && b.repeatNumber == 1)
    let s = try rig.fold()
    #expect(s.anomalies.map(\.kind) == ["possible_duplicate"])
    #expect(s.txns.count == 2 && s.txns[b.txnID]?.needsReview == true && s.txns[b.txnID]?.copyOf == nil)
    #expect(s.txns[b.txnID]?.possibleDuplicateOf == a.txnID && s.txns[a.txnID]?.isLive == true && s.txns[b.txnID]?.isLive == true)
  }
}

actor FakeTextLedger: BankTextLedger {
  nonisolated let textWrites = WriteSerial()
  var outbox: Set<String>
  var rows: [BankTextRow] = []
  var mail: [TextTwinMail]
  var authored: [BankTextDraft] = []

  init(outbox: Set<String> = [], mail: [TextTwinMail] = []) {
    self.outbox = outbox
    self.mail = mail
  }

  func isIngested(_ ingestID: String) async -> Bool { outbox.contains(ingestID) || authored.contains { $0.ingestID == ingestID } }
  func textRows(postedFromMs: Int64, toMs: Int64) async -> [BankTextRow] { rows }
  func mailRows(postedFromMs: Int64, toMs: Int64) async -> [TextTwinMail] { mail.filter { $0.postedMs >= postedFromMs && $0.postedMs <= toMs } }
  func authorText(_ draft: BankTextDraft, archiving: String?) async throws(MailboxLedgerError) -> String {
    authored.append(draft)
    return "01JC00000000000000000000\(authored.count < 10 ? "0" : "")\(authored.count)"
  }
}

@Suite("bank texts: the transfer pair")
struct BankTextTransferPairTests {
  static func ownTransfer(_ amount: String) -> String {
    "تحويل بين حساباتك بمبلغ AED \(amount) من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 05-06-2026 MB Fund Transfer رصيد حساب الخصم هو AED 9,876.54 وحساب الايداع هو AED 8,765.43"
  }

  static func debit(_ amount: String) -> String { "خصم بمبلغ \(amount) في 05-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44" }

  @Test("a DIB debit alert and a transfer notice for one amount within 30 minutes: the second waits in Review naming the first, in either order")
  func pairs() async throws {
    for order in [[Self.debit("234.56"), Self.ownTransfer("234.56")], [Self.ownTransfer("234.56"), Self.debit("234.56")]] {
      let rig = try TextRig()
      let first = try #require(await rig.add(TextCase(name: "a", sender: "DIB-SMS", text: order[0], receivedAtMs: TextRig.t0)).added)
      let second = try #require(
        await rig.add(TextCase(name: "b", sender: "DIB-SMS", text: order[1], receivedAtMs: TextRig.t0 + 29 * 60_000)).added)
      #expect(first.transferPartner == nil && second.transferPartner == first.txnID && !second.filed)
      #expect(try rig.payload(second.txnID)["needs_review"]?.boolValue == true)
      let s = try rig.fold()
      #expect(s.anomalies.isEmpty && s.txns[first.txnID]?.isLive == true && s.txns[second.txnID]?.isLive == true)
      #expect(s.txns[first.txnID]?.copyOf == nil && s.txns[second.txnID]?.copyOf == nil && s.txns[second.txnID]?.mergedInto == nil)
    }
  }

  @Test("31 minutes apart, another amount, or two of the same role: no hold")
  func noPair() async throws {
    let cases: [(String, String, Int64)] = [
      (Self.debit("234.56"), Self.ownTransfer("234.56"), 31), (Self.debit("234.56"), Self.ownTransfer("234.57"), 5),
      (Self.debit("234.56"), Self.debit("234.56"), 5),
    ]
    for (a, b, minutes) in cases {
      let rig = try TextRig()
      _ = try #require(await rig.add(TextCase(name: "a", sender: "DIB-SMS", text: a, receivedAtMs: TextRig.t0)).added)
      let second = try #require(
        await rig.add(TextCase(name: "b", sender: "DIB-SMS", text: b, receivedAtMs: TextRig.t0 + minutes * 60_000)).added)
      #expect(second.transferPartner == nil)
    }
  }

  @Test("an archived text row is no transfer partner; textRows lists only live text rows")
  func archivedIsNoPartner() async throws {
    let rig = try TextRig()
    let alert = try #require(
      await rig.add(TextCase(name: "a", sender: "DIB-SMS", text: Self.debit("234.56"), receivedAtMs: TextRig.t0)).added)
    #expect(try rig.observer.reader.textRows(postedFromMs: TextRig.t0 - 3_600_000, toMs: TextRig.t0 + 3_600_000).map(\.id) == [alert.txnID])
    try await rig.ledger.author { a throws(AuthorError) in a.annotate(txnID: alert.txnID, set: [("archived", "user")]) }
    #expect(try rig.observer.reader.textRows(postedFromMs: TextRig.t0 - 3_600_000, toMs: TextRig.t0 + 3_600_000).isEmpty)
    #expect(try rig.observer.reader.textRowSpan()?.count == 1)
    let notice = try #require(
      await rig.add(TextCase(name: "b", sender: "DIB-SMS", text: Self.ownTransfer("234.56"), receivedAtMs: TextRig.t0 + 600_000)).added)
    #expect(notice.transferPartner == nil)
    #expect(try rig.fold().anomalies.isEmpty)
  }

  @Test("the pure check: other role, same bank, amount and currency, within the window, nearest first")
  func pureCheck() {
    func row(_ id: String, _ t: String, _ ms: Int64, amount: Int64 = 100, bank: String? = "dib", currency: String = "AED") -> BankTextRow {
      BankTextRow(id: id, bank: bank, amountMinor: amount, currency: currency, direction: "debit", last4: "", postedMs: ms, templateRef: t, unparsed: false)
    }
    let alert = row("x", "dib.sms.debit.v1@1", 0)
    let rows = [
      row("a", "dib.sms.own-transfer.v1@1", 20 * 60_000), row("b", "dib.sms.own-transfer.v1@1", -10 * 60_000),
      row("c", "dib.sms.debit.v1@1", 60_000), row("d", "dib.sms.own-transfer.v1@1", 60_000, amount: 101),
      row("e", "dib.sms.own-transfer.v1@1", 60_000, bank: nil), row("f", "dib.sms.own-transfer.v1@1", 60_000, currency: "USD"),
      row("g", "dib.sms.purchase.v1@1", 0),
    ]
    #expect(BankTextTransferPair.partner(of: alert, among: rows)?.id == "b")
    #expect(BankTextTransferPair.partner(of: row("y", "dib.sms.purchase.v1@1", 0), among: rows) == nil)
    #expect(BankTextTransferPair.partner(of: alert, among: [row("z", "dib.sms.own-transfer.v1@1", 31 * 60_000)]) == nil)
  }
}

@Suite("bank texts: the unparsed text row, paste and categorization")
struct BankTextRowTests {
  @Test("a payment-shaped bank text with no readable amount is an unparsed text row that folds with no anomaly")
  func unparsedRow() async throws {
    let rig = try TextRig()
    let added = try #require(await rig.add(try TextCase.named("dib-arabic-no-amount")).added)
    #expect(added.unparsed && !added.filed)
    let p = try rig.payload(added.txnID)
    #expect(p["tier"]?.stringValue == "none" && p["unparsed"]?.boolValue == true && p["needs_review"]?.boolValue == true)
    #expect(p["amount_minor"] == nil && p["currency"] == nil && p["direction"] == nil)
    #expect(p["bank"]?.stringValue == "dib" && p["last4"]?.stringValue == "1234" && p["posted_precision"]?.stringValue == "time")
    #expect(p["posted_at"]?.stringValue == "2026-06-05T08:00:00.000Z" && p["received_at"]?.stringValue == "2026-06-05T08:00:00.000Z")
    #expect(p["channel"]?.stringValue == "sms" && p["gates"]?["template"]?.stringValue == "none")
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns[added.txnID]?.unparsed == true && s.txns[added.txnID]?.isText == true)
    let row = try #require(try rig.row(added.txnID))
    #expect(row.unparsed && row.isText && row.reviewLane == "unreadable")
  }

  @Test("a paste that replaces an unparsed text row archives it in the same blob, and the fold accepts it")
  func pasteReplaces() async throws {
    let rig = try TextRig()
    let unread = try #require(await rig.add(try TextCase.named("dib-arabic-no-amount")).added)
    let pasted = try #require(
      await rig.author.paste(
        try TextCase.named("dib-purchase-credit-card").text, atMs: TextRig.t0 + 3_600_000, secret: TextRig.secret, link: .unknownUnanswered,
        replacing: unread.txnID
      ).added)
    #expect(!pasted.filed)
    let ops = try rig.pendingOps()
    let annotate = try #require(ops.last)
    #expect(annotate.type == .txnAnnotated && annotate.payload["txn_id"]?.stringValue == unread.txnID)
    #expect(annotate.payload["set"]?["archived"]?.stringValue == "user")
    let rows = try rig.store.pendingOps()
    #expect(Set(rows.suffix(2).map(\.enqueuedAt)).count == 1 && rows.suffix(2).first?.opType == "txn_ingested")
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns[unread.txnID]?.annotation("archived") == "user")
    let p = try rig.payload(pasted.txnID)
    #expect(p["received_at"]?.stringValue == "2026-06-05T09:00:00.000Z")
  }

  @Test("the SMS refund and reversal templates file credits under refunds")
  func refunds() async throws {
    struct Shops: IngestCategorizer {
      func decide(merchantRaw: String, direction: String) -> IngestDecision { .none }
    }
    let rig = try TextRig(categorizer: Shops())
    for name in ["dib-refund", "dib-reversal"] {
      let added = try #require(await rig.add(try TextCase.named(name)).added)
      let p = try rig.payload(added.txnID)
      #expect(p["category"]?.stringValue == "refunds", "\(name)")
      #expect(p["category_source"]?["entry"]?.stringValue?.hasPrefix("template:dib.sms.") == true, "\(name)")
    }
    #expect(try rig.fold().anomalies.isEmpty)
  }

  @Test("only rows read by the SMS purchase template may leave the device under Cloud suggestions")
  func cloudSuggestions() async throws {
    let rig = try TextRig()
    var ids: [String: String] = [:]
    for name in [
      "dib-purchase-credit-card", "dib-own-transfer", "dib-salary", "dib-credit-transfer", "dib-refund", "dib-reversal", "dib-card-payment",
      "dib-debit", "dib-english-purchase", "dib-arabic-no-amount",
    ] {
      ids[name] = try #require(await rig.add(try TextCase.named(name)).added?.txnID, "\(name)")
    }
    let rows = Dictionary(uniqueKeysWithValues: try rig.observer.reader.sweepRows().map { ($0.id, $0) })
    for (name, id) in ids {
      let r = try #require(rows[id], "\(name)")
      #expect(r.text, "\(name)")
      #expect(ModelSuggestionSweep.mayLeaveDevice(r) == (name == "dib-purchase-credit-card"), "\(name)")
      #expect(!ModelSuggestionSweep.mayStayOnDevice(r), "\(name)")
    }
  }

  @Test("learned layouts train on bank senders and on texts with no sender, keyed sms:<sender> or sms:, only when a row is authored, and live only in the author's memory")
  func layouts() async throws {
    let rig = try TextRig()
    _ = await rig.add(try TextCase.named("person-sent-money"))
    #expect(await rig.author.layouts == LearnedLayouts())
    _ = await rig.add(try TextCase.named("dib-english-purchase"), link: .linked)
    #expect(await rig.author.layouts == LearnedLayouts())
    _ = await rig.add(try TextCase.named("dib-otp-purchase"))
    #expect(await rig.author.layouts == LearnedLayouts())
    _ = await rig.add(try TextCase.named("dib-english-purchase"))
    #expect(await rig.author.layouts.senders.keys.sorted() == ["sms:dib-sms"])
    _ = await rig.add(try TextCase.named("dib-english-purchase-no-sender"))
    #expect(await rig.author.layouts.senders.keys.sorted() == ["sms:", "sms:dib-sms"])
    let next = BankTextAuthor(ledger: rig.ledger)
    #expect(await next.layouts == LearnedLayouts())
    _ = try #require(await next.add(try TextCase.named("dib-english-purchase").arrival, secret: TextRig.secret, link: { .notLinked }).added)
    #expect(await next.layouts.senders.keys.sorted() == ["sms:dib-sms"])
  }
}

@Suite("bank texts: no text in an op")
struct BankTextNoTextInOpTests {
  static func strings(_ v: JSONValue, _ out: inout [String]) {
    switch v {
    case .string(let s): out.append(s)
    case .array(let a): for x in a { strings(x, &out) }
    case .object(let o): for m in o.members where m.key != "bank" { strings(m.value, &out) }
    default: break
    }
  }

  static func pieces(_ text: String) -> [String] {
    var out: [String] = []
    for line in text.split(separator: "\n") {
      out.append(String(line))
      var current = ""
      for ch in line {
        current.append(ch)
        if ".!?؟،؛".contains(ch) {
          out.append(current.trimmingCharacters(in: .whitespaces))
          current = ""
        }
      }
      if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
    }
    return out.filter { $0.utf8.count >= 12 }
  }

  @Test("no op holds the body, a sentence or line of it, the sender or the secret")
  func scan() async throws {
    var checked = 0
    for c in try TextCase.all() {
      let rig = try TextRig()
      _ = await rig.add(c)
      _ = await rig.author.paste(c.text, atMs: c.receivedAtMs, secret: TextRig.secret, link: .notLinked)
      for op in try rig.ingests() {
        checked += 1
        let json = String(decoding: try OpCodec.encodeBlobOps([op]), as: UTF8.self)
        #expect(!json.contains(Hex.encode(TextRig.secret)) && !json.contains(Base64.encode(TextRig.secret)), "\(c.name)")
        var values: [String] = []
        Self.strings(op.payload, &values)
        let body = BankTextReader.normalized(c.text)
        let merchant = op.payload["merchant_raw"]?.stringValue ?? ""
        for v in values {
          #expect(v != body || body.utf8.count < 12, "\(c.name): the whole body is in an op")
          if let s = c.sender, !s.isEmpty { #expect(!v.localizedCaseInsensitiveContains(s), "\(c.name): the sender is in an op") }
          for piece in Self.pieces(body) where v.contains(piece) {
            #expect(v == merchant && merchant.contains(piece), "\(c.name): a line of the text is in an op")
          }
        }
        if c.sender == nil || c.sender?.first == "+" || c.sender == "SAMPLEINFO",
          op.payload["gates"]?["template"]?.stringValue == "none"
        {
          #expect(merchant.split(separator: " ").count <= TextGate.merchantWordLimit && merchant.utf8.count <= TextGate.merchantByteLimit, "\(c.name)")
        }
      }
    }
    #expect(checked > 60)
  }

  @Test("a person's text keeps a merchant only from a card-purchase label, at most 4 words and 40 bytes; a transfer's payee is not kept")
  func personMerchant() throws {
    func merchant(_ name: String) throws -> String? {
      let (r, _) = BankTextReader.read(try TextCase.named(name).arrival)
      return r.kept.map { $0.fields?.merchant ?? $0.merchant }
    }
    #expect(try merchant("person-card-purchase") == "SYNTHETIC BAKERY DOWNTOWN DUBAI")
    #expect(try merchant("person-sent-money") == "")
    #expect(try merchant("no-sender-transfer-to-payee") == "")
    #expect(try merchant("no-sender-transfer-no-currency") == "")
    #expect(TextGate.limited("ABCDEFGHIJ ABCDEFGHIJ ABCDEFGHIJ ABCDEFGHIJ") == "ABCDEFGHIJ ABCDEFGHIJ ABCDEFGHIJ")
    #expect(TextGate.limited(String(repeating: "م", count: 30)).utf8.count <= 40)
    #expect(try merchant("dib-english-purchase") == "SYNTHETIC SHOP")
  }
}

@Suite("bank texts: the authored op is the fold golden's op")
struct BankTextGoldenOpTests {
  static func golden(_ caseName: String, _ opID: String) throws -> JSONValue {
    let doc = try TextGolden.json("swift/fold-v4-sms-texts.json")
    let c = try #require(doc["cases"]?.arrayValue?.first { $0["name"]?.stringValue == caseName })
    let ops = (c["log"]?.arrayValue ?? []).flatMap { $0["ops"]?.arrayValue ?? [] }
    let op = try #require(ops.first { $0["op_id"]?.stringValue == opID })
    return try #require(op["payload"]).sortingKeysByUTF8()
  }

  @Test("every text row in conformance/swift/fold-v4-sms-texts.json is what the author writes for its synthetic text")
  func sameOps() async throws {
    let rig = try TextRig()
    let filed = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    #expect(JSONValue.object(try rig.payload(filed.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-template-row", "op-sms-1")))

    let other = try TextRig()
    let unread = try #require(await other.add(try TextCase.named("dib-arabic-no-amount")).added)
    #expect(JSONValue.object(try other.payload(unread.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-unparsed-pasted-over", "op-sms-1")))
    let pasted = try #require(
      await other.author.paste(
        try TextCase.named("dib-purchase-credit-card").text, atMs: TextRig.t0 + 3_600_000, secret: TextRig.secret,
        link: .unknownUnanswered, replacing: unread.txnID
      ).added)
    #expect(JSONValue.object(try other.payload(pasted.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-unparsed-pasted-over", "op-sms-2")))
    let reader = try #require(await other.add(try TextCase.named("dib-english-purchase-no-sender")).added)
    #expect(JSONValue.object(try other.payload(reader.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-reader-repeat-no-bank", "op-sms-1")))

    let pair = try TextRig()
    let alert = try #require(
      await pair.add(TextCase(name: "a", sender: "DIB-SMS", text: BankTextTransferPairTests.debit("234.56"), receivedAtMs: TextRig.t0)).added)
    let notice = try #require(
      await pair.add(
        TextCase(name: "b", sender: "DIB-SMS", text: BankTextTransferPairTests.ownTransfer("234.56"), receivedAtMs: TextRig.t0 + 600_000)
      ).added)
    #expect(notice.transferPartner == alert.txnID)
    #expect(JSONValue.object(try pair.payload(alert.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-transfer-pair-kept", "op-sms-1")))
    #expect(JSONValue.object(try pair.payload(notice.txnID)).sortingKeysByUTF8() == (try Self.golden("sms-transfer-pair-kept", "op-sms-2")))
  }
}

actor RefusingTextLedger: BankTextLedger {
  nonisolated let textWrites = WriteSerial()
  let refusals: Int
  let error: String
  var attempts: [(draft: BankTextDraft, archiving: String?)] = []

  init(refusing refusals: Int, with error: String = "invalid_op") {
    self.refusals = refusals
    self.error = error
  }

  func isIngested(_ ingestID: String) async -> Bool { false }
  func textRows(postedFromMs: Int64, toMs: Int64) async -> [BankTextRow] { [] }
  func mailRows(postedFromMs: Int64, toMs: Int64) async -> [TextTwinMail] { [] }
  func authorText(_ draft: BankTextDraft, archiving: String?) async throws(MailboxLedgerError) -> String {
    attempts.append((draft, archiving))
    if attempts.count <= refusals { throw MailboxLedgerError(error) }
    return "01JC0000000000000000000001"
  }
}

@Suite("bank texts: a refused draft falls back to an unparsed row")
struct BankTextFallbackTests {
  static func folds(_ d: BankTextDraft) throws -> Bool {
    var a = OpAuthor(
      AuthorContext(writerID: TextRig.writer.string, nowMs: TextRig.t0, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "fallback")))
    try a.ingest(payload: d.payload, ingestID: d.ingestID)
    var s = State()
    try Replay.foldOps(try a.build().ops, seq: 1, writerID: TextRig.writer.string, into: &s)
    return s.anomalies.isEmpty && s.txns.count == 1
  }

  static func add(_ ledger: RefusingTextLedger, _ c: TextCase) async -> BankTextOutcome {
    await BankTextAuthor(ledger: ledger).add(c.arrival, secret: TextRig.secret, link: { .notLinked })
  }

  @Test("each refusal takes the next draft: unparsed with the merchant, then without it, then without bank, card and the text's time")
  func chain() async throws {
    let c = try TextCase.named("dib-purchase-credit-card")
    let ledger = RefusingTextLedger(refusing: 3)
    let added = try #require(await Self.add(ledger, c).added)
    #expect(added.unparsed && !added.filed && added.bank == "dib")
    let drafts = await ledger.attempts.map(\.draft)
    #expect(drafts.count == 4 && Set(drafts.map(\.ingestID)).count == 1)
    #expect(drafts[0].payload["unparsed"]?.boolValue == false && drafts[0].payload["amount_minor"]?.stringValue == "12345")
    #expect(drafts[0].payload["needs_review"]?.boolValue == false && !drafts[0].needsReview)
    for d in drafts.dropFirst() {
      let p = d.payload
      #expect(d.needsReview && p["needs_review"]?.boolValue == true && p["unparsed"]?.boolValue == true && p["tier"]?.stringValue == "none")
      #expect(p["amount_minor"] == nil && p["currency"] == nil && p["direction"] == nil && p["category"] == .null)
      #expect(p["channel"]?.stringValue == "sms" && p["received_at"]?.stringValue == "2026-06-05T08:00:00.000Z")
      #expect(p["posted_precision"]?.stringValue == "time" && p["gates"]?["template"]?.stringValue == "none")
      #expect(p["gates"]?["sender"]?.stringValue == "untrusted")
    }
    for d in drafts { #expect(try Self.folds(d)) }
    let (one, two, three) = (drafts[1].payload, drafts[2].payload, drafts[3].payload)
    #expect(one["merchant_raw"]?.stringValue == "SAMPLE SHOP" && one["bank"]?.stringValue == "dib" && one["last4"]?.stringValue == "1234")
    #expect(one["posted_at"]?.stringValue == "2026-06-05T06:11:00.000Z" && one["gates"]?["card"] == nil)
    #expect(two["merchant_raw"]?.stringValue == "" && two["bank"]?.stringValue == "dib" && two["last4"]?.stringValue == "1234")
    #expect(two["posted_at"]?.stringValue == "2026-06-05T06:11:00.000Z")
    #expect(three["merchant_raw"]?.stringValue == "" && three["bank"] == nil && three["last4"]?.stringValue == "")
    #expect(three["posted_at"]?.stringValue == "2026-06-05T08:00:00.000Z" && three["gates"]?["card"] == nil)
  }

  @Test("a refusal of every draft fails with the refusal; an error that is no refusal stops at the first draft")
  func stops() async throws {
    let c = try TextCase.named("dib-purchase-credit-card")
    let all = RefusingTextLedger(refusing: 4)
    #expect(await Self.add(all, c) == .failed("invalid_op"))
    #expect(await all.attempts.count == 4)
    for refusal in ["op_too_large", "refused_cap"] {
      let r = RefusingTextLedger(refusing: 1, with: refusal)
      #expect(await Self.add(r, c).added?.unparsed == true, "\(refusal)")
      #expect(await r.attempts.count == 2, "\(refusal)")
    }
    for other in ["enqueue", "context_offline", "not_authored"] {
      let r = RefusingTextLedger(refusing: 1, with: other)
      #expect(await Self.add(r, c) == .failed(other), "\(other)")
      #expect(await r.attempts.count == 1, "\(other)")
    }
  }

  @Test("the archive of the row a paste replaces rides along with every draft")
  func archiving() async throws {
    let ledger = RefusingTextLedger(refusing: 2)
    let out = await BankTextAuthor(ledger: ledger).paste(
      try TextCase.named("dib-purchase-credit-card").text, atMs: TextRig.t0, secret: TextRig.secret, link: .notLinked,
      replacing: "01JC0000000000000000000009")
    #expect(out.added?.unparsed == true)
    let attempts = await ledger.attempts
    #expect(attempts.count == 3 && attempts.allSatisfy { $0.archiving == "01JC0000000000000000000009" })
  }

  @Test("an unparsed draft is not tried twice: its fallbacks start with the next variant")
  func unparsedNotRetried() async throws {
    let ledger = RefusingTextLedger(refusing: 1)
    let added = try #require(await Self.add(ledger, try TextCase.named("dib-arabic-no-amount")).added)
    #expect(added.unparsed)
    let drafts = await ledger.attempts.map(\.draft)
    #expect(drafts.count == 2 && drafts.allSatisfy { $0.payload["unparsed"]?.boolValue == true } && drafts[0] != drafts[1])
    #expect(drafts[0].payload["bank"]?.stringValue == "dib" && drafts[0].payload["last4"]?.stringValue == "1234")
    #expect(drafts[1].payload["bank"] == nil && drafts[1].payload["last4"]?.stringValue == "" && drafts[1].payload["gates"]?["card"] == nil)
    let all = RefusingTextLedger(refusing: 9)
    #expect(await Self.add(all, try TextCase.named("dib-arabic-no-amount")) == .failed("invalid_op"))
    #expect(await all.attempts.count == 2)
  }

  @Test("an automation text with only a date that is not the arrival's day is authored with time inside its day, also on each fallback")
  func dayPrecision() async throws {
    let text = "خصم بمبلغ 234.56 في 03-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44"
    let c = TextCase(name: "day", sender: "DIB-SMS", text: text, receivedAtMs: TextRig.t0)
    let k = try #require(BankTextReader.read(c.arrival).reading.kept)
    #expect(k.fields?.precision == "day" && k.postedAt == "2026-06-02T20:00:00.000Z")
    let ledger = RefusingTextLedger(refusing: 3)
    _ = try #require(await Self.add(ledger, c).added)
    let drafts = await ledger.attempts.map(\.draft)
    #expect(drafts.count == 4)
    for d in drafts.prefix(3) {
      #expect(d.payload["posted_precision"]?.stringValue == "time" && d.payload["posted_at"]?.stringValue == "2026-06-03T07:59:00.000Z")
    }
    #expect(drafts[3].payload["posted_precision"]?.stringValue == "time" && drafts[3].payload["posted_at"]?.stringValue == "2026-06-05T08:00:00.000Z")
    for d in drafts { #expect(try Self.folds(d)) }
  }

  @Test("the time of a date-only text: the arrival minute on its own day; after its day, as far before the day's end as the arrival is after it")
  func timedClamp() throws {
    let text = "خصم بمبلغ 234.56 في 05-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44"
    func kept(_ ms: Int64) throws -> BankTextKept {
      try #require(BankTextReader.read(BankTextArrival(text: text, sender: "DIB-SMS", receivedAtMs: ms)).reading.kept)
    }
    let sameDay = try kept(TextRig.t0)
    #expect(sameDay.fields?.precision == "time" && sameDay.timed(arrivalMinuteMs: TextRig.t0) == sameDay)
    let late = try kept(TextRig.t0 + 86_400_000)
    #expect(late.fields?.precision == "day")
    let t = late.timed(arrivalMinuteMs: TextRig.t0 + 86_400_000)
    #expect(t.fields?.postedAt == "2026-06-05T07:59:00.000Z" && t.fields?.precision == "time" && t.precision == "time" && t.postedAt == t.fields?.postedAt)
    let justAfter = try kept(TextRig.t0 + 12 * 3_600_000)
    #expect(justAfter.timed(arrivalMinuteMs: TextRig.t0 + 12 * 3_600_000).postedAt == "2026-06-05T19:59:00.000Z")
    #expect(justAfter.timed(arrivalMinuteMs: TextRig.t0 + 12 * 3_600_000 + 180_000).postedAt == "2026-06-05T19:56:00.000Z")
    #expect(justAfter.timed(arrivalMinuteMs: TextRig.t0 + 36 * 3_600_000 - 60_000).postedAt == "2026-06-04T20:00:00.000Z")
    #expect(justAfter.timed(arrivalMinuteMs: TextRig.t0 + 36 * 3_600_000).postedAt == "2026-06-05T19:59:00.000Z")
    #expect(justAfter.timed(arrivalMinuteMs: TextRig.t0 + 40 * 3_600_000).postedAt == "2026-06-05T15:59:00.000Z")
    let early = try kept(TextRig.t0 - 86_400_000)
    let e = early.timed(arrivalMinuteMs: TextRig.t0 - 86_400_000)
    #expect(e.fields?.postedAt == "2026-06-04T20:00:00.000Z" && e.fields?.precision == "time")
  }

  @Test("a pasted text with only a date is authored with time inside its day, keeps that date on its fallback, and waits in Review")
  func pasteTimesItsDay() async throws {
    let text = "خصم بمبلغ 234.56 في 03-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44"
    let ledger = RefusingTextLedger(refusing: 1)
    let out = await BankTextAuthor(ledger: ledger).paste(text, atMs: TextRig.t0, secret: TextRig.secret, link: .notLinked)
    #expect(out.added?.filed == false && out.added?.unparsed == true)
    let drafts = await ledger.attempts.map(\.draft)
    #expect(drafts.count == 2 && drafts.allSatisfy { $0.needsReview })
    for d in drafts {
      #expect(d.payload["posted_precision"]?.stringValue == "time" && d.payload["posted_at"]?.stringValue == "2026-06-03T07:59:00.000Z")
      #expect(try BankTextFallbackTests.folds(d))
    }
    let same = RefusingTextLedger(refusing: 0)
    _ = await BankTextAuthor(ledger: same).paste(
      text.replacingOccurrences(of: "03-06-2026", with: "05-06-2026"), atMs: TextRig.t0, secret: TextRig.secret, link: .notLinked)
    let d = try #require(await same.attempts.first?.draft)
    #expect(d.payload["posted_precision"]?.stringValue == "time" && d.payload["posted_at"]?.stringValue == "2026-06-05T08:00:00.000Z")
  }
}

@Suite("bank texts: a date-only text that arrives after its day")
struct BankTextLateDayTests {
  static let local: Int64 = 4 * 3_600_000
  static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
    TextRig.t0 - 8 * 3_600_000 - local + Int64(day - 5) * 86_400_000 + Int64(hour) * 3_600_000 + Int64(minute) * 60_000
  }

  static let debit = "خصم بمبلغ 234.56 في 04-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44"
  static let ownTransfer =
    "تحويل بين حساباتك بمبلغ AED 234.56 من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 04-06-2026 MB Fund Transfer رصيد حساب الخصم هو AED 9,876.54 وحساب الايداع هو AED 8,765.43"

  @Test("an automation that runs twice for a text dated the day before, just after midnight, gives two rows, the second held")
  func doubleRunAfterMidnight() async throws {
    let rig = try TextRig()
    let c = TextCase(name: "late", sender: "DIB-SMS", text: Self.debit, receivedAtMs: Self.at(5, 0, 1))
    let a = try #require(await rig.add(c).added)
    let b = try #require(await rig.add(c, at: Self.at(5, 0, 2) + 30_000).added)
    #expect(a.txnID != b.txnID)
    let p = try rig.payload(a.txnID)
    #expect(p["posted_precision"]?.stringValue == "time" && p["posted_at"]?.stringValue == "2026-06-04T19:58:00.000Z")
    #expect(try rig.payload(b.txnID)["posted_at"]?.stringValue == "2026-06-04T19:57:00.000Z")
    let s = try rig.fold()
    #expect(s.anomalies.isEmpty && s.txns[b.txnID]?.copyOf == a.txnID && s.txns[b.txnID]?.isHeldCopy == true)
  }

  @Test("two equal date-only texts that arrive hours apart after their day are two rows with no hold, on the next day and later")
  func equalTextsHoursApart() async throws {
    for day in [5, 6, 9] {
      let rig = try TextRig()
      let a = try #require(await rig.add(TextCase(name: "a", sender: "DIB-SMS", text: Self.debit, receivedAtMs: Self.at(day, 8, 0))).added)
      let b = try #require(await rig.add(TextCase(name: "b", sender: "DIB-SMS", text: Self.debit, receivedAtMs: Self.at(day, 14, 0))).added)
      let pa = try parseInstantMs(try #require(try rig.payload(a.txnID)["posted_at"]?.stringValue))
      let pb = try parseInstantMs(try #require(try rig.payload(b.txnID)["posted_at"]?.stringValue))
      #expect(abs(pa - pb) == 6 * 3_600_000, "day \(day)")
      for ms in [pa, pb] { #expect(ms >= Self.at(4, 0, 0) && ms < Self.at(5, 0, 0), "day \(day)") }
      let s = try rig.fold()
      #expect(s.anomalies.allSatisfy { $0.kind == "possible_duplicate" }, "day \(day)")
      for id in [a.txnID, b.txnID] { #expect(s.txns[id]?.copyOf == nil && s.txns[id]?.isHeldCopy == false && s.txns[id]?.isLive == true, "day \(day)") }
    }
  }

  @Test("a debit alert and its transfer notice that straddle midnight are a transfer pair")
  func pairAcrossMidnight() async throws {
    let rig = try TextRig()
    let notice = try #require(
      await rig.add(TextCase(name: "n", sender: "DIB-SMS", text: Self.ownTransfer, receivedAtMs: Self.at(4, 23, 58))).added)
    let alert = try #require(await rig.add(TextCase(name: "a", sender: "DIB-SMS", text: Self.debit, receivedAtMs: Self.at(5, 0, 3))).added)
    #expect(try rig.payload(notice.txnID)["posted_at"]?.stringValue == "2026-06-04T19:58:00.000Z")
    #expect(alert.transferPartner == notice.txnID && !alert.filed)
    #expect(try rig.fold().anomalies.isEmpty)
  }
}
