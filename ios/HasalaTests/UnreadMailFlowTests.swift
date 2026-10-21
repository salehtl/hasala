import CoreDomain
import CoreJSON
import CoreMailbox
import CoreOutbox
import CoreReplay
import CoreWire
import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Unread bank emails in the app")
struct UnreadMailFlowTests {
  static let received: Int64 = 1_791_450_000_000

  static func unparsedPayload(provider: MailProviderID = .gmail, messageID: String = "m-unread-1") -> (JSONObject, String) {
    let mail = MessageDisposer.unparsed(raw: Array(messageID.utf8), messageID: messageID, internalDateMs: received, spam: false)
    let draft = MessageDisposer.finalize(
      mail, provider: provider, grantID: "u/mbx-a", cards: [:], categorizer: NoCategorizer())
    return (draft.payload, draft.ingestID)
  }

  static func addUnparsed(_ o: inout OpAuthor, provider: MailProviderID = .gmail, messageID: String = "m-unread-1") throws(AuthorError) {
    let (payload, ingest) = unparsedPayload(provider: provider, messageID: messageID)
    try o.ingest(payload: payload, ingestID: ingest)
  }

  @Test func anEmptyReviewRowIsAnUnreadEmailNotATransaction() async throws {
    let base = try await LiveLedgerMapperTests.foldedState()
    let state = try await LiveLedgerMapperTests.foldedState { o throws(AuthorError) in try Self.addUnparsed(&o) }
    #expect(base.unreadMail.isEmpty)
    let mail = try #require(state.unreadMail.first)
    #expect(state.unreadMail.count == 1)
    #expect(mail.provider == .gmail)
    #expect(mail.receivedOn == LocalDate(2026, 10, 8))
    #expect(state.txns.count == base.txns.count)
    #expect(ReviewEngine.queue(state).count == ReviewEngine.queue(base).count)
    #expect(AppModel(store: InMemoryLedger(state: state)).reviewCount == AppModel(store: InMemoryLedger(state: base)).reviewCount)
    #expect(ReviewEngine.unreadCount(state) == 1)
  }

  @Test func eachMailboxKeepsItsOwnProvider() async throws {
    let state = try await LiveLedgerMapperTests.foldedState { o throws(AuthorError) in
      try Self.addUnparsed(&o, provider: .gmail, messageID: "m-g")
      try Self.addUnparsed(&o, provider: .outlook, messageID: "m-o")
    }
    #expect(Set(state.unreadMail.compactMap(\.provider)) == [.gmail, .outlook])
    #expect(ReviewEngine.unreadLine(state.unreadMail.count) == "2 bank emails we couldn't read")
  }

  @Test func theSenderKeptOnThisIPhoneNamesTheBankAndItsAccount() async throws {
    var c = LiveLedgerMapperTests.context()
    c.unreadSenders = ["m-dib": "alerts.dib.ae", "m-other": "example.com"]
    let state = try await LiveLedgerMapperTests.foldedState(context: c) { o throws(AuthorError) in
      try Self.addUnparsed(&o, messageID: "m-dib")
      try Self.addUnparsed(&o, messageID: "m-other")
      try Self.addUnparsed(&o, messageID: "m-before")
    }
    let named = state.unreadMail.filter { $0.bank != nil }
    #expect(named.map(\.bank) == ["DIB"])
    #expect(state.unreadMail.count == 3)
    #expect(state.unreadMail.map(ReviewEngine.unreadTitle).sorted() == ["Bank email", "Bank email", "DIB email"])
    let dibAccounts = state.accounts.filter { $0.shortName.hasPrefix("DIB") }
    #expect(named.first?.accountID == (dibAccounts.first(where: \.inPlan) ?? dibAccounts.first)?.id)
    #expect(state.unreadMail.filter { $0.bank == nil }.allSatisfy { $0.accountID == nil })
  }

