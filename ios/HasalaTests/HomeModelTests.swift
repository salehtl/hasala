import Foundation
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
    #expect(home.bell.count == 3)
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    #expect(!home.bell.needsALook.contains { $0.id == "review" })
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
    #expect(app.tab == .projects)
    #expect(app.router.projects == [.project("japan")])
    app.tab = .home
    home.openNotCounted(SpendHero.NotCounted(amount: .aed(5_600_00), projects: 2, projectID: nil, line: ""))
    #expect(app.tab == .projects)
    #expect(app.router.projects.isEmpty)
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
    #expect(home.bell.count == 2)
  }

  @Test func markAllReadClearsTheBadgeUntilSomethingChanges() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(home.bell.unread == 3)
    #expect(app.bellCount == 3)
    home.markAllRead()
    #expect(home.bell.unread == 0)
    #expect(app.bellCount == 0)
    #expect(home.bell.count == 3)
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    #expect(home.bell.unread == 0)
    #expect(app.bellCount == 0)
  }

  @Test func aReadItemComesBackOnlyWhenItGrowsOrChanges() {
    func item(_ id: String, _ title: String, count: Int = 0) -> NotificationItem {
      NotificationItem(id: id, disc: .neutral(.flag), title: title, line: "", when: nil, destination: .review(.allTime),
                       count: count)
    }
    let reads = NotificationReads()
    reads.markAllRead([item("review", "1,284 transactions to sort", count: 1_284), item("bill.axa", "AXA Insurance may be late")])
    #expect(reads.isRead(item("review", "1,284 transactions to sort", count: 1_284)))
    #expect(reads.isRead(item("review", "999 transactions to sort", count: 999)))
    #expect(!reads.isRead(item("review", "1,285 transactions to sort", count: 1_285)))
    #expect(reads.isRead(item("bill.axa", "AXA Insurance may be late")))
    #expect(reads.isRead(item("bill.axa", "\u{2068}AXA Insurance\u{2069} may be late")))
    #expect(!reads.isRead(item("bill.axa", "AXA Insurance is late")))
    #expect(!reads.isRead(item("bill.du", "du may be late")))
  }

  @Test func aReadConnectRowStaysReadThroughAnOpenBeforeTheServerAnswers() throws {
    let suite = "test.bell.reads.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    func launch() -> (AppModel, CountingMailbox) {
      let mailbox = CountingMailbox(MockMailbox())
      return (AppModel(store: InMemoryLedger(), mailbox: mailbox, notificationReads: NotificationReads(defaults: defaults)), mailbox)
    }
    let (first, _) = launch()
    #expect(first.needsALook.contains { $0.id == "mail.connect" })
    HomeViewModel(app: first).markAllRead()
    #expect(first.bellCount == 0)

    let (offline, mailbox) = launch()
    mailbox.offerOverride = .some(nil)
    mailbox.offerSettled = false
    #expect(!offline.needsALook.contains { $0.id == "mail.connect" })
    HomeViewModel(app: offline).markAllRead()

    mailbox.offerOverride = nil
    mailbox.offerSettled = true
    #expect(offline.needsALook.contains { $0.id == "mail.connect" })
    #expect(offline.bellCount == 0)
    let (later, _) = launch()
    #expect(later.bellCount == 0)
  }

  @Test func aConnectRowThatTrulyLeftIsNewWhenItReturns() {
    let mailbox = CountingMailbox(MockMailbox())
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    home.markAllRead()
    #expect(app.bellCount == 0)
    mailbox.offerOverride = .some(nil)
    home.markAllRead()
    mailbox.offerOverride = nil
    #expect(app.bellCount == 1)
  }

  @Test func anOpenBeforeTheServerAnswersMarksNoConnectRowThatWasNeverRead() {
    let mailbox = CountingMailbox(MockMailbox())
    mailbox.offerOverride = .some(nil)
    mailbox.offerSettled = false
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    HomeViewModel(app: app).markAllRead()
    #expect(app.bellCount == 0)
    mailbox.offerOverride = nil
    mailbox.offerSettled = true
    #expect(app.bellCount == 1)
  }

  @Test func readsPersistAsDigestsAndAreForgotten() throws {
    let suite = "test.bell.reads.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = AppModel(store: InMemoryLedger(), notificationReads: NotificationReads(defaults: defaults))
    HomeViewModel(app: first).markAllRead()
    let stored = defaults.stringArray(forKey: NotificationReads.key) ?? []
    #expect(stored.count == 3)
    #expect(!stored.contains { $0.contains("review") || $0.contains("AXA") })
    let again = AppModel(store: InMemoryLedger(), notificationReads: NotificationReads(defaults: defaults))
    #expect(again.bellCount == 0)
    NotificationReads.forget(defaults)
    let after = AppModel(store: InMemoryLedger(), notificationReads: NotificationReads(defaults: defaults))
    #expect(after.bellCount == 3)
  }

  /// Mail's offer is the bell's last row (plan B4.3); Home's board stays Maya's.
  @Test func mailNeedsAreTheBellsLastRow() {
    let mailbox = MockMailbox()
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    #expect(app.mailOffer == .connect)
    #expect(home.snapshot == Maya.home)
    #expect(home.bell.count == 4)
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
    let after = home.openNotification(.review(.allTime))
    #expect(router.sheet == nil)
    #expect(router.tab == .review)
    #expect(app.cover == nil)
    #expect(app.period.isAllTime && app.period.title == "All time")
    after?()
    #expect(app.cover == .review)
    app.cover = nil
    app.period = .month(YearMonth(2026, 9))
    router.open(.notifications)
    home.openNotification(.review(nil))?()
    #expect(app.cover == .review && app.period == .month(YearMonth(2026, 9)))
    app.cover = nil
    app.period = .month(MayaLedger.october)

    // A late bill: Home, pushed to the bill.
    router.tab = .plan
    router.open(.notifications)
    #expect(home.openNotification(.bill("axa")) == nil)
    #expect(router.sheet == nil && router.tab == .home && router.home == [.bill("axa")])

    // A found bill: Bills.
    router.open(.notifications)
    #expect(home.openNotification(.bills) == nil)
    #expect(router.home == [.bills])

    router.open(.notifications)
    #expect(home.openNotification(.category("groceries")) == nil)
    #expect(router.sheet == nil)
    #expect(router.nextSheet?.0 == .profile && router.nextSheet?.profilePath == [.plan, .category("groceries")])
    router.sheetDismissed()
    #expect(router.sheet == .profile && router.profile == [.plan, .category("groceries")])
    router.sheet = nil
    router.sheetDismissed()

    // Mail: the bell's sheet closes, then Profile opens with Bank alerts pushed inside it.
    router.open(.notifications)
    #expect(home.openNotification(.bankAlerts) == nil)
    #expect(router.sheet == nil)
    #expect(router.nextSheet?.0 == .profile && router.nextSheet?.profilePath == [.bankAlerts])
    router.sheetDismissed()
    #expect(router.sheet == .profile && router.profile == [.bankAlerts])
  }

  @Test func everyBellRowLandsOnAScreenThatShowsIt() throws {
    var state = MayaHistory.state
    state.txns.append(Txn(id: "jun-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 6, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state), mailbox: MockMailbox())
    app.period = .month(YearMonth(2026, 9))
    let home = HomeViewModel(app: app)
    let router = app.router
    let items = home.bell.needsALook
    #expect(items.map(\.id) == ["bill.axa", "found.apple-bill", "price.du", "mail.connect"])
    #expect(Bell.label(home.bell.count) == "Notifications, 4 need a look")
    #expect(Bell.label(1) == "Notifications, 1 needs a look")
    #expect(Bell.label(0) == "Notifications")
    for item in items {
      router.clearPresentation()
      router.tab = .activity
      router.home = []
      router.open(.notifications)
      let after = home.openNotification(item.destination)
      #expect(router.sheet == nil, "\(item.id)")
      switch item.destination {
      case .review:
        #expect(router.tab == .review)
        after?()
        #expect(app.cover == .review)
        let deck = ReviewViewModel(app: app)
        #expect(item.title == "\(deck.total) transactions to sort")
        #expect(deck.cards.contains { $0.id == "jun-shop" })
        #expect(ReviewTabView.countLine(deck.total).hasPrefix("\(app.reviewCount) to sort"))
      case .bill(let id):
        #expect(router.tab == .home && router.home == [.bill(id)])
        let detail = try #require(BillsViewModel(app: app).detail(id))
        #expect(item.id.hasPrefix("price.") ? detail.isPriceChange : detail.isLate, "\(item.id)")
      case .bills:
        #expect(router.tab == .home && router.home == [.bills])
        let found = BillsViewModel(app: app).snapshot.found.map { "found.\($0.id)" }
        #expect(found.contains(item.id))
      case .category(let id):
        #expect(router.nextSheet?.0 == .profile && router.nextSheet?.profilePath == [.plan, .category(id)])
      case .unreadMail:
        #expect(router.tab == .review && router.review == [.unreadMail])
        #expect(!app.store.state.unreadMail.isEmpty)
      case .unreadTexts:
        #expect(router.tab == .review && router.review == [.unreadTexts])
        #expect(!app.store.state.unreadTexts.isEmpty)
      case .bankAlerts:
        router.sheetDismissed()
        #expect(router.sheet == .profile && router.profile == [.bankAlerts])
        #expect(app.mailOffer == .connect)
      }
    }
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
    #expect(home.bell.needsALook.allSatisfy { !$0.line.rendered(hidden: home.hidden).contains("AED 1") })
    #expect(home.bell.needsALook.contains { $0.line.rendered(hidden: home.hidden).contains("•••") })
  }

  @Test func theBellLeavesSortingToTheReviewTab() {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.reviewCount > 0)
    #expect(!HomeViewModel(app: app).bell.needsALook.contains { $0.id == "review" })
    #expect(!app.needsALook.contains { $0.id == "review" })
  }

  @Test func openingTheBellKeepsASignInRowUnread() {
    let reads = NotificationReads()
    let app = AppModel(store: InMemoryLedger(), notificationReads: reads)
    let home = HomeViewModel(app: app)
    let signIn = NotificationItem(id: "mail.signIn.gmail", disc: .neutral(.envelope), title: "Sign in again to Gmail",
                                  line: "", when: nil, destination: .bankAlerts)
    home.markAllRead()
    #expect(home.bell.unread == 0)
    #expect(HomeViewModel.staysUnread(signIn))
    #expect(!HomeViewModel.staysUnread(NotificationItem(id: "mail.connect", disc: .neutral(.envelope),
                                                        title: "Connect your email", line: "", when: nil,
                                                        destination: .bankAlerts)))
    reads.markAllRead([signIn].filter { !HomeViewModel.staysUnread($0) })
    #expect(!reads.isRead(signIn))
  }

  @Test func everyWidgetHasATapResult() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(!app.store.state.accounts.isEmpty)
    #expect(home.widgetOpens("netWorth") && home.openWidget("netWorth") == .accounts)
    #expect(home.widgetOpens("spentSoFar"))
    #expect(home.openWidget("spentSoFar") == nil && app.tab == .activity)
    let goal = HomeWidgetKind.goal.rawValue + ".emergency"
    #expect(home.widgetOpens(goal))
    var state = MayaLedger.state
    state.accounts = []
    let none = HomeViewModel(app: AppModel(store: InMemoryLedger(state: state)))
    #expect(none.widgetOpens("netWorth") == BuildSurface.showsUnfinished)
  }

  @Test func anEmptyBudgetPaceOpensTheMonthlyPlan() {
    var state = MayaLedger.state
    state.plan.budgets = [:]
    let app = AppModel(store: InMemoryLedger(state: state))
    let home = HomeViewModel(app: app)
    #expect(home.snapshot.hero.state == .noPlan)
    var asked = 0
    #expect(home.openWidget("budgetPace", setPlan: { asked += 1 }) == nil)
    #expect(asked == 1)
    let planned = HomeViewModel(app: AppModel(store: InMemoryLedger()))
    _ = planned.openWidget("budgetPace", setPlan: { asked += 1 })
    #expect(asked == 1)
  }

  @Test func eachMonthBarSaysItsPlanInWords() {
    let over = HeroMonthBar(month: YearMonth(2026, 8), spent: .aed(19_283_10), plan: .aed(19_000_00), verdict: .overBudget)
    let under = HeroMonthBar(month: YearMonth(2026, 9), spent: .aed(18_000_00), plan: .aed(19_000_00), verdict: .onTrack)
    let unplanned = HeroMonthBar(month: YearMonth(2026, 10), spent: .aed(500_00), plan: .aed(0), verdict: .onTrack)
    #expect(over.spoken(hidden: false) == "August 2026, AED 19,283.10, AED 283.10 over the plan of AED 19,000.00")
    #expect(under.spoken(hidden: false) == "September 2026, AED 18,000.00, AED 1,000.00 under the plan of AED 19,000.00")
    #expect(unplanned.spoken(hidden: false) == "October 2026, AED 500.00")
    #expect(over.spoken(hidden: true) == "August 2026, Amount hidden")
    #expect(HeroMonthBar.overLine([over, under, unplanned], hidden: false) == "Aug 283 over plan")
    #expect(HeroMonthBar.overLine([over], hidden: true) == "Aug ••• over plan")
    #expect(HeroMonthBar.overLine([under, unplanned], hidden: false) == nil)
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
