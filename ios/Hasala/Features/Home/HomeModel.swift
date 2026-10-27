import HasalaModels
import Observation

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// The bell (Paper "Home · Notifications" 11Y9-0): what needs a look, then what came before.
/// Its unread items are the bell's badge; the Review tab's badge counts only transactions to sort.
struct Bell: Equatable {
  /// Newest first: the ledger's items, then mail's ("Connect your email", "Sign in again").
  var needsALook: [NotificationItem]
  /// Notifications sent before. Only a Debug feed has any (plan B7.6, decision 12).
  var earlier: [NotificationItem]
  var unread: Int = 0

  var count: Int { needsALook.count }

  static func label(_ count: Int) -> String {
    switch count {
    case ...0: "Notifications"
    case 1: "Notifications, 1 needs a look"
    default: "Notifications, \(count) need a look"
    }
  }
}

/// Home · Default (spec 10 §2) and its bell (§4).
@MainActor
protocol HomeModel: AnyObject, Observable {
  var snapshot: HomeSnapshot { get }
  var canvas: [HomeCanvasItem] { get }
  var hidden: Bool { get }
  var bell: Bell { get }
  /// A widget tap; returns a screen to push, if any.
  func openWidget(_ id: String) -> HomeRoute?
  /// Whether tapping the widget leads anywhere in this build (`BuildSurface`): a Release
  /// build doesn't make a widget tappable when its detail screen isn't built yet.
  func widgetOpens(_ id: String) -> Bool
  func openNotCounted(_ line: SpendHero.NotCounted)
  /// A bell row (spec 10 §4.4, "Tapping an item opens its screen"): closes the sheet and opens
  /// the row's screen. What can open under a closing sheet opens now (a tab, a push, the next
  /// sheet); what needs the sheet gone first (the review cover) comes back to run once it is.
  func openNotification(_ destination: NotificationDestination) -> (@MainActor () -> Void)?
  func markAllRead()
}

@MainActor
@Observable
final class HomeViewModel: HomeModel {
  private let app: AppModel
  @ObservationIgnored private let feed: (any NotificationFeed)?

  init(app: AppModel) {
    self.app = app
    #if HASALA_MOCKS
      // The Debug "Earlier" list belongs to the Maya mock only: a Debug build signed in to a
      // real account shows what is real, and the Release surface shows no history.
      feed = BuildSurface.showsUnfinished && app.store is InMemoryLedger ? MockNotificationFeed() : nil
    #else
      feed = nil
    #endif
  }

  /// One engine pass per ledger change (`AppModel.snapshot` is memoised by revision).
  var snapshot: HomeSnapshot { app.snapshot }

  var canvas: [HomeCanvasItem] {
    let snapshot = app.snapshot
    guard snapshot.isThisMonth else {
      return snapshot.widgets.map { HomeCanvasItem(entry: HomeLayout.Entry($0.kind), widget: $0) }
    }
    return app.homeCanvas
  }

  var hidden: Bool { app.amountsHidden }

  var bell: Bell {
    let items = app.needsALook
    return Bell(
      needsALook: items, earlier: feed?.earlier(now: app.store.now) ?? [],
      unread: app.notificationReads.unread(items).count)
  }

  func markAllRead() {
    app.notificationReads.markAllRead(app.needsALook)
  }

  /// Mail's row (plan B4.3: the offer is the bell's mail row and the Profile card). It has no
  /// moment of its own, so it comes after the ledger's dated items. Both open Bank alerts,
  /// which offers the connect or the sign-in.
  static func mailItem(_ offer: MailOffer?, mailboxes: [MailboxSnapshot]) -> NotificationItem? {
    switch offer {
    case nil:
      return nil
    case .connect:
      return NotificationItem(
        id: "mail.connect", disc: .neutral(.envelope), title: "Connect your email",
        line: "Then Hasala can read your bank alerts.", when: nil, destination: .bankAlerts)
    case .signInAgain(let id, let provider):
      // Page 18 §14 "Mailbox needs sign-in": the title names the mailbox, never the account.
      let address = mailboxes.first { $0.id == id }?.address ?? provider.appName
      return NotificationItem(
        id: "mail.signIn.\(id)", disc: .neutral(.envelope), title: "Sign in again to \(address)",
        line: "Hasala can't read this mailbox right now.", when: nil, destination: .bankAlerts)
    }
  }

