import CoreDomain
import CoreJSON
import CoreMail
import CoreProjection
import CoreReplay
import CoreStore
import CoreTestSupport
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreMailbox

enum Twins {
  static let minute: Int64 = 60_000

  static func text(
    _ id: String, bank: String? = "enbd", amount: Int64 = 1234, currency: String = "AED", direction: String = "debit",
    last4: String = "", at ms: Int64, unparsed: Bool = false
  ) -> BankTextRow {
    BankTextRow(
      id: id, bank: bank, amountMinor: unparsed ? 0 : amount, currency: unparsed ? "" : currency,
      direction: unparsed ? "" : direction, last4: last4, postedMs: ms, templateRef: nil, unparsed: unparsed)
  }

  static func mail(
    bank: String? = "enbd", amount: Int64 = 1234, currency: String = "AED", direction: String = "debit", last4: String = "",
    at ms: Int64
  ) -> TextTwinMail {
    TextTwinMail(bank: bank, last4: last4, amountMinor: amount, currency: currency, direction: direction, postedMs: ms)
  }

  static func overlap(_ rows: [BankTextRow]) -> TextOverlap {
    let posted = rows.map(\.postedMs)
    return TextOverlap(
      span: TextRowSpan(oldestPostedMs: posted.min() ?? 0, newestPostedMs: posted.max() ?? 0, count: rows.count), rows: rows)
  }
}

@Suite("bank texts: the text twin of a mail (D10)")
struct TextTwinTests {
  let t = Rig.t0

  @Test("a text row with the mail's bank, direction, amount and currency within 24 hours is its twin; the merchant does not count")
  func sameFieldsMatch() {
    let mail = Twins.mail(at: t)
    #expect(BankTextTwin.matches(Twins.text("a", at: t - 7 * Twins.minute), mail))
    #expect(BankTextTwin.matches(Twins.text("b", at: t - BankTextTwin.windowMs), mail))
    #expect(BankTextTwin.matches(Twins.text("c", at: t + BankTextTwin.windowMs), mail))
    #expect(!BankTextTwin.matches(Twins.text("d", at: t - BankTextTwin.windowMs - 1), mail))
  }

  @Test("twins also match with no card on either side, a foreign amount on one side, no bank on the text, or an unparsed text")
  func looseCases() {
    let at = t + 5 * Twins.minute
    #expect(BankTextTwin.matches(Twins.text("no-card", at: t), Twins.mail(last4: "1234", at: at)))
    #expect(BankTextTwin.matches(Twins.text("card", last4: "1234", at: t), Twins.mail(at: at)))
    #expect(BankTextTwin.matches(Twins.text("same-card", last4: "1234", at: t), Twins.mail(last4: "1234", at: at)))
    #expect(BankTextTwin.matches(Twins.text("usd", amount: 2000, currency: "USD", at: t), Twins.mail(amount: 7345, at: at)))
    #expect(BankTextTwin.matches(Twins.text("no-bank", bank: nil, at: t), Twins.mail(at: at)))
    #expect(BankTextTwin.matches(Twins.text("unparsed", at: t, unparsed: true), Twins.mail(amount: 99_999, at: at)))
  }

  @Test("another amount in the same currency, the other direction, another bank or another card is no twin")
  func notTwins() {
    let at = t + 5 * Twins.minute
    #expect(!BankTextTwin.matches(Twins.text("amount", amount: 1235, at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("credit", direction: "credit", at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("bank", bank: "dib", at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("card", last4: "1111", at: t), Twins.mail(last4: "2222", at: at)))
    #expect(!BankTextTwin.matches(Twins.text("mail-no-bank", at: t), Twins.mail(bank: nil, at: at)))
    #expect(BankTextTwin.matches(Twins.text("neither", bank: nil, at: t), Twins.mail(bank: nil, at: at)))
  }

  @Test("the nearest twin is named")
  func nearest() {
    let rows = [Twins.text("far", at: t - 600 * Twins.minute), Twins.text("near", at: t - 3 * Twins.minute)]
    #expect(BankTextTwin.twin(of: Twins.mail(at: t), among: rows)?.id == "near")
  }

  @Test("the overlap keeps its rows sorted and searches only the 24 hours around a mail, bounds included")
  func window() {
    let w = BankTextTwin.windowMs
    let rows = [
      Twins.text("late", at: t + w + 1), Twins.text("edge-after", at: t + w), Twins.text("b", at: t), Twins.text("a", at: t),
      Twins.text("early", at: t - w - 1), Twins.text("edge-before", at: t - w), Twins.text("far", at: t - 30 * day),
    ]
    let o = Twins.overlap(rows)
    #expect(o.rows.map(\.id) == ["far", "early", "edge-before", "a", "b", "edge-after", "late"])
    #expect(BankTextTwin.window(o.rows, around: t, w).map(\.id) == ["edge-before", "a", "b", "edge-after"])
    #expect(BankTextTwin.window(o.rows, around: t - 10 * day, w).isEmpty)
    #expect(BankTextTwin.window([], around: t, w).isEmpty)
    #expect(BankTextTwin.window(o.rows, around: t + 5 * day, w).isEmpty)
  }