  @Test func addingByHandFromANamedEmailPicksThatBanksAccount() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaUnreadMail.state))
    #expect(AddTransactionModel(app: app, resolving: "unread-gmail").accountID == "dib")
    #expect(AddTransactionModel(app: app, resolving: "unread-outlook").accountID == AddTransactionModel(app: app).accountID)
    var s = Scenario.mayaUnreadMail.state
    s.unreadMail[0].accountID = "gone"
    #expect(AddTransactionModel(app: AppModel(store: InMemoryLedger(state: s)), resolving: "unread-gmail").accountID == AddTransactionModel(app: app).accountID)
  }

  @Test func dismissingARowIsAnArchiveThatTheProjectionKeeps() async throws {
    let a = try LiveLedgerMapperTests.account()
    for b in try await LiveLedgerMapperTests.seed(a) { try await a.outbox.enqueue(b.ops) }
    if let blob = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      try Self.addUnparsed(&o)
    }) {
      try await a.outbox.enqueue(blob.ops)
    }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: LiveLedgerMapperTests.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "unread.mail.tests")!), clock: { MayaLedger.now })
    await store.reload()
    let mail = try #require(store.state.unreadMail.first)
    #expect(try a.projection.reader.txn(mail.id)?.reviewLane == "unreadable")
    let token = try #require(try store.apply(.archive(mail.id, true)))
    #expect(token.title == "Dismissed")
    #expect(store.state.unreadMail.isEmpty)
    try await LiveLedgerMapperTests.eventually { try a.projection.reader.txn(mail.id)?.archived != nil }
    #expect(try a.projection.reader.txn(mail.id)?.reviewLane == nil)
    await store.reload()
    #expect(store.state.unreadMail.isEmpty)
    store.undo(token)
    try await LiveLedgerMapperTests.eventually { try a.projection.reader.txn(mail.id)?.archived == nil }
    await store.reload()
    #expect(store.state.unreadMail.map(\.id) == [mail.id])
  }

  @Test func theOptimisticPatchDismissesOnlyAnUnreadRow() throws {
    var s = Scenario.mayaUnreadMail.state
    let (title, inverses) = try LiveLedgerStore.patch(.archive("unread-gmail", true), &s, now: MayaLedger.now)
    #expect(title == "Dismissed")
    #expect(inverses == [.archived(txn: "unread-gmail", archived: false)])
    #expect(s.unreadMail.map(\.id) == ["unread-outlook"])
    var other = Scenario.mayaUnreadMail.state
    #expect(throws: ActionError.notFound) { try LiveLedgerStore.patch(.archive("nope", true), &other, now: MayaLedger.now) }
  }

  @Test func addingByHandOpensOnTheDayTheEmailCameAndResolvesTheRow() throws {
    let store = InMemoryLedger(state: Scenario.mayaUnreadMail.state)
    let app = AppModel(store: store)
    let model = AddTransactionModel(app: app, resolving: "unread-outlook")
    #expect(AddTransactionDates.local(model.postedAt) == LocalDateTime(2026, 10, 7, 0, 0))
    #expect(model.resolvedMail == "unread-outlook")
    let before = store.state.txns.count
    model.entry = AmountEntry(typing: "250")
    model.merchant = "Transfer to a friend"
    model.categoryID = "transfer"
    #expect(model.save())
    #expect(store.state.txns.count == before + 1)
    #expect(store.state.unreadMail.map(\.id) == ["unread-gmail"])
    #expect(app.toast?.title == "Added Transfer to a friend")
    #expect(store.state.txns.last?.amount == .aed(250_00))
  }

  @Test func anUnknownEmailLeavesTheAddSheetAsItWas() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaUnreadMail.state))
    let model = AddTransactionModel(app: app, resolving: "nope")
    #expect(model.resolvedMail == nil)
    #expect(model.postedAt == AddTransactionDates.date(app.store.now))
  }

  @Test func theBellOpensTheListInsideTheReviewTab() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaUnreadMail.state))
    let home = HomeViewModel(app: app)
    #expect(home.bell.needsALook.contains { $0.id == "unread" })
    #expect(home.openNotification(.unreadMail) == nil)
    #expect(app.router.tab == .review)
    #expect(app.router.review == [.unreadMail])
    app.router.popToRoot(.review)
    #expect(app.router.review.isEmpty)
  }

  @Test func theSheetForAnEmailHasItsOwnId() {
    #expect(SheetRoute.addFromEmail("a").id == "addFromEmail.a")
    #expect(SheetRoute.addFromEmail("a") != SheetRoute.addTransaction)
  }
}
