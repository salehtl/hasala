import CoreExtract
import CoreJSON
import CoreMail
import CoreMailbox
import CoreTemplate
import CoreTestSupport
import Foundation
import Testing

enum NovelMail {
  static let from = "DIB <notification@dib.ae>"
  static let merchants = ["SAMPLE BOOKSHOP", "SAMPLE BAKERY", "SAMPLE PHARMACY", "SAMPLE GARAGE", "SAMPLE FLORIST", "SAMPLE CINEMA"]

  static func card(
    _ i: Int, amount: String, merchant: String? = nil, on: String = "", dateMs: Int64, to: String? = SyntheticMail.defaultTo
  ) -> FakeGmail.Message {
    let body =
      "Hello,\nYour purchase of AED \(amount) at \(merchant ?? merchants[i % merchants.count]) was charged to your card ending 4321\(on).\n"
      + "Thank you for choosing us."
    return FakeGmail.Message(
      id: "nv\(i)",
      raw: SyntheticMail.rfc822(from: from, subject: "Account activity", body: body, dateMs: dateMs, authDomain: "dib.ae", to: to),
      internalDateMs: dateMs, from: from)
  }

  static func pending(_ id: String, amount: String, dateMs: Int64) -> FakeGmail.Message {
    let body =
      "Dear Customer,\nYour fund transfer of AED \(amount) to SAMPLE BENEFICIARY has been initiated.\nStatus: In process\n"
      + "You will be notified when it completes."
    return FakeGmail.Message(
      id: id,
      raw: SyntheticMail.rfc822(from: from, subject: "Transfer request", body: body, dateMs: dateMs, authDomain: "dib.ae"),
      internalDateMs: dateMs, from: from)
  }

  static func enbdForeign(_ id: String, usd: String = "12.50", aed: String = "45.91", dateMs: Int64) -> FakeGmail.Message {
    let from = "Emirates NBD <alerts@emiratesnbd.com>"
    let body = "USD\(usd) has been debited from your account 012XXX34XXX56. AED \(aed) debited in local currency."
    return FakeGmail.Message(
      id: id,
      raw: SyntheticMail.rfc822(
        from: from, subject: "Transaction advice for your account ending with 8642", body: body, dateMs: dateMs,
        authDomain: "emiratesnbd.com"),
      internalDateMs: dateMs, from: from)
  }
}

extension NovelMail {
  static func enbdWithdrawal(_ id: String, tail: String, dateMs: Int64) -> FakeGmail.Message {
    let from = "Emirates NBD <alerts@emiratesnbd.com>"
    let body = "AED120.00 has been withdrawn from your account 012XXX34XXX56. \(tail)"
    return FakeGmail.Message(
      id: id,
      raw: SyntheticMail.rfc822(
        from: from, subject: "Transaction advice for your account ending with 8642", body: body, dateMs: dateMs,
        authDomain: "emiratesnbd.com"),
      internalDateMs: dateMs, from: from)
  }
}

@Suite struct TemplateFreeDispositionTests {
  let templates = BundledTemplates.load().templates
  let trusted = ["dib.ae", "emiratesnbd.com"]

