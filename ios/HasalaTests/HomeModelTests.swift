import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Home's view model over the Maya ledger: the board, the bell and where each row goes.
@MainActor
@Suite("Home model")
struct HomeModelTests {
  @Test func homeFollowsTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(home.snapshot == Maya.home)
    #expect(home.bell.count == 4)
    // Sorting a transaction updates the bell's first row; the hero already counted it.
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    #expect(home.bell.needsALook[0].title == "5 transactions to sort")
    #expect(home.snapshot.hero.spent == .aed(11_115_62))
    #expect(home.snapshot.hero.tiles[0].value == .aed(9_255_10))
    #expect(home.openWidget("nextBill") == .bills)
    #expect(home.openWidget("today") == nil)
    #expect(app.tab == .activity)
  }

  @Test func notCountedOpensTheProjectOrTheProjects() throws {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    app.period = .month(YearMonth(2026, 9))
    let line = try #require(home.snapshot.hero.notCounted)
    home.openNotCounted(line)
    #expect(app.tab == .plan)
    #expect(app.router.plan == [.project("japan")])
    app.tab = .home
    app.router.plan = []
    home.openNotCounted(SpendHero.NotCounted(amount: .aed(5_600_00), projects: 2, projectID: nil, line: ""))
    #expect(app.tab == .plan)
    #expect(app.router.plan == [.projects])
  }

  /// The snapshot is computed once per ledger change (`AppModel`'s memo): reading it again
  /// returns the same value without a new engine pass, and a change gives a new one.
  @Test func theSnapshotIsMemoisedByRevision() {
    let store = InMemoryLedger()
    let app = AppModel(store: store)
    let home = HomeViewModel(app: app)
    let first = home.snapshot
    let revision = store.revision
    #expect(home.snapshot == first)
    #expect(store.revision == revision)
    app.perform(.markBillPaid("axa"))
    #expect(home.snapshot != first)
    #expect(home.bell.count == 3)
  }

  /// Mail's offer is the bell's last row (plan B4.3); Home's board stays Maya's.
  @Test func mailNeedsAreTheBellsLastRow() {
    let mailbox = MockMailbox()
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    #expect(app.mailOffer == .connect)
    #expect(home.snapshot == Maya.home)
    #expect(home.bell.count == 5)
    let row = home.bell.needsALook.last
    #expect(row?.id == "mail.connect")
    #expect(row?.title == "Connect your email")
    #expect(row?.destination == .bankAlerts)
    // Main's `homeOffersConnectMailboxWhenTheLaneSaysSo`: Outlook's sign-in again is the
    // Outlook row; a working Outlook mailbox needs no row (v2 has no `.change` to offer).
    let outlook = MockMailbox.needingSignIn(MockMailbox.outlook)
    #expect(HomeViewModel.mailItem(.signInAgain(mailboxID: "outlook-1", provider: .outlook), mailboxes: [outlook])?.title
      == "Sign in again to maya.k@example.com")
    #expect(HomeViewModel.mailItem(nil, mailboxes: [MockMailbox.outlook]) == nil)
  }

  @Test func signInAgainNamesTheMailbox() {
    let mailboxes = [
      MailboxSnapshot(id: "outlook-1", provider: .outlook, address: "maya.k@example.com", state: .needsSignIn,
                      meta: "Checked Wed"),
    ]
    let row = HomeViewModel.mailItem(.signInAgain(mailboxID: "outlook-1", provider: .outlook), mailboxes: mailboxes)
    #expect(row?.id == "mail.signIn.outlook-1")
    #expect(row?.title == "Sign in again to maya.k@example.com")
    #expect(row?.line.rendered(hidden: false) == "Hasala can't read this mailbox right now.")
    #expect(HomeViewModel.mailItem(nil, mailboxes: mailboxes) == nil)
    // Without the row (a mailbox the lane no longer lists), the provider's name stands in.
    #expect(HomeViewModel.mailItem(.signInAgain(mailboxID: "gmail", provider: .gmail), mailboxes: [])?.title
      == "Sign in again to Gmail")
  }

  /// Each row closes the bell's sheet and opens its screen (spec 10 §4.4, plan P5 work 4).
  @Test func eachRowOpensItsScreen() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    let router = app.router

    // To sort: the Review tab, and the deck once the sheet has gone.
    router.open(.notifications)
    let after = home.openNotification(.review)
    #expect(router.sheet == nil)
    #expect(router.tab == .review)
    #expect(app.cover == nil)
    after?()
    #expect(app.cover == .review)
    app.cover = nil

    // A late bill: Home, pushed to the bill.
    router.tab = .plan
    router.open(.notifications)
    #expect(home.openNotification(.bill("axa")) == nil)
    #expect(router.sheet == nil && router.tab == .home && router.home == [.bill("axa")])

    // A found bill or a new price: Bills.
    router.open(.notifications)
    #expect(home.openNotification(.bills) == nil)
    #expect(router.home == [.bills])

    // A category running fast (Debug "Earlier"): Plan's category.
    router.open(.notifications)
    #expect(home.openNotification(.category("groceries")) == nil)
    #expect(router.tab == .plan && router.plan == [.category("groceries")])

    // Mail: the bell's sheet closes, then Profile opens with Bank alerts pushed inside it.
    router.open(.notifications)
    #expect(home.openNotification(.bankAlerts) == nil)
    #expect(router.sheet == nil)
    #expect(router.nextSheet?.0 == .profile && router.nextSheet?.profilePath == [.bankAlerts])
    router.sheetDismissed()
    #expect(router.sheet == .profile && router.profile == [.bankAlerts])
  }

  /// "Earlier" is the Debug Maya mock's (plan B7.6 decision 12): three rows read and done.
  @Test func earlierComesFromTheDebugFeed() {
    let home = HomeViewModel(app: AppModel(store: InMemoryLedger()))
    #expect(home.bell.earlier.map(\.title) == [
      "Groceries is running fast", "No alerts from DIB for 3 days", "Rent is due Thu",
    ])
    #expect(home.bell.earlier[0].line.rendered(hidden: false)
      == "812.40 of 2,200 so far. At this pace October ends near 2,518.")
    #expect(home.bell.earlier[1].status == .success)
  }

  /// Hiding amounts reaches the bell's rows (three dots, page 06 §6.3).
  @Test func hiddenAmountsReachTheBell() {
    let app = AppModel(store: InMemoryLedger(), amountsHidden: true)
    let home = HomeViewModel(app: app)
    #expect(home.hidden)
    #expect(home.bell.needsALook[0].line.rendered(hidden: home.hidden) == "AED ••• still to check")
  }

  /// The hero's first reveal keeps the owner's sequence (motion policy): the tick starts as
  /// the 300 ms fill lands, the verdict as the 120 ms tick lands, and the 150 ms verdict is in
  /// by 570 ms. The steps start together on these delays, never from completion handlers.
  @Test func theRevealKeepsTheOwnersSequence() {
    let ms = { (s: Double) in Int((s * 1000).rounded()) }
    #expect(ms(HeroReveal.schedule.tick) == 300)
    #expect(ms(HeroReveal.schedule.verdict) == 420)
    #expect(ms(HeroReveal.schedule.end) == 570)
  }
}
