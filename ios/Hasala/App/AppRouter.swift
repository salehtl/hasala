import Observation

/// Where the app is: the selected tab, every tab's push path, the sheet and the cover.
/// One router per `AppModel` (so per open account), shared by every screen, so anything
/// can open any screen with a real back stack behind it (Paper "Back, deep links and
/// scrolling": "Open the thing it names, inside its own tab").
///
/// The shell presents what the router says: `MainView` binds the tab bar, the sheet and
/// the cover; each tab's stack binds its path; the profile and transaction sheets bind
/// theirs.
@MainActor
@Observable
final class AppRouter {
  var tab: AppTab = .home
  var home: [HomeRoute] = []
  var plan: [PlanRoute] = []
  var activity: [ActivityRoute] = []
  var review: [ReviewRoute] = []
  var profile: [ProfileRoute] = []
  var transaction: [TransactionRoute] = []
  var sheet: SheetRoute?
  var cover: CoverRoute?
  /// Sheet B after sheet A closes (never two at once): the bell row "Sign in again" opens
  /// Profile › Bank alerts.
  var nextSheet: (SheetRoute, profilePath: [ProfileRoute])?

  #if HASALA_MOCKS
    /// What a Debug launch argument presents once the shell is on screen (`ScreenLaunch`).
    var pendingLaunch: PendingLaunch?
  #endif

  /// Presents `route`, with `path` pushed inside it when it is the profile. A sheet that
  /// is up closes first; `route` follows it (`presentNext`, from the sheet's dismissal).
  func open(_ route: SheetRoute, profile path: [ProfileRoute] = []) {
    if sheet != nil {
      nextSheet = (route, path)
      sheet = nil
      return
    }
    present(route, profile: path)
  }

  /// A sheet went: its pushed pages go with it (the next one opens at its root, as a
  /// fresh sheet did when each held its own path), then the queued sheet comes up.
  func sheetDismissed() {
    guard sheet == nil else { return }
    MailConnectCoordinator.release()
    profile = []
    transaction = []
    guard let next = nextSheet else { return }
    nextSheet = nil
    present(next.0, profile: next.profilePath)
  }

  /// The selected tab tapped again: back to its root.
  func popToRoot(_ tab: AppTab) {
    switch tab {
    case .home: home = []
    case .plan: plan = []
    case .activity: activity = []
    case .review: review = []
    case .add: break
    }
  }

  /// No sheet, no cover and nothing queued (the shell appearing again, after signing out
  /// and back in).
  func clearPresentation() {
    sheet = nil
    cover = nil
    nextSheet = nil
  }

  private func present(_ route: SheetRoute, profile path: [ProfileRoute]) {
    switch route {
    case .profile: profile = path
    case .transaction: transaction = []
    default: break
    }
    sheet = route
  }
}

#if HASALA_MOCKS
  /// What a `ScreenLaunch` id presents after the shell appears (`MainView.onAppear` first
  /// clears presentation, then applies this, so a launched sheet or cover stays).
  struct PendingLaunch {
    var sheet: SheetRoute?
    var cover: CoverRoute?
    var profile: [ProfileRoute] = []
    var transaction: [TransactionRoute] = []
  }
#endif