  func openNotification(_ destination: NotificationDestination) -> (@MainActor () -> Void)? {
    let router = app.router
    switch destination {
    case .bankAlerts:
      // A sheet never opens a second sheet: the bell's closes, then Profile comes up with Bank
      // alerts pushed inside it (`AppRouter.open` queues it).
      router.open(.profile, profile: [.bankAlerts])
      return nil
    case .review(let preset):
      close()
      if let preset { app.choose(preset) }
      router.tab = .review
      return { [app] in app.startReview() }
    case .unreadMail:
      close()
      router.tab = .review
      router.review = [.unreadMail]
      return nil
    case .unreadTexts:
      close()
      router.tab = .review
      router.review = [.unreadTexts]
      return nil
    case .bill(let id):
      close()
      router.tab = .home
      router.home = [.bill(id)]
      return nil
    case .bills:
      close()
      router.tab = .home
      router.home = [.bills]
      return nil
    case .category(let id):
      if BuildSurface.showsPlanTab {
        close()
        app.openPlan(category: id)
      } else {
        router.open(.profile, profile: [.plan, .category(id)])
      }
      return nil
    }
  }

  /// Closes the bell's sheet (and only it).
  private func close() {
    if app.router.sheet == .notifications { app.router.sheet = nil }
  }

  func openWidget(_ id: String) -> HomeRoute? {
    switch id {
    case "budgetPace":
      app.openPlan()
      return nil
    case "today":
      app.tab = .activity
      return nil
    case "nextBill", "comingUp":
      return .bills
    case "netWorth":
      return .accounts
    case "toReview":
      app.startReview()
      return nil
    case "spentSoFar":
      return nil
    default:
      if id.hasPrefix(Self.categoryPrefix) {
        app.openPlan(category: String(id.dropFirst(Self.categoryPrefix.count)))
        return nil
      }
      if id.hasPrefix(Self.projectPrefix) {
        app.openProjectsTab(String(id.dropFirst(Self.projectPrefix.count)))
        return nil
      }
      app.openPlan()
      return nil
    }
  }

  func openNotCounted(_ line: SpendHero.NotCounted) {
    app.openProjectsTab(line.projectID)
  }

  static let categoryPrefix = HomeWidgetKind.categoryWatch.rawValue + "."
  static let projectPrefix = HomeWidgetKind.project.rawValue + "."

  /// The widgets with a built destination: Plan, a category, a project, Activity, Bills and the review deck.
  static let widgetsWithDestinations: Set<String> = ["budgetPace", "today", "nextBill", "comingUp", "toReview"]

  func widgetOpens(_ id: String) -> Bool {
    if id == "spentSoFar" { return false }
    return BuildSurface.showsUnfinished || Self.widgetsWithDestinations.contains(id) || id.hasPrefix(Self.categoryPrefix)
      || id.hasPrefix(Self.projectPrefix)
  }
}

extension AppModel {
  var needsALook: [NotificationItem] {
    NotificationsEngine.snapshot(store.state, now: store.now).needsALook
      + [HomeViewModel.mailItem(mailOffer, mailboxes: mailbox?.mailboxes ?? [])].compactMap { $0 }
  }

  var bellCount: Int { notificationReads.unread(needsALook).count }
}

/// Notifications Hasala sent before (Paper "Earlier"). The app keeps no notification history
/// yet, so live has no feed; Debug's Maya mock has one (`MockNotificationFeed`).
@MainActor
protocol NotificationFeed {
  func earlier(now: LocalDateTime) -> [NotificationItem]
}
