import HasalaModels

// Every place a screen can be pushed or presented (Paper "13 · Navigation · Patterns and
// app map"): one stack per tab, the sheets over the tabs and the one full-screen cover.
// `AppRouter` holds them all, so a launch argument, a notification row or a test can open
// any screen with a real back stack behind it. A package that needs a case that isn't here
// asks for it (plan 0.1 rule 15); the cases are shared by every package.

/// The tabs, in the bar's order: Home, Plan, Review and Activity, and the add button beside
/// them, which opens Add a transaction and is never the selected tab.
enum AppTab: Hashable {
  case home, plan, projects, review, activity, add
}

/// Pushed inside the Home tab.
enum HomeRoute: Hashable {
  /// Bills · Coming up and found.
  case bills
  /// One bill (Bills · AXA Insurance).
  case bill(BillID)
  /// Accounts · Net worth.
  case accounts
  /// Insights, from the hero's "Insights" link, for Home's period.
  case insights
}

/// Pushed inside the Plan tab.
enum PlanRoute: Hashable {
  /// Plan · Dining (category detail).
  case category(CategoryID)
  /// Plan · Japan trip (project detail).
  case project(ProjectID)
  case projects
  case addToProject(ProjectID)
}

/// Pushed inside the Activity tab.
enum ActivityRoute: Hashable {
  /// A "Coming up" bill.
  case bill(BillID)
}

/// Pushed inside the Review tab.
enum ReviewRoute: Hashable {
  case unreadMail
}

/// Pushed inside the transaction sheet (one sheet at a time: its editors push, never stack).
enum TransactionRoute: Hashable {
  case category, note, rename, split, project
  case reviewReason(TxnReviewReason)
}

/// Pages pushed inside the profile sheet (Paper "Profile · Your profile (sheet)": its rows
/// push inside the sheet, never a sheet over it).
enum ProfileRoute: Hashable {
  /// Profile › Bank alerts: the mailboxes, the banks, what couldn't be read.
  case bankAlerts
  /// One mailbox (`MailboxSnapshot.id`).
  case mailbox(String)
  /// Add a mailbox: the providers this build can connect.
  case addMailbox
  /// The read-only connect screen for one provider, in the profile's context.
  case connectMail(MailProviderKind)
  case accounts
  case bills
  case bill(BillID)
  /// Categories and rules.
  case rules
  case project(ProjectID)
  case projects
  case addToProject(ProjectID)
  case editProject(ProjectID?)
  case newProject(ProjectStarter)
  case plan
  case category(CategoryID)
  /// Sign-in & security.
  case security
  case editName
  case notifications
  case exchangeRates
  case editRate(String?)
  case privacy
  case help
  case deleteAccount
}

/// Sheets over the tabs. Never two at once: `AppRouter.open` queues the next one.
enum SheetRoute: Hashable, Identifiable {
  case transaction(TxnID)
  case budget(CategoryID)
  case moveMoney(to: CategoryID?)
  case profile
  /// The header's bell, on every tab.
  case notifications
  case period
  case widgetGallery
  case widgetConfig(HomeWidgetKind, entry: String?)
  case project(ProjectID?)
  case newProject(ProjectStarter)
  case addTransaction
  case addFromEmail(TxnID)
  case search

  var id: String {
    switch self {
    case .transaction(let id): "txn.\(id)"
    case .budget(let id): "budget.\(id)"
    case .moveMoney(let id): "move.\(id ?? "assign")"
    case .profile: "profile"
    case .notifications: "notifications"
    case .period: "period"
    case .widgetGallery: "widgetGallery"
    case .widgetConfig(let kind, let entry): "widgetConfig.\(kind.rawValue).\(entry ?? "new")"
    case .project(let id): "project.\(id ?? "new")"
    case .newProject(let starter): "project.new.\(starter.name)"
    case .addTransaction: "addTransaction"
    case .addFromEmail(let id): "addFromEmail.\(id)"
    case .search: "search"
    }
  }
}

/// Full-screen covers (focused flows without the tab bar).
enum CoverRoute: Hashable, Identifiable {
  /// The review deck.
  case review
  var id: Self { self }
}

struct ProjectStarter: Hashable {
  let name: String
  let glyph: Glyph

  static let quickStarts: [ProjectStarter] = [
    ProjectStarter(name: "Trip", glyph: .travel),
    ProjectStarter(name: "Move", glyph: .rent),
    ProjectStarter(name: "Eid gifts", glyph: .shopping),
  ]
}