  @Test("the overlap runs from the oldest text row minus 24 hours to the newest plus 24 hours")
  func overlapSpan() {
    let o = Twins.overlap([Twins.text("old", at: t - 10 * day), Twins.text("new", at: t - 3 * day)])
    #expect(o.fromMs == t - 11 * day && o.toMs == t - 2 * day)
    #expect(o.covers(t - 11 * day) && o.covers(t - 2 * day) && !o.covers(t - 2 * day + 1) && !o.covers(t - 11 * day - 1))
  }
}

@Suite("bank texts: the overlap check on a mailbox connect (D10)")
struct TextOverlapEngineTests {
  static let amount = "12.34"

  static func byID(_ rig: Rig) async -> [String: MailboxIngestDraft] {
    Dictionary(await rig.enqueued().map { ($0.messageID, $0) }, uniquingKeysWith: { a, _ in a })
  }

  @Test("on the first connect no listed mail is skipped; a mail with a text twin waits in Review, every other mail is authored as any mail")
  func firstConnect() async throws {
    let rig = Rig()
    let texts = [Twins.text("t-old", at: Rig.t0 - 10 * day), Twins.text("t-new", at: Rig.t0 - 3 * day)]
    await rig.ledger.setTexts(Twins.overlap(texts))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "before", dateMs: Rig.t0 - 20 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "twin", dateMs: Rig.t0 - 3 * day + 5 * Twins.minute))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "other", amount: "99.99", dateMs: Rig.t0 - 5 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "after", dateMs: Rig.t0 - day))
    await rig.connectAndActivate()
    let d = await Self.byID(rig)
    #expect(Set(d.keys) == ["before", "twin", "other", "after"])
    #expect(d["twin"]?.needsReview == true && d["twin"]?.payload["needs_review"] == .bool(true))
    #expect(d["before"]?.needsReview == false && d["other"]?.needsReview == false && d["after"]?.needsReview == false)
    #expect(d["twin"]?.payload["gates"] == d["other"]?.payload["gates"])
    #expect(await rig.ledger.textReads >= 1)
  }

  @Test("the switch from texts to email holds the twin")
  func theSwitch() async throws {
    let rig = Rig()
    await rig.ledger.setTexts(Twins.overlap([Twins.text("t", at: Rig.t0 - 2 * day)]))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "twin", dateMs: Rig.t0 - 2 * day + 9 * Twins.minute))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "lone", amount: "50.00", dateMs: Rig.t0 - 2 * day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, replacing: true)
    _ = await rig.engine.runCycle(trigger: .launch)
    let d = await Self.byID(rig)
    #expect(d["twin"]?.needsReview == true && d["lone"]?.needsReview == false)
  }

  @Test("Add a mailbox after a disconnect, with texts added in between, holds the twin of a text from that gap")
  func reconnectAfterDisconnect() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.enbdAlert(id: "first", dateMs: Rig.t0 - 4 * day))
    await rig.connectAndActivate()
    #expect(await Self.byID(rig)["first"]?.needsReview == false)
    await rig.ledger.setIngested(Set(await rig.enqueued().map(\.ingestID)))
    #expect(await rig.engine.disconnect())
    rig.clock.advance(3 * day)
    await rig.ledger.setTexts(Twins.overlap([Twins.text("gap", at: Rig.t0 + day)]))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "gap-mail", dateMs: Rig.t0 + day + 2 * Twins.minute))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    _ = await rig.engine.runCycle(trigger: .launch)
    let d = await Self.byID(rig)
    #expect(d["gap-mail"]?.needsReview == true)
    #expect(await rig.accounted("first") == .dup)
  }

  @Test("a takeover (Read them here instead) holds the twin of a text added while another iPhone read the mailbox")
  func takeover() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.advance(11 * Twins.minute)
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .otherDevice)
    rig.clock.advance(day)
    await rig.ledger.setTexts(Twins.overlap([Twins.text("while-away", at: Rig.t0 + day - 30 * Twins.minute)]))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "away-twin", dateMs: Rig.t0 + day - 20 * Twins.minute))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "away-lone", amount: "7.00", dateMs: Rig.t0 + day - 10 * Twins.minute))
    await rig.server.setLink(.holder(isThisDevice: true, watchExpiresAtMs: nil))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .active)
    let d = await Self.byID(rig)
    #expect(d["away-twin"]?.needsReview == true && d["away-lone"]?.needsReview == false)
  }

  @Test("an account with no text row skips the check: the same mail files")
  func noTextRows() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.enbdAlert(id: "m", dateMs: Rig.t0 - 3 * day))
    await rig.connectAndActivate()
    #expect(await rig.ledger.textReads >= 1)
    #expect(await Self.byID(rig)["m"]?.needsReview == false)
  }

  @Test("when the text rows cannot be read, no mail is authored and the cycle stops as offline")
  func unreadableTexts() async throws {
    let rig = Rig()
    await rig.ledger.setTextFails(true)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "m", dateMs: Rig.t0 - 3 * day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == .offline && r.ops == 0)
    #expect(await rig.enqueued().isEmpty)
    await rig.ledger.setTextFails(false)
    _ = await rig.engine.runCycle(trigger: .launch)
    #expect(await Self.byID(rig)["m"]?.needsReview == false)
  }

  @Test("Add a sender pulls to head first: a text row another iPhone added holds its twin mail")
  func addASenderPullsFirst() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let syncs = await rig.ledger.syncs
    await rig.ledger.setTextsOnPull(Twins.overlap([Twins.text("peer", at: Rig.t0 - 2 * day)]))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "imp-twin", dateMs: Rig.t0 - 2 * day + 4 * Twins.minute))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "imp-lone", amount: "61.00", dateMs: Rig.t0 - 2 * day))
    let r = try await rig.engine.importSender("emiratesnbd.com").get()
    #expect(r.haltedOn == nil && r.ops == 2)
    #expect(await rig.ledger.syncs == syncs + 1)
    let d = await Self.byID(rig)
    #expect(d["imp-twin"]?.needsReview == true && d["imp-lone"]?.needsReview == false)
  }

  @Test("Add a sender that cannot pull stops as offline and authors nothing")
  func addASenderOffline() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.ledger.setSyncFails(true)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "imp", dateMs: Rig.t0 - 2 * day))
    let r = try await rig.engine.importSender("emiratesnbd.com").get()
    #expect(r.haltedOn == .offline && r.ops == 0)
    #expect(await Self.byID(rig)["imp"] == nil)
  }

  @Test("the text rows are read once for a cycle that authors mail, and not for a cycle that authors none")
  func readOnlyWhenAuthoring() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.ledger.textReads == 0)
    await rig.ledger.setTexts(Twins.overlap([Twins.text("t", at: Rig.t0 - day)]))
    _ = await rig.engine.runCycle(trigger: .silentPush)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.ledger.textReads == 0)
    rig.gmail.add(SyntheticMail.enbdAlert(id: "one", dateMs: Rig.t0 - day + Twins.minute))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "two", amount: "8.00", dateMs: Rig.t0 - day))
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.ledger.textReads == 1)
    let d = await Self.byID(rig)
    #expect(d["one"]?.needsReview == true && d["two"]?.needsReview == false)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.ledger.textReads == 1)
  }

  @Test("a mail with another amount in the same currency, or the other direction, is authored as any mail")
  func notTwinsFile() async throws {
    let rig = Rig()
    await rig.ledger.setTexts(
      Twins.overlap([
        Twins.text("amount", amount: 1299, at: Rig.t0 - 2 * day), Twins.text("credit", direction: "credit", at: Rig.t0 - 2 * day),
      ]))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "m", dateMs: Rig.t0 - 2 * day + Twins.minute))
    await rig.connectAndActivate()
    #expect(await Self.byID(rig)["m"]?.needsReview == false)
  }
}

