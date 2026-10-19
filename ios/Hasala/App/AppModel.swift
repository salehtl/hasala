import HasalaDesign
import HasalaModels
import Observation
import SwiftUI
import UIKit

/// App-wide UI state: the ledger the screens read and write, Hide amounts (which applies
/// to every screen, spec 04 §12), the transient toast with its Undo, and routing
/// (`router`: the selected tab, every push path, the presented sheet and cover; `tab`,
/// `sheet` and `cover` forward to it so callers read as before).
///
/// The store is the Maya mock in Debug builds; the live store over HasalaCore's
/// projection replaces it (spec 04 §15.2) without changing anything here.
@MainActor
@Observable
final class AppModel {
  struct Toast: Equatable {
    /// The leading disc (Paper page 14 §03): the accent check when something was done, an
    /// ink disc with a glyph for a note (amounts hidden, a refusal).
    enum Disc: Equatable {
      case done
      case note(HIcon)
    }

    var disc: Disc
    var title: String
    var subtitle: String?
    var actionTitle: String?
    /// The edit the toast's "Undo" takes back.
    var undo: UndoToken?
  }

  let store: any LedgerStore
  /// The mail lane as setup uses it: the mailboxes, and what the bell, Profile and Bank
  /// alerts offer.
  @ObservationIgnored let mailbox: (any MailboxConnecting)?
  private(set) var amountsHidden: Bool
  private(set) var toast: Toast?
  /// Where the app is: the selected tab, every push path, the sheet and the cover.
  let router = AppRouter()
  var tab: AppTab {
    get { router.tab }
    set { router.tab = newValue }
  }
  var sheet: SheetRoute? {
    get { router.sheet }
    set { router.sheet = newValue }
  }
  var cover: CoverRoute? {
    get { router.cover }
    set { router.cover = newValue }
  }
  /// Needs-you cards put off with "Later".
  // TODO(spec 04 §16.1 "Home · Default", 03a §6.15): device-local until the next local midnight,
  // kept in DevicePrefs so it survives a relaunch.
  private(set) var snoozed: Set<String> = []

  /// Pull to refresh on Home and Activity: a sync and a Gmail check now, set by the live
  /// graph once the account is open. Nil (the Maya mock) ends the pull at once.
  @ObservationIgnored var refreshWork: (@MainActor () async -> Void)?

  private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var homeMemo = Memo<HomeMemoKey, HomeSnapshot>()
  private var chosenPeriod: Period?
  @ObservationIgnored private var reviewMemo = Memo<ReviewMemoKey, Int>()
  @ObservationIgnored private var thisMonthMemo = Memo<Int, HomeSnapshot>()
  @ObservationIgnored private var earliestMemo = Memo<Int, YearMonth?>()
  @ObservationIgnored private var canvasMemo = Memo<CanvasMemoKey, [HomeCanvasItem]>()
  @ObservationIgnored private var previewMemo = Memo<Int, [HomeWidgetKind: HomeCanvasItem]>()

  @ObservationIgnored let layouts: HomeLayoutStore?
  private(set) var homeLayout: HomeLayout?
  var editingHome = false

  init(
    store: any LedgerStore, amountsHidden: Bool = false, mailbox: (any MailboxConnecting)? = nil,
    layouts: HomeLayoutStore? = nil
  ) {
    self.store = store
    self.amountsHidden = amountsHidden
    self.mailbox = mailbox
    self.layouts = layouts
    homeLayout = layouts?.load()
  }

  var homeCanvas: [HomeCanvasItem] {
    let layout = homeLayout
    return canvasMemo.value(for: CanvasMemoKey(revision: store.revision, layout: layout)) {
      HomeEngine.canvas(layout, store.state, now: store.now)
    }
  }

  var currentHomeLayout: HomeLayout { homeLayout ?? HomeLayout(homeCanvas.map(\.entry)) }

  var widgetPreviews: [HomeWidgetKind: HomeCanvasItem] {
    previewMemo.value(for: store.revision) { HomeEngine.previews(store.state, now: store.now) }
  }

  func suggestedWidgetConfig(_ kind: HomeWidgetConfig.Kind) -> HomeWidgetConfig? {
    HomeEngine.suggested(kind, store.state, now: store.now)
  }

  func widgetOptions(_ kind: HomeWidgetConfig.Kind) -> [HomeWidgetOption] {
    HomeEngine.options(kind, store.state, now: store.now)
  }

  @discardableResult
  func addWidget(_ entry: HomeLayout.Entry) -> Bool {
    changeHomeLayout { $0.add(entry) }
  }

  @discardableResult
  func removeWidget(_ id: String) -> Bool {
    let done = changeHomeLayout { $0.remove(id) }
    if done, homeLayout?.isEmpty == true { editingHome = false }
    return done
  }

  @discardableResult
  func moveWidget(_ id: String, to index: Int) -> Bool {
    changeHomeLayout { $0.move(id, to: index) }
  }

  @discardableResult
  func moveWidget(_ id: String, by offset: Int) -> Bool {
    changeHomeLayout { $0.move(id, by: offset) }
  }

  @discardableResult
  func configureWidget(_ id: String, _ config: HomeWidgetConfig) -> Bool {
    changeHomeLayout { $0.configure(id, config) }
  }

  func forgetHomeLayout() {
    editingHome = false
    homeLayout = nil
    layouts?.forget()
  }

  private func changeHomeLayout(_ change: (inout HomeLayout) -> Bool) -> Bool {
    var layout = currentHomeLayout
    guard change(&layout) else { return false }
    homeLayout = layout
    layouts?.save(layout)
    return true
  }

  /// "Connect your email" or "Sign in again" on the bell, Profile and Bank alerts, when
  /// mail needs it.
  var mailOffer: MailOffer? { mailbox?.offer }

