import CoreDomain
import CoreJSON
import CoreMailbox
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreStore
import CoreSync
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Bank texts in Review and Activity")
struct BankTextsReviewTests {
  typealias Mapper = LiveLedgerMapperTests

  static let secret = Data((0..<32).map { UInt8($0 &* 5 &+ 1) })
  static let june5: Int64 = 1_780_646_400_000
  static let purchase = "مشتريات بمبلغ 123.45 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
  static let nextPurchase = "مشتريات بمبلغ 45.00 من بطاقة XX1234 في 06-06-2026 09:30 من SAMPLE STORE. الحد الائتماني المتاح 1,000.00"
  static let noAmount = "تم خصم مبلغ من بطاقتك XX1234 لدى SAMPLE SHOP"
  static let debit = "خصم بمبلغ 234.56 في 05-06-2026 OUTGOING DOMESTIC FUND TR رصيدك الحالى4,444.44"
  static let ownTransfer =
    "تحويل بين حساباتك بمبلغ AED 234.56 من حساب 001-000-123XXXX-01 الي حساب 001-000-456XXXX-01 في 05-06-2026 MB Fund Transfer رصيد حساب الخصم هو AED 9,876.54 وحساب الايداع هو AED 8,765.43"

  struct Live {
    let a: Mapper.Account
    let ledger: RuntimeMailboxLedger
    let texts: BankTextAuthor
    let store: LiveLedgerStore
    var reader: LedgerReader { a.projection.reader }

    func add(_ text: String, sender: String? = "DIB-SMS", at ms: Int64 = BankTextsReviewTests.june5) async throws -> BankTextAdded {
      let outcome = await texts.add(
        BankTextArrival(text: text, sender: sender, receivedAtMs: ms), secret: BankTextsReviewTests.secret, link: { .notLinked })
      guard case .added(let added) = outcome else { throw Failure.notAdded("\(outcome)") }
      await store.reload()
      return added
    }

    func ops() throws -> [Op] { try a.context.store.pendingOps().map(LiveSortingTests.decode) }

    func cards() throws -> [CardKey: CardState] { CardLinkPlan.current(try reader.cards()) }

