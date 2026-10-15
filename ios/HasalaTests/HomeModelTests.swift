import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Home's view model over the Maya ledger.
@MainActor
@Suite("Home model")
struct HomeModelTests {
  @Test func homeFollowsTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(home.snapshot == Maya.home)
    // Sorting a card updates the Needs-you poster.
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    guard case .count(let n, _) = home.snapshot.needsYou.cards[0].figure else {
      Issue.record("first card is not the review poster")
      return
    }
    #expect(n == 5)
    // "Later" puts the review card off; "Details" on a late bill opens Bills.
    #expect(home.needsYou("review", primary: false) == nil)
    #expect(!home.snapshot.needsYou.cards.contains { $0.id == "review" })
    #expect(home.needsYou("bill.axa", primary: false) == .bills)
    #expect(home.openWidget("nextBill") == .bills)
    #expect(home.openWidget("today") == nil)
    #expect(app.tab == .activity)
  }

  /// Gmail skipped at setup: Home's Needs you leads with "Connect Gmail" (spec 04 §6.6 row 4);
  /// "Connect" opens the connect sheet and "Later" puts it off.
  @Test func homeOffersConnectGmailWhenTheLaneSaysSo() throws {
    let mailbox = MockMailbox()
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    #expect(home.snapshot == Maya.home)
    mailbox.gmailOffer = .connect
    let rail = home.snapshot.needsYou
    let card = try #require(rail.cards.first)
    #expect(card.id == "gmail.connect" && card.title == "Connect Gmail" && card.primaryAction == "Connect")
    #expect(rail.count == Maya.home.needsYou.count + 1)
    #expect(rail.subtitle == Maya.home.needsYou.subtitle)
    #expect(home.needsYou(card.id, primary: true) == nil)
    #expect(app.sheet == .connectGmail(.connect))
    app.sheet = nil
    #expect(home.needsYou(card.id, primary: false) == nil)
    #expect(app.sheet == nil)
    #expect(!home.snapshot.needsYou.cards.contains { $0.id == "gmail.connect" })
    #expect(home.snapshot == Maya.home)  // the count and subtitle too

    mailbox.gmailOffer = .reconnect
    #expect(home.snapshot.needsYou.cards.first?.title == "Reconnect Gmail")
    mailbox.gmailOffer = nil
    #expect(home.snapshot == Maya.home)
  }

  @Test func theGmailCardSaysWhatNeedsDoingWhenItIsAlone() {
    let rail = GmailOffer.reconnect.adding(to: NeedsYouRail(count: 0, subtitle: "All caught up", cards: []))
    #expect(rail.count == 1 && rail.cards.map(\.id) == ["gmail.reconnect"])
    #expect(rail.subtitle == "Gmail needs reconnecting")
    #expect(GmailOffer(cardID: "gmail.connect") == .connect)
    #expect(GmailOffer(cardID: "review") == nil && GmailOffer(cardID: "gmail.other") == nil)
  }

  @Test func startOpensTheReviewCover() {
    let app = AppModel(store: InMemoryLedger())
    _ = HomeViewModel(app: app).needsYou("review", primary: true)
    #expect(app.cover == .review)
  }
}