  var period: Period {
    get { chosenPeriod?.clamped(to: store.now.date.yearMonth) ?? .month(store.now.date.yearMonth) }
    set {
      let today = store.now.date.yearMonth
      let p = newValue.clamped(to: today)
      chosenPeriod = p == .month(today) ? nil : p
    }
  }

  /// What Home draws, recomputed once per ledger change or period.
  var snapshot: HomeSnapshot {
    let period = chosenPeriod
    return homeMemo.value(for: HomeMemoKey(revision: store.revision, period: period)) {
      HomeEngine.snapshot(store.state, now: store.now, period: period)
    }
  }

  var earliestMonth: YearMonth? {
    earliestMemo.value(for: store.revision) { store.state.txns.lazy.map(\.postedAt.date.yearMonth).min() }
  }

  var thisMonthSnapshot: HomeSnapshot {
    if chosenPeriod == nil { return snapshot }
    return thisMonthMemo.value(for: store.revision) { HomeEngine.snapshot(store.state, now: store.now) }
  }

  /// The header's avatar letter, without running the Home engine on every tab.
  var avatarInitial: String { store.state.profile.initial }

  /// Transactions waiting to be sorted in Home's period: the Review tab's badge, once per
  /// ledger or period change.
  var reviewCount: Int {
    let window = reviewWindow
    return reviewMemo.value(for: ReviewMemoKey(revision: store.revision, window: window)) {
      ReviewEngine.queue(store.state, in: window).count
    }
  }

  var reviewWindow: ReviewWindow { ReviewWindow(period) }

  var showingProfile: Bool {
    get { sheet == .profile }
    set { sheet = newValue ? .profile : (sheet == .profile ? nil : sheet) }
  }

  /// Pull to refresh: waits for the run, so the spinner shows until the screens reload.
  func refresh() async {
    await refreshWork?()
  }

  /// The header eye (Paper "Home · Amounts hidden"): hiding persists until it is toggled back; a
  /// toast confirms it and offers "Show".
  func toggleAmountsHidden() {
    amountsHidden.toggle()
    if amountsHidden {
      show(Toast(disc: .note(.eyeSlash), title: "Amounts hidden", subtitle: "Until you tap the eye again",
                 actionTitle: "Show"))
    } else {
      dismissToast()
    }
  }

  /// Applies one edit. An undoable edit shows its toast with "Undo"; a refusal shows
  /// why. Returns whether the edit was applied.
  @discardableResult
  func perform(_ edit: LedgerEdit) -> Bool {
    do {
      if let token = try store.apply(edit) {
        show(Toast(disc: .done, title: token.title, actionTitle: "Undo", undo: token))
      }
      return true
    } catch {
      show(Toast(disc: .note(.info), title: Self.message(for: error)))
      return false
    }
  }

  /// Shows a one-line confirmation without an action: the accent check, or `icon` on the
  /// ink disc for a note.
  func say(_ title: String, icon: HIcon? = nil) {
    show(Toast(disc: icon.map { .note($0) } ?? .done, title: title))
  }

  func toastAction() {
    if let undo = toast?.undo {
      store.undo(undo)
      dismissToast()
    } else if amountsHidden, toast?.actionTitle == "Show" {
      toggleAmountsHidden()
    } else {
      dismissToast()
    }
  }

  func dismissToast() {
    toastTask?.cancel()
    toast = nil
  }

  /// The toast is touched: it stays while the finger is down, then for a full dwell after.
  func holdToast(_ held: Bool) {
    guard toast != nil else { return }
    toastTask?.cancel()
    if !held { scheduleToastEnd() }
  }

  func open(_ txn: TxnID) { router.open(.transaction(txn)) }

  func snooze(_ card: String) { snoozed.insert(card) }

  func startReview() { cover = .review }

  static func message(for error: ActionError) -> String {
    switch error {
    case .notFound: "That's no longer there"
    case .splitDoesNotAddUp: "The split doesn't add up"
    case .insufficientFunds: "There isn't enough to move"
    case .invalidAmount: "Enter an amount"
    case .invalidProject: "Check the project's name, amount and dates"
    }
  }

  /// One toast at a time: a new one replaces the old (plan decision 4). It stays about 4 s,
  /// 8 s while VoiceOver runs, longer while touched; that is also the window for its Undo.
  /// VoiceOver hears it without losing its place ("Sorted into Groceries. Undo available.").
  /// The motion is `ToastHost`'s.
  // TODO(spec 04 §14.6): pause the window while the app is in the background (pwa `pausableTimeout`).
  private func show(_ t: Toast) {
    toast = t
    AccessibilityNotification.Announcement(Self.announcement(for: t)).post()
    scheduleToastEnd()
  }

  private func scheduleToastEnd() {
    toastTask?.cancel()
    let dwell = UIAccessibility.isVoiceOverRunning ? HMotion.toastDwellVoiceOver : HMotion.toastDwell
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(dwell))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  /// What VoiceOver says when a toast appears: the message, then the action it offers.
  static func announcement(for t: Toast) -> String {
    // Toasts carry no closing full stop ("Sorted into Groceries"); some lines already end in one.
    func sentence(_ s: String) -> String { s.hasSuffix(".") ? s : s + "." }
    let parts = [t.title, t.subtitle].compactMap { $0 } + [t.actionTitle.map { "\($0) available" }].compactMap { $0 }
    return parts.map(sentence).joined(separator: " ")
  }
}

struct CanvasMemoKey: Equatable {
  var revision: Int
  var layout: HomeLayout?
}

struct HomeMemoKey: Equatable {
  var revision: Int
  var period: Period?
}

struct ReviewMemoKey: Hashable {
  var revision: Int
  var window: ReviewWindow
}
