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

  /// Mail's offer is no longer a Needs-you card (plan B4.3): Home stays Maya's board, and
  /// the offer is `AppModel.mailOffer` for the bell and the Profile card.
  @Test func mailNeedsAreNotANeedsYouCard() {
    let mailbox = MockMailbox()
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    #expect(app.mailOffer == .connect)
    #expect(home.snapshot == Maya.home)
    #expect(!home.snapshot.needsYou.cards.contains { $0.id.hasPrefix("gmail.") })
  }

  @Test func startOpensTheReviewCover() {
    let app = AppModel(store: InMemoryLedger())
    _ = HomeViewModel(app: app).needsYou("review", primary: true)
    #expect(app.cover == .review)
  }
}
