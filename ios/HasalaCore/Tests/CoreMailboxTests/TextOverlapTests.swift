import CoreDomain
import CoreJSON
import CoreMail
import CoreProjection
import CoreReplay
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
    #expect(BankTextTwin.matches(Twins.text("mail-no-bank", at: t), Twins.mail(bank: nil, at: at)))
  }

  @Test("another amount in the same currency, the other direction, another bank or another card is no twin")
  func notTwins() {
    let at = t + 5 * Twins.minute
    #expect(!BankTextTwin.matches(Twins.text("amount", amount: 1235, at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("credit", direction: "credit", at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("bank", bank: "dib", at: t), Twins.mail(at: at)))
    #expect(!BankTextTwin.matches(Twins.text("card", last4: "1111", at: t), Twins.mail(last4: "2222", at: at)))
  }

  @Test("the nearest twin is named")
  func nearest() {
    let rows = [Twins.text("far", at: t - 600 * Twins.minute), Twins.text("near", at: t - 3 * Twins.minute)]
    #expect(BankTextTwin.twin(of: Twins.mail(at: t), among: rows)?.id == "near")
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

@Suite("bank texts: the card link on confirm")
struct CardLinkOnConfirmTests {
  static let card = CardKey(bank: "dib", last4: "1234")

  static func confirm(_ rig: TextRig, _ id: String, inject: Bool = false) async throws -> AuthoredBlob? {
    let row = try #require(try rig.row(id))
    let ledger = rig.ledger
    let accounts = Set(try rig.observer.reader.accounts().map(\.id))
    let current = await ledger.knownCards()
    let link = CardLinkPlan.confirming(
      bank: row.bank, last4: row.last4, accounts: accounts, current: current,
      creditCards: CardLinkPlan.creditCards(rig.store))
    let ctx = try await rig.observer.authorContext()
    let blob = try rig.observer.stamps.build(ctx) { a throws(AuthorError) in
      try CardLinkPlan.apply(link, to: &a)
      a.categorize(txnID: id, parentVersion: row.version, category: "groceries", needsReview: false)
      if inject { throw AuthorError.random }
    }
    if let blob {
      try await ledger.outbox.enqueue(blob.ops)
      try await rig.observer.reproject()
    }
    return blob
  }

  static func accountSet(_ ops: [Op]) -> JSONObject? { ops.first { $0.type == .accountSet }?.payload.objectValue }

  @Test("authorCards and the confirm get the same account id, name and kind for the same card from the shared plan")
  func samePlan() async throws {
    let viaCards = try TextRig()
    try await viaCards.linkCard("dib", "1234", .mine)
    let a = try #require(Self.accountSet(try viaCards.pendingOps()))
    let viaConfirm = try TextRig()
    let added = try #require(await viaConfirm.add(try TextCase.named("dib-purchase-credit-card")).added)
    let blob = try #require(try await Self.confirm(viaConfirm, added.txnID))
    let b = try #require(Self.accountSet(blob.ops))
    #expect(a["id"] == b["id"] && a["name"] == b["name"] && a["kind"] == b["kind"])
    #expect(b["name"]?.stringValue == "DIB ···1234" && b["kind"]?.stringValue == "current")
    let link = try #require(blob.ops.first { $0.type == .cardLinked }?.payload)
    #expect(link["account"] == b["id"] && link["state"]?.stringValue == "mine")
  }

  @Test("the confirm, the card_linked and the account_set are one blob; a failure after the closure's last op leaves none of them")
  func oneBlob() async throws {
    let rig = try TextRig()
    let added = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    #expect(!added.filed)
    let before = try rig.store.pendingOps().count
    await #expect(throws: AuthorError.self) { _ = try await Self.confirm(rig, added.txnID, inject: true) }
    #expect(try rig.store.pendingOps().count == before)
    #expect(await rig.ledger.knownCards().isEmpty)
    #expect(try rig.row(added.txnID)?.needsReview == true)
    let blob = try #require(try await Self.confirm(rig, added.txnID))
    #expect(blob.ops.map(\.type) == [.accountSet, .cardLinked, .txnCategorized])
    #expect(try rig.store.pendingOps().count == before + 3)
    #expect(await rig.ledger.knownCards()[Self.card] == .mine)
    #expect(try rig.fold().anomalies.isEmpty)
  }

  @Test("after the confirm, the next text on that card from its sender files")
  func nextTextFiles() async throws {
    let rig = try TextRig()
    let first = try #require(await rig.add(try TextCase.named("dib-purchase-credit-card")).added)
    #expect(!first.filed)
    _ = try await Self.confirm(rig, first.txnID)
    let later = TextCase(
      name: "dib-purchase-same-card-next-day", sender: "DIB-SMS",
      text: "مشتريات بمبلغ 45.00 من بطاقة XX1234 في 06-06-2026 09:30 من SAMPLE STORE. الحد الائتماني المتاح 1,000.00",
      receivedAtMs: TextRig.t0 + 86_400_000)
    let next = try #require(await rig.add(later).added)
    #expect(next.filed)
    #expect(try rig.payload(next.txnID)["gates"]?["card"]?.stringValue == "known")
  }

  @Test("a card already linked mine or not_mine keeps its link; a row with no bank or no card links nothing")
  func keepsLinks() {
    let accounts: Set<String> = []
    #expect(CardLinkPlan.confirming(bank: "dib", last4: "1234", accounts: accounts, current: [Self.card: .notMine], creditCards: []).isEmpty)
    #expect(CardLinkPlan.confirming(bank: "dib", last4: "1234", accounts: accounts, current: [Self.card: .mine], creditCards: []).isEmpty)
    #expect(CardLinkPlan.confirming(bank: nil, last4: "1234", accounts: accounts, current: [:], creditCards: []).isEmpty)
    #expect(CardLinkPlan.confirming(bank: "dib", last4: "", accounts: accounts, current: [:], creditCards: []).isEmpty)
    let steps = CardLinkPlan.confirming(bank: "dib", last4: "1234", accounts: accounts, current: [:], creditCards: [Self.card])
    guard case .mine(let account, let create)? = steps.first?.link else {
      Issue.record("no link")
      return
    }
    #expect(account == OpAuthor.cardAccountID(bank: "dib", last4: "1234") && create?.kind == .creditCard)
    let existing = CardLinkPlan.confirming(bank: "dib", last4: "1234", accounts: [account], current: [:], creditCards: [])
    guard case .mine(_, let none)? = existing.first?.link else {
      Issue.record("no link")
      return
    }
    #expect(none == nil)
  }

  @Test("the plan skips what authorCards skipped: a mine card with no account asked for, a not_mine card already not_mine")
  func planSkips() {
    let other = CardKey(bank: "enbd", last4: "9999")
    let steps = CardLinkPlan.plan(
      [
        CardDecision(card: Self.card, state: .mine), CardDecision(card: other, state: .notMine),
        CardDecision(card: CardKey(bank: "dib", last4: "5555"), state: .mine),
        CardDecision(card: CardKey(bank: "dib", last4: "5555"), state: .mine),
      ], accounts: [], current: [Self.card: .mine, other: .notMine], creditCards: [])
    #expect(steps.count == 2)
    if case .mine(_, let create)? = steps.last?.link { #expect(create == nil) } else { Issue.record("no second step") }
  }
}