  func parse(_ m: FakeGmail.Message, _ reader: inout MailReaderState?) -> MessageDisposer.Parse {
    MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
      bankDomains: trusted, trusted: trusted, provider: .gmail, linkedAddress: SyntheticMail.defaultTo, spam: false,
      reader: &reader, analyze: AuthResults.analyze)
  }

  func mail(_ m: FakeGmail.Message, _ reader: inout MailReaderState?) throws -> ParsedMail {
    guard case .mail(let p) = parse(m, &reader) else { throw CancellationError() }
    return p
  }

  func finalize(_ p: ParsedMail) -> MailboxIngestDraft {
    MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [:], categorizer: NoCategorizer())
  }

  func learned(_ count: Int) throws -> MailReaderState? {
    var reader: MailReaderState? = MailReaderState()
    for i in 0..<count {
      _ = try mail(NovelMail.card(i, amount: "\(10 + i * 7).\(10 + i)", dateMs: Rig.t0 + Int64(i) * 60_000), &reader)
    }
    return reader
  }

  @Test func withoutAReaderANovelLayoutIsTheEmptyReviewShape() throws {
    var none: MailReaderState?
    let p = try mail(NovelMail.card(0, amount: "123.45", dateMs: Rig.t0), &none)
    #expect(p.fields == nil && p.gates.reader == nil && none == nil)
  }

  @Test func aFirstNovelMailGoesToReviewPrefilled() throws {
    var reader: MailReaderState? = MailReaderState()
    let p = try mail(NovelMail.card(0, amount: "123.45", dateMs: Rig.t0), &reader)
    #expect(p.gates.template == nil && p.gates.reader == "extract@1" && p.readerConfident == false)
    #expect(p.bank == "dib" && p.gates.kind == "card_purchase")
    let f = try #require(p.fields)
    #expect(f.amountMinor == 12_345 && f.currency == "AED" && f.direction == "debit" && f.last4 == "4321")
    let d = finalize(p)
    #expect(d.needsReview && d.payload["needs_review"] == .bool(true))
    #expect(d.payload["unparsed"] == .bool(false) && d.payload["tier"] == .string("heuristic"))
    #expect(d.payload["amount_minor"] == .string("12345") && d.payload["bank"] == .string("dib"))
    #expect(d.payload["gates"]?["template"] == .string("none") && d.payload["gates"]?["reader"] == .string("extract@1"))
    #expect(reader?.counts["dib"]?.readerOnly == 1)
  }

  @Test func anAgreedTrustedReadingFilesWithoutReview() throws {
    var reader = try learned(5)
    let p = try mail(NovelMail.card(9, amount: "77.70", merchant: "SAMPLE TAILOR", dateMs: Rig.t0 + 3_600_000), &reader)
    #expect(p.readerConfident == true, "\(p)")
    let d = finalize(p)
    #expect(!d.needsReview && d.payload["amount_minor"] == .string("7770") && d.payload["tier"] == .string("heuristic"))
    #expect(d.payload["gates"]?["card"] == .string("unknown"))
    #expect(reader?.counts["dib"]?.readerOnly == 6)
  }

  @Test func anAgreedReadingStillNeedsEveryTrustGate() throws {
    var reader = try learned(5)
    let other = try mail(
      NovelMail.card(9, amount: "77.70", merchant: "SAMPLE TAILOR", dateMs: Rig.t0 + 3_600_000, to: "someone.else@example.net"),
      &reader)
    #expect(other.readerConfident == true && other.recipient == .mismatch)
    #expect(finalize(other).needsReview)
    var spoofed = try mail(NovelMail.card(10, amount: "66.60", merchant: "SAMPLE TAILOR", dateMs: Rig.t0 + 3_700_000), &reader)
    spoofed.gates.senderTrusted = false
    #expect(finalize(spoofed).needsReview)
  }

  @Test func aStagedReaderRowWithoutTheConfidenceFactStaysInReview() throws {
    var reader = try learned(5)
    let p = try mail(NovelMail.card(9, amount: "77.70", merchant: "SAMPLE TAILOR", dateMs: Rig.t0 + 3_600_000), &reader)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    json.removeValue(forKey: "readerConfident")
    let old = try JSONDecoder().decode(ParsedMail.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(finalize(old).needsReview)
    var gates = json["gates"] as! [String: Any]
    gates.removeValue(forKey: "reader")
    gates.removeValue(forKey: "kind")
    let legacy = try JSONDecoder().decode(MailGates.self, from: JSONSerialization.data(withJSONObject: gates))
    #expect(legacy.reader == nil && legacy.kind == nil)
  }

  @Test func aPendingTransferIsSetAside() throws {
    var reader: MailReaderState? = MailReaderState()
    let r = parse(NovelMail.pending("p1", amount: "500.00", dateMs: Rig.t0), &reader)
    #expect(r == .setAside(domain: "dib.ae"))
    #expect(reader?.counts["dib"]?.pendingSetAside == 1)

    var arabic: MailReaderState? = MailReaderState()
    let t = parse(SyntheticMail.dibTransferNotice(id: "p2", day: "29-05-2026", status: "قيد التنفيذ", dateMs: Rig.t0), &arabic)
    #expect(t == .setAside(domain: "dib.ae"))
  }

  @Test func aTemplateHitKeepsItsFieldsAndRecordsItsKind() throws {
    var none: MailReaderState?
    var reader: MailReaderState? = MailReaderState()
    for m in [
      SyntheticMail.dibCard(id: "c1", dateMs: Rig.t0),
      SyntheticMail.dibTransferNotice(id: "c2", day: "29-05-2026", dateMs: Rig.t0),
      SyntheticMail.dibDebitAlert(id: "c3", day: "29-05-2026", dateMs: Rig.t0),
    ] {
      let plain = try mail(m, &none)
      let read = try mail(m, &reader)
      #expect(read.fields == plain.fields && read.gates.template == plain.gates.template && read.gates.reader == nil)
      #expect(read.readerConfident == nil)
      #expect(finalize(read).needsReview == finalize(plain).needsReview)
      #expect(finalize(read).payload["tier"] == .string("template"))
    }
    let notice = try mail(SyntheticMail.dibTransferNotice(id: "c2", day: "29-05-2026", dateMs: Rig.t0), &none)
    #expect(notice.gates.kind == nil && notice.gates.template == "dib.transfer.v1@1")
    #expect(finalize(notice).payload["gates"]?["kind"] == nil)
    let counts = try #require(reader?.counts["dib"])
    #expect(counts.templateHit == 3 && counts.readerAgreed + counts.readerDisagreed == 3 && counts.readerOnly == 0)
  }

  @Test func aTemplateThatReadsTheForeignAmountTakesTheAEDAmount() throws {
    var none: MailReaderState?
    let p = try mail(NovelMail.enbdForeign("f1", dateMs: Rig.t0), &none)
    #expect(p.gates.template?.hasPrefix("enbd.alert.v1@") == true)
    let f = try #require(p.fields)
    #expect(f.amountMinor == 4_591 && f.currency == "AED" && f.direction == "debit")
    #expect(p.held == true && finalize(p).needsReview)
  }

  @Test func theAEDAmountOfATemplateHitFilesItselfOnlyWhenTheReadersAgree() throws {
    var reader: MailReaderState? = MailReaderState()
    var fresh: MailReaderState? = MailReaderState()
    var last: ParsedMail?
    for i in 0..<6 {
      last = try mail(NovelMail.enbdForeign("f\(i)", usd: "\(12 + i).50", aed: "\(45 + i * 4).91", dateMs: Rig.t0 + Int64(i) * 60_000), &reader)
    }
    let first = try mail(NovelMail.enbdForeign("g0", dateMs: Rig.t0), &fresh)
    #expect(first.held == true && finalize(first).needsReview)
    let p = try #require(last)
    #expect(p.fields?.amountMinor == 6_591 && p.fields?.currency == "AED")
    #expect(p.held == nil && !finalize(p).needsReview, "\(p)")
  }

  @Test func aPendingPhraseCannotSetATemplateHitAside() throws {
    var reader: MailReaderState? = MailReaderState()
    let p = try mail(NovelMail.enbdWithdrawal("w1", tail: "Any remaining instalments will be processed as scheduled.", dateMs: Rig.t0), &reader)
    #expect(p.gates.template?.hasPrefix("enbd.alert.v1@") == true && p.fields?.amountMinor == 12_000)
    #expect(p.held == true && finalize(p).needsReview)
    #expect(reader?.counts["enbd"]?.pendingSetAside ?? 0 == 0)

    let plain = try mail(NovelMail.enbdWithdrawal("w2", tail: "Thank you.", dateMs: Rig.t0), &reader)
    #expect(plain.held == nil && !finalize(plain).needsReview)
  }

  @Test func aPendingStatusWithNoReadableAmountIsSetAside() throws {
    var reader: MailReaderState? = MailReaderState()
    let body = "Dear Customer,\nYour fund transfer request to SAMPLE BENEFICIARY was received.\nStatus: In process"
    let m = FakeGmail.Message(
      id: "u1", raw: SyntheticMail.rfc822(from: NovelMail.from, subject: "Transfer request", body: body, dateMs: Rig.t0, authDomain: "dib.ae"),
      internalDateMs: Rig.t0, from: NovelMail.from)
    #expect(parse(m, &reader) == .setAside(domain: "dib.ae"))
    #expect(reader?.counts["dib"]?.pendingSetAside == 1)
  }

  @Test func aReaderRowTakesTheDateTheMailStates() throws {
    var reader: MailReaderState? = MailReaderState()
    let timed = try mail(NovelMail.card(0, amount: "12.00", on: " on 26-05-2026 14:05", dateMs: Rig.t0), &reader)
    #expect(timed.fields?.postedAt == "2026-05-26T10:05:00.000Z" && timed.fields?.precision == "time")
    let dayOnly = try mail(NovelMail.card(1, amount: "13.00", on: " on 26 May 2026", dateMs: Rig.t0), &reader)
    #expect(dayOnly.fields?.postedAt == "2026-05-25T20:00:00.000Z" && dayOnly.fields?.precision == "day")
    let sameDay = try mail(NovelMail.card(2, amount: "14.00", on: " on 29-05-2026 09:00", dateMs: Rig.t0), &reader)
    #expect(sameDay.fields?.postedAt == "2026-05-28T20:26:40.000Z" && sameDay.fields?.precision == "time")
    let none = try mail(NovelMail.card(3, amount: "15.00", dateMs: Rig.t0), &reader)
    #expect(none.fields?.postedAt == "2026-05-28T20:26:40.000Z" && none.fields?.precision == "time")
    let future = try mail(NovelMail.card(4, amount: "16.00", on: " on 26-06-2026", dateMs: Rig.t0), &reader)
    #expect(future.fields?.precision == "time")
  }

  @Test func unverifiedMailTeachesNoLayout() throws {
    var reader: MailReaderState? = MailReaderState()
    for i in 0..<5 {
      let body = "Hello,\nYour purchase of AED \(10 + i).00 at SAMPLE SHOP was charged to your card ending 4321."
      let m = FakeGmail.Message(
        id: "s\(i)", raw: SyntheticMail.rfc822(from: NovelMail.from, subject: "Account activity", body: body, dateMs: Rig.t0, authDomain: nil),
        internalDateMs: Rig.t0, from: NovelMail.from)
      let p = try mail(m, &reader)
      #expect(p.gates.reader != nil && p.readerConfident == false)
    }
    #expect(reader?.layouts.isEmpty == true)
    let trusted = try learned(2)
    #expect(trusted?.layouts.senders.keys.contains("dib.ae") == true)
  }

  @Test func anOversizedMemoryDropsTheLeastRecentSenderFirst() throws {
    var reader = try learned(5)
    for i in 0..<3 {
      _ = try mail(NovelMail.enbdForeign("e\(i)", usd: "\(12 + i).50", aed: "\(45 + i * 4).91", dateMs: Rig.t0 + Int64(i) * 60_000), &reader)
    }
    let state = try #require(reader)
    #expect(state.layouts.senders.count == 2)
    let full = try #require(state.encoded())
    let trimmed = try #require(MailReaderState.decoded(state.encoded(limit: full.count - 1)))
    #expect(Array(trimmed.layouts.senders.keys) == ["emiratesnbd.com"])
    #expect(trimmed.counts == state.counts)
  }
}

