import HasalaMocks
import HasalaModels
import Testing

@Suite("Unread bank emails")
struct UnreadMailTests {
  let now = MayaLedger.now

  @Test func theMayaLedgerHasNone() {
    let s = MayaLedger.state
    #expect(s.unreadMail.isEmpty)
    #expect(ReviewEngine.unreadCount(s) == 0)
    #expect(NotificationsEngine.snapshot(s, now: now).needsALook.first { $0.id == "unread" } == nil)
  }

  @Test func theLineCountsRowsAndDownloadFailuresTogether() {
    let s = Scenario.mayaUnreadMail.state
    #expect(s.unreadMail.count == 2)
    #expect(ReviewEngine.notDownloaded(s) == 1)
    #expect(ReviewEngine.unreadCount(s) == 3)
    #expect(ReviewEngine.unreadLine(1) == "1 bank email we couldn't read")
    #expect(ReviewEngine.unreadLine(3) == "3 bank emails we couldn't read")
    #expect(ReviewEngine.notDownloadedLine(1) == "1 more email couldn't be downloaded.")
    #expect(ReviewEngine.notDownloadedLine(2) == "2 more emails couldn't be downloaded.")
  }

  @Test func downloadFailuresAloneStillCount() {
    var s = MayaLedger.state
    s.mailbox.unreadable = 2
    #expect(ReviewEngine.unreadCount(s) == 2)
    #expect(ReviewEngine.unreadMail(s).isEmpty)
  }

  @Test func theListRunsNewestFirst() {
    var s = MayaLedger.state
    s.unreadMail = [
      UnreadMail(id: "a", provider: .outlook, receivedOn: LocalDate(2026, 10, 3)),
      UnreadMail(id: "b", provider: .gmail, receivedOn: LocalDate(2026, 10, 9)),
      UnreadMail(id: "c", provider: nil, receivedOn: LocalDate(2026, 10, 9)),
    ]
    #expect(ReviewEngine.unreadMail(s).map(\.id) == ["c", "b", "a"])
  }

  @Test func eachRowNamesItsDayAndItsMailbox() {
    let today = LocalDate(2026, 10, 10)
    #expect(ReviewEngine.unreadDetail(UnreadMail(id: "a", provider: .gmail, receivedOn: LocalDate(2026, 10, 8)), today: today)
      == "Received Thu 8 Oct · in Gmail")
    #expect(ReviewEngine.unreadDetail(UnreadMail(id: "a", provider: .outlook, receivedOn: today), today: today)
      == "Received today · in Outlook")
    #expect(ReviewEngine.unreadDetail(UnreadMail(id: "a", provider: nil, receivedOn: LocalDate(2026, 10, 8)), today: today)
      == "Received Thu 8 Oct")
  }

  @Test func aRowNamesItsBankWhenThisIPhoneKnowsTheSender() {
    #expect(ReviewEngine.unreadTitle(UnreadMail(id: "a", provider: .gmail, receivedOn: now.date, bank: "DIB")) == "DIB email")
    #expect(ReviewEngine.unreadTitle(UnreadMail(id: "a", provider: .gmail, receivedOn: now.date)) == "Bank email")
    let s = Scenario.mayaUnreadMail.state
    #expect(s.unreadMail.map(ReviewEngine.unreadTitle) == ["DIB email", "Bank email"])
    #expect(s.unreadMail.first?.accountID.flatMap { id in s.accounts.first { $0.id == id } }?.shortName == "DIB card")
  }

  @Test func theBellGetsOneItemAndTheToSortItemDoesNotCountThem() {
    var s = Scenario.mayaUnreadMail.state
    let bell = NotificationsEngine.snapshot(s, now: now)
    let unread = bell.needsALook.first { $0.id == "unread" }
    #expect(unread?.title == "2 bank emails we couldn't read")
    #expect(unread?.destination == .unreadMail)
    #expect(unread?.when == "Yesterday")
    #expect(bell.count == NotificationsEngine.snapshot(MayaLedger.state, now: now).count + 1)
    #expect(bell.needsALook.first { $0.id == "review" }?.title == "6 transactions to sort")
    #expect(ReviewEngine.queue(s).count == 6)
    s.unreadMail = []
    #expect(NotificationsEngine.snapshot(s, now: now).needsALook.first { $0.id == "unread" } == nil)
  }

  @Test func unreadRowsAreNotInTheDeckTheTabsBadgeOrTheMoney() {
    let s = Scenario.mayaUnreadMail.state
    let base = MayaLedger.state
    #expect(ReviewEngine.cards(s).map(\.id) == ReviewEngine.cards(base).map(\.id))
    #expect(ActivityEngine.reviewSummary(s, now: now).count == ActivityEngine.reviewSummary(base, now: now).count)
    #expect(Spending.total(s, in: MayaLedger.october) == Spending.total(base, in: MayaLedger.october))
  }

  @Test @MainActor func dismissingARowRemovesItAndUndoBringsItBack() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaUnreadMail.state)
    let token = try #require(try ledger.apply(.archive("unread-gmail", true)))
    #expect(token.title == "Dismissed")
    #expect(ledger.state.unreadMail.map(\.id) == ["unread-outlook"])
    #expect(ReviewEngine.unreadCount(ledger.state) == 2)
    ledger.undo(token)
    #expect(Set(ledger.state.unreadMail.map(\.id)) == ["unread-gmail", "unread-outlook"])
  }

  @Test @MainActor func aMissingRowIsRefused() {
    let ledger = InMemoryLedger(state: Scenario.mayaUnreadMail.state)
    #expect(throws: ActionError.notFound) { try ledger.apply(.archive("nope", true)) }
  }
}