    func ingestMail(_ fields: [(String, JSONValue)], id: String) async throws {
      var p = JSONObject([
        ("currency", .string("AED")), ("direction", .string("debit")), ("posted_precision", .string("time")),
        ("merchant_raw", .string("SAMPLE SHOP LLC")), ("last4", .string("1234")), ("needs_review", .bool(true)),
        ("unparsed", .bool(false)), ("tier", .string("template")), ("entry_method", .string("mailbox")), ("bank", .string("dib")),
        ("provenance", .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string("g")), ("message_id", .string(id))]))),
        ("gates", .object(JSONObject([
          ("ar", .string("pass")), ("sender", .string("trusted")), ("template", .string("dib.card.v1@1")),
          ("card", .string("unknown")), ("forwarded", .bool(false)),
        ]))),
      ])
      for (k, v) in fields { p[k] = v }
      let ingest = String(repeating: String(id.count % 10), count: 64)
      let blob = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
        try o.ingest(payload: p, ingestID: ingest)
      }
      if let blob { try await a.outbox.enqueue(blob.ops) }
      try await a.observer.reproject()
      await store.reload()
    }
  }

  enum Failure: Error { case notAdded(String) }

  static func live(_ suite: String) async throws -> Live {
    let a = try Mapper.account()
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let ledger = RuntimeMailboxLedger(
      engine: SyncEngine(context: a.context, observer: a.observer), observer: a.observer, outbox: a.outbox,
      authoring: MailboxAuthoring(observer: a.observer))
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: defaults), clock: { MayaLedger.now })
    await store.reload()
    return Live(a: a, ledger: ledger, texts: BankTextAuthor(ledger: ledger), store: store)
  }

  static let card = CardKey(bank: "dib", last4: "1234")

  @Test func sortingATextRowInReviewLinksItsCardInTheSameBlobAndTheNextTextFiles() async throws {
    let l = try await Self.live("texts.review.confirm")
    let first = try await l.add(Self.purchase)
    #expect(!first.filed && l.store.state.txn(first.txnID)?.inReview == true)
    let before = try l.ops().count
    _ = try #require(try l.store.apply(.categorize(first.txnID, "groceries", learnRule: false, project: nil)))
    try await Mapper.eventually { try l.reader.txn(first.txnID)?.needsReview == false }
    let added = try Array(l.ops().dropFirst(before))
    #expect(added.map(\.type) == [.accountSet, .cardLinked, .txnCategorized])
    let account = try #require(added.first?.payload.objectValue)
    #expect(account["name"]?.stringValue == "DIB ···1234" && account["kind"]?.stringValue == "credit_card")
    #expect(added[1].payload["account"] == account["id"] && added[1].payload["state"]?.stringValue == "mine")
    #expect(try l.cards()[Self.card] == .mine)
    let next = try await l.add(Self.nextPurchase, at: Self.june5 + 86_400_000)
    #expect(next.filed)
  }

  @Test func theConfirmIsOneBlobAndAFailureAfterItsLastOpLeavesNone() async throws {
    let l = try await Self.live("texts.review.blob")
    let first = try await l.add(Self.purchase)
    let row = try #require(try l.reader.txn(first.txnID))
    let author = LedgerEditAuthor(observer: l.a.observer, outbox: l.a.outbox)
    let link = try author.confirmLink(row)
    #expect(link.count == 1)
    let body = LedgerEditAuthor.confirming(row, category: "groceries", project: nil, link: link)
    let before = try l.ops().count
    let ctx = try await l.a.observer.authorContext()
    #expect(throws: AuthorError.self) {
      _ = try l.a.observer.stamps.build(ctx) { a throws(AuthorError) in
        try body(&a)
        throw AuthorError.random
      }
    }
    #expect(try l.ops().count == before)
    #expect(try l.cards()[Self.card] == nil && l.reader.txn(first.txnID)?.needsReview == true)
    let blob = try #require(try l.a.observer.stamps.build(ctx, body))
    #expect(blob.ops.map(\.type) == [.accountSet, .cardLinked, .txnCategorized])
  }

  @Test func aCardAlreadyNotMineStaysNotMineAndAFiledRowLinksNothing() async throws {
    let l = try await Self.live("texts.review.keep")
    try await l.ledger.authorCards([CardDecision(card: Self.card, state: .notMine)])
    let row = try await l.add(Self.purchase)
    #expect(!row.filed)
    let before = try l.ops().count
    _ = try l.store.apply(.categorize(row.txnID, "groceries", learnRule: false, project: nil))
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.needsReview == false }
    #expect(try l.ops().dropFirst(before).map(\.type) == [.txnCategorized])
    #expect(try l.cards()[Self.card] == .notMine)

    let m = try await Self.live("texts.review.filed")
    try await m.ledger.authorCards([CardDecision(card: Self.card, state: .mine)])
    let filed = try await m.add(Self.purchase)
    #expect(filed.filed)
    let start = try m.ops().count
    _ = try m.store.apply(.categorize(filed.txnID, "shopping", learnRule: false, project: nil))
    try await Mapper.eventually { try m.reader.txn(filed.txnID)?.category == "shopping" }
    #expect(try m.ops().dropFirst(start).map(\.type) == [.txnCategorized])
  }

  @Test func aReaderRowLeftUnconfirmedLinksNoCard() async throws {
    let l = try await Self.live("texts.review.reader")
    let before = try l.ops().count
    let row = try await l.add("Purchase of AED 75.00 on card XX4321 at SAMPLE MARKET was successful", sender: nil)
    #expect(!row.filed)
    #expect(try l.ops().dropFirst(before).map(\.type) == [.txnIngested])
    #expect(try l.cards()[CardKey(bank: "", last4: "4321")] == nil)
  }

  @Test func addingACategoryAndSortingLinksTheCardToo() async throws {
    let l = try await Self.live("texts.review.addAndSort")
    let row = try await l.add(Self.purchase)
    let draft = CategoryDraft(id: l.store.newCategoryID(), name: "VPN", glyph: .subscriptions, parent: "subscriptions")
    _ = try l.store.apply(.addCategoryAndSort(draft, row.txnID, alwaysUse: false, project: nil))
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.needsReview == false }
    #expect(try l.cards()[Self.card] == .mine)
  }

  static func inOrder(_ types: [OpType], _ wanted: [OpType]) -> Bool {
    var i = types.startIndex
    for w in wanted {
      guard let j = types[i...].firstIndex(of: w) else { return false }
      i = types.index(after: j)
    }
    return true
  }

  @Test func alwaysUseItOnATextRowLinksTheCardInTheFirstBlobAndUndoForgetsIt() async throws {
    let l = try await Self.live("texts.review.alwaysUse")
    let row = try await l.add(Self.purchase)
    #expect(try l.reader.txn(row.txnID)?.merchantGroup != nil)
    let before = try l.ops().count
    let token = try #require(try l.store.apply(.categorize(row.txnID, "groceries", learnRule: true, project: nil)))
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.needsReview == false }
    let types = try l.ops().dropFirst(before).map(\.type)
    #expect(Array(types.prefix(3)) == [.accountSet, .cardLinked, .txnCategorized])
    #expect(types.contains(.ruleAdded))
    #expect(try l.cards()[Self.card] == .mine)
    l.store.undo(token)
    try await Mapper.eventually { try l.cards()[Self.card] == nil }
  }

  @Test func addingACategoryWithAlwaysUseItLinksTheCardInTheFirstBlobAndUndoForgetsIt() async throws {
    let l = try await Self.live("texts.review.addAlwaysUse")
    let row = try await l.add(Self.purchase)
    let before = try l.ops().count
    let draft = CategoryDraft(id: l.store.newCategoryID(), name: "VPN", glyph: .subscriptions, parent: "subscriptions")
    let token = try #require(try l.store.apply(.addCategoryAndSort(draft, row.txnID, alwaysUse: true, project: nil)))
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.needsReview == false }
    let types = try l.ops().dropFirst(before).map(\.type)
    #expect(Self.inOrder(types, [.accountSet, .cardLinked, .txnCategorized, .ruleAdded]))
    #expect(types.firstIndex(of: .ruleAdded).map { r in !types[..<r].contains(.txnSplit) } == true)
    #expect(try l.cards()[Self.card] == .mine)
    l.store.undo(token)
    try await Mapper.eventually { try l.cards()[Self.card] == nil }
  }

  @Test func markingATextRowATransferOrARefundOrSplittingItLinksTheCardAndUndoForgetsIt() async throws {
    let edits: [(String, (String) -> LedgerEdit, OpType)] = [
      ("transfer", { .markTransfer($0) }, .txnCategorized),
      ("refund", { .markRefund($0) }, .txnCategorized),
      ("split", { id in
        .split(id, [
          SplitLine(id: 0, categoryID: "groceries", amount: .aed(100_00)), SplitLine(id: 1, categoryID: "shopping", amount: .aed(23_45)),
        ])
      }, .txnSplit),
    ]
    for (name, edit, op) in edits {
      let l = try await Self.live("texts.review.mark.\(name)")
      let row = try await l.add(Self.purchase)
      let before = try l.ops().count
      let token = try #require(try l.store.apply(edit(row.txnID)), "\(name)")
      try await Mapper.eventually { try l.cards()[Self.card] == .mine }
      #expect(try l.ops().dropFirst(before).map(\.type) == [.accountSet, .cardLinked, op], "\(name)")
      l.store.undo(token)
      try await Mapper.eventually { try l.cards()[Self.card] == nil }
    }
  }

  @Test func takingARefundBackLinksNoCard() async throws {
    let l = try await Self.live("texts.review.refundBack")
    let row = try await l.add(Self.purchase)
    let version = try #require(try l.reader.txn(row.txnID)?.version)
    let blob = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      o.categorize(txnID: row.txnID, parentVersion: version, category: "refunds", needsReview: true)
    }
    if let blob { try await l.a.outbox.enqueue(blob.ops) }
    try await l.a.observer.reproject()
    await l.store.reload()
    #expect(try l.reader.txn(row.txnID)?.category == "refunds" && l.reader.txn(row.txnID)?.needsReview == true)
    let before = try l.ops().count
    _ = try l.store.apply(.markRefund(row.txnID))
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.category == nil }
    #expect(try l.ops().dropFirst(before).map(\.type) == [.txnCategorized])
    #expect(try l.cards()[Self.card] == nil)
  }

  @Test func undoingTheSortForgetsTheCardItLinked() async throws {
    let l = try await Self.live("texts.review.undo")
    let row = try await l.add(Self.purchase)
    let token = try #require(try l.store.apply(.categorize(row.txnID, "groceries", learnRule: false, project: nil)))
    try await Mapper.eventually { try l.cards()[Self.card] == .mine }
    l.store.undo(token)
    try await Mapper.eventually { try l.cards()[Self.card] == nil }
    #expect(try l.cards()[Self.card] == nil)
    #expect(try l.reader.txn(row.txnID)?.needsReview == true)
  }

  @Test func aTextRowShowsBankTextAsItsSource() async throws {
    let l = try await Self.live("texts.review.source")
    let row = try await l.add(Self.purchase)
    let t = try #require(l.store.state.txn(row.txnID))
    let p = try #require(t.provenance)
    #expect(p.isText && t.fromText && p.title == "Bank text from DIB" && p.readAt == "Received 12:00 · read automatically")
    #expect(p.senderCheck == nil && p.rawMerchant == "SAMPLE SHOP")
    let card = ReviewEngine.card(t, l.store.state)
    #expect(card.fromText && card.rawMerchant == "SAMPLE SHOP")
    #expect(LedgerStateMapper.textSource(nil) == "Bank text" && LedgerStateMapper.textSource("adcb") == "Bank text from ADCB")
  }

  @Test func anUnreadableTextIsKeptOutOfTheUnreadMailListWithItsOwnCopy() async throws {
    let l = try await Self.live("texts.review.unread")
    let row = try await l.add(Self.noAmount)
    #expect(row.unparsed)
    let s = l.store.state
    #expect(s.unreadMail.isEmpty && ReviewEngine.unreadCount(s) == 0)
    let text = try #require(s.unreadTexts.first)
    #expect(s.unreadTexts.count == 1 && text.id == row.txnID && text.bank == "DIB")
    #expect(text.receivedAt == LocalDateTime(2026, 6, 5, 12, 0))
    #expect(s.txn(row.txnID) == nil)
    let today = MayaLedger.now.date
    #expect(
      ReviewEngine.unreadTextBody(text, today: today, canPaste: true)
        == "Hasala couldn't read this bank text. Find the text from DIB at 12:00 on Fri 5 Jun in Messages, copy it and paste it here, or add the payment yourself.")
    #expect(
      ReviewEngine.unreadTextBody(text, today: today, canPaste: false)
        == "Hasala couldn't read this bank text. Find the text from DIB at 12:00 on Fri 5 Jun in Messages and add the payment yourself.")
    #expect(ReviewEngine.unreadTextTitle(text) == "Text from DIB")
    #expect(ReviewEngine.unreadTextLine(1) == "1 bank text we couldn't read" && ReviewEngine.unreadTextLine(2) == "2 bank texts we couldn't read")
    let token = try #require(try l.store.apply(.archive(row.txnID, true)))
    #expect(token.title == "Dismissed" && l.store.state.unreadTexts.isEmpty)
    try await Mapper.eventually { try l.reader.txn(row.txnID)?.archived != nil }
  }

  @Test func theTransferPairHoldNamesTheOtherText() async throws {
    let l = try await Self.live("texts.review.pair")
    let first = try await l.add(Self.debit)
    let second = try await l.add(Self.ownTransfer, at: Self.june5 + 29 * 60_000)
    #expect(second.transferPartner == first.txnID && !second.filed)
    let t = try #require(l.store.state.txn(second.txnID))
    #expect(t.mayRepeat == MayRepeat(of: first.txnID, line: "This may be the same transfer as the bank text from DIB at 12:00."))
    #expect(t.activeReviewReason == .mayRepeat)
    let card = ReviewEngine.card(t, l.store.state)
    #expect(card.reviewReason == .mayRepeat && card.reasonLine == t.mayRepeat?.line)
    #expect(ReviewEngine.tabRow(card, l.store.state).subtitle.hasPrefix("Same payment? · you decide"))
    let detail = try #require(TransactionEngine.detail(second.txnID, l.store.state, now: MayaLedger.now))
    #expect(detail.reviewReason == .mayRepeat && detail.reasonLine == t.mayRepeat?.line)
  }

  @Test func aMailWithATextTwinNamesItAndAnotherAmountDoesNot() async throws {
    let l = try await Self.live("texts.review.twin")
    let text = try await l.add(Self.purchase)
    try await l.ingestMail(
      [("amount_minor", .string("12345")), ("posted_at", .string("2026-06-05T06:20:00.000Z"))], id: "m-twin")
    try await l.ingestMail(
      [("amount_minor", .string("99900")), ("posted_at", .string("2026-06-05T06:25:00.000Z"))], id: "m-other-amount")
    let mails = l.store.state.txns.filter { $0.provenance?.isText == false && $0.postedAt.date == LocalDate(2026, 6, 5) }
    let twin = try #require(mails.first { $0.amount.minor == 12345 })
    #expect(twin.mayRepeat == MayRepeat(of: text.txnID, line: "This may be the same payment as a bank text from DIB on 5 June."))
    #expect(twin.activeReviewReason == .mayRepeat)
    #expect(mails.first { $0.amount.minor == 99900 }?.mayRepeat == nil)
    #expect(l.store.state.txn(text.txnID)?.mayRepeat == nil)
  }

  @Test func aMailHeldForAnUnparsedTextNamesItsTwin() async throws {
    let l = try await Self.live("texts.review.unparsedTwin")
    let text = try await l.add(Self.noAmount)
    #expect(text.unparsed)
    try await l.ingestMail(
      [("amount_minor", .string("12345")), ("posted_at", .string("2026-06-05T08:20:00.000Z"))], id: "m-unparsed-twin")
    let mail = try #require(l.store.state.txns.first { $0.provenance?.isText == false && $0.amount.minor == 12345 })
    #expect(mail.mayRepeat == MayRepeat(of: text.txnID, line: "This may be the same payment as a bank text from DIB on 5 June."))
    #expect(mail.activeReviewReason == .mayRepeat)
    #expect(ReviewEngine.card(mail, l.store.state).reasonLine == mail.mayRepeat?.line)
  }

  @Test func theBellListsUnreadTextsAndOpensTheirPage() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaTexts.state))
    let home = HomeViewModel(app: app)
    let item = try #require(home.bell.needsALook.first { $0.id == "unreadTexts" })
    #expect(item.title == "2 bank texts we couldn't read" && item.destination == .unreadTexts)
    #expect(home.openNotification(.unreadTexts) == nil)
    #expect(app.router.tab == .review && app.router.review == [.unreadTexts])
  }

  @Test func addingAnUnreadTextByHandStartsAtItsTimeAndBank() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaTexts.state))
    let m = AddTransactionModel(app: app, resolving: "unread-text-dib")
    #expect(m.resolvedMail == "unread-text-dib" && m.accountID == "dib")
    #expect(AddTransactionDates.local(m.postedAt) == LocalDateTime(2026, 10, 10, 9, 58))
    let other = AddTransactionModel(app: app, resolving: "unread-text-other")
    #expect(other.accountID == AddTransactionModel(app: app).accountID)
  }

  @Test func theMockLedgerDismissesAndUndoesAnUnreadText() throws {
    let store = InMemoryLedger(state: Scenario.mayaTexts.state)
    let token = try #require(try store.apply(.archive("unread-text-dib", true)))
    #expect(token.title == "Dismissed" && store.state.unreadTexts.map(\.id) == ["unread-text-other"])
    store.undo(token)
    #expect(Set(store.state.unreadTexts.map(\.id)) == ["unread-text-dib", "unread-text-other"])
  }
}