@Suite struct TemplateFreeEngineTests {
  @Test(arguments: [Backend.sqlite, .memory])
  func learnedLayoutsPersistAcrossCycles(_ backend: Backend) async throws {
    let rig = Rig(backend: backend)
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    for i in 0..<5 {
      rig.gmail.add(NovelMail.card(i, amount: "\(10 + i * 7).\(10 + i)", dateMs: rig.clock.nowMs() - 10_000 + Int64(i) * 1_000))
    }
    let first = await rig.engine.runCycle(trigger: .refresh)
    #expect(first.ops == 5 && first.review >= 1, "\(first)")
    let saved = try #require(try await rig.store.loadReader())
    #expect(!saved.layouts.isEmpty && saved.counts["dib"]?.readerOnly == 5)

    rig.clock.advance(60_000)
    rig.gmail.add(NovelMail.card(9, amount: "77.70", merchant: "SAMPLE TAILOR", dateMs: rig.clock.nowMs() - 1_000))
    let second = await rig.engine.runCycle(trigger: .refresh)
    #expect(second.ops == 1 && second.review == 0, "\(second)")
    let row = try #require(await rig.enqueued().first { $0.messageID == "nv9" })
    #expect(row.payload["tier"] == .string("heuristic") && row.payload["needs_review"] == .bool(false))
    #expect(await rig.engine.readerCounts()["dib"]?.readerOnly == 6)
  }