@Suite("bank texts: the overlap from the synced ledger")
struct RuntimeTextOverlapTests {
  @Test("no text row: no overlap")
  func none() async throws {
    let rig = try TextRig()
    #expect(try await rig.ledger.textOverlap() == nil)
  }

  @Test("the span is the oldest and newest text row, archived included; the twins are the live text rows, unparsed included")
  func spanAndRows() async throws {
    let rig = try TextRig()
    let read = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    let unparsed = try #require(await rig.add(try TextCase.named("dib-arabic-no-amount")).added)
    let o = try #require(try await rig.ledger.textOverlap())
    let posted = try parseInstantMs("2026-06-05T06:11:00.000Z")
    #expect(o.fromMs == posted - BankTextTwin.windowMs && o.toMs == TextRig.t0 + BankTextTwin.windowMs)
    #expect(Set(o.rows.map(\.id)) == [read.txnID, unparsed.txnID])
    #expect(o.rows.first { $0.id == unparsed.txnID }?.unparsed == true)
    try await rig.ledger.author { a throws(AuthorError) in a.annotate(txnID: read.txnID, set: [("archived", "user")]) }
    let after = try #require(try await rig.ledger.textOverlap())
    #expect(after.fromMs == o.fromMs && after.rows.map(\.id) == [unparsed.txnID])
  }
}

@Test("the bank name table names known banks and upper-cases others")
func bankNames() {
  #expect(RuntimeMailboxLedger.bankName("dib") == "DIB")
  #expect(RuntimeMailboxLedger.bankName("ei") == "Emirates Islamic")
  #expect(RuntimeMailboxLedger.bankName("zz") == "ZZ")
}
