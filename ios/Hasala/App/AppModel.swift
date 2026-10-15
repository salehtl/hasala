import HasalaModels
import Observation
import SwiftUI

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
    var systemImage: String
    var title: String
    var subtitle: String?
    var actionTitle: String?
    /// The edit the toast's "Undo" takes back.
    var undo: UndoToken?
  }

  let store: any LedgerStore
  /// The Gmail lane as setup uses it: what Home and Profile offer for Gmail.
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
  @ObservationIgnored private var homeMemo = Memo<Int, HomeSnapshot>()
  @ObservationIgnored private var reviewMemo = Memo<Int, Int>()

  init(store: any LedgerStore, amountsHidden: Bool = false, mailbox: (any MailboxConnecting)? = nil) {
    self.store = store
    self.amountsHidden = amountsHidden
    self.mailbox = mailbox
  }

  /// "Connect Gmail" or "Reconnect Gmail" on Home and Profile, when Gmail needs it.
  var gmailOffer: GmailOffer? { mailbox?.gmailOffer }

  /// What Home draws, recomputed once per ledger change.
  var snapshot: HomeSnapshot {
    homeMemo.value(for: store.revision) { HomeEngine.snapshot(store.state, now: store.now) }
  }

  /// The header's avatar letter, without running the Home engine on every tab.
  var avatarInitial: String { store.state.profile.initial }

  /// Transactions waiting to be sorted: the Review tab's badge (it never follows the
  /// period, Paper "13 · Navigation"), once per ledger change.
  var reviewCount: Int {
    reviewMemo.value(for: store.revision) { ReviewEngine.queue(store.state).count }
  }

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
      show(Toast(systemImage: "eye.slash", title: "Amounts hidden", subtitle: "Until you tap the eye again",
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
        show(Toast(systemImage: "checkmark", title: token.title, actionTitle: "Undo", undo: token))
      }
      return true
    } catch {
      show(Toast(systemImage: "exclamationmark", title: Self.message(for: error)))
      return false
    }
  }

  /// Shows a one-line confirmation without an action.
  func say(_ title: String, systemImage: String = "checkmark") {
    show(Toast(systemImage: systemImage, title: title))
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

  func open(_ txn: TxnID) { router.open(.transaction(txn)) }

  func snooze(_ card: String) { snoozed.insert(card) }

  func startReview() { cover = .review }

  static func message(for error: ActionError) -> String {
    switch error {
    case .notFound: "That's no longer there"
    case .splitDoesNotAddUp: "The split doesn't add up"
    case .insufficientFunds: "There isn't enough to move"
    case .invalidAmount: "Enter an amount"
    }
  }

  /// The undo window is 5 s (spec 04 §14.6).
  // TODO(spec 04 §14.6): pause the window while the app is in the background (pwa `pausableTimeout`).
  private func show(_ t: Toast) {
    toastTask?.cancel()
    withAnimation(.snappy) { toast = t }
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      withAnimation(.snappy) { self?.toast = nil }
    }
  }
}