  @Test func aPendingNoticeIsSetAsideAndShown() async throws {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    rig.gmail.add(NovelMail.pending("p1", amount: "500.00", dateMs: rig.clock.nowMs() - 1_000))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.setAside == 1, "\(r)")
    #expect(await rig.accounted("p1") == .setAside)
    #expect(await rig.engine.status().setAside.contains { $0.domain == "dib.ae" && $0.count == 1 })
    #expect(await rig.engine.readerCounts()["dib"]?.pendingSetAside == 1)
  }

  @Test func theFirstScanReadsNewestFirstAndStillLearns() async throws {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    let day: Int64 = 86_400_000
    for i in 0..<6 {
      rig.gmail.add(NovelMail.card(i, amount: "\(20 + i).00", dateMs: Rig.t0 - 40 * day + Int64(i) * day))
    }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let reports = await rig.engine.runFirstScan()
    #expect(reports.last?.phase == .active, "\(reports)")
    let order = await rig.enqueued().map(\.messageID)
    #expect(order == (0..<6).map { "nv\($0)" })
    let rows = await rig.enqueued()
    #expect(rows.last?.needsReview == true && rows.first?.needsReview == false)
  }

  @Test func disconnectForgetsTheLearnedLayouts() async throws {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    rig.gmail.add(NovelMail.card(0, amount: "12.00", dateMs: rig.clock.nowMs() - 1_000))
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(try await rig.store.loadReader() != nil)
    var c = MailboxCommit()
    c.clearAll = true
    try await rig.store.commit(c)
    #expect(try await rig.store.loadReader() == nil)
  }
}
