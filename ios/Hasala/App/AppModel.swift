import HasalaModels
import Observation
import SwiftUI

/// The tabs (spec 04 §13.1).
enum AppTab: Hashable {
  case home, plan, activity, search
}

/// Large sheets over the tabs (spec 04 §13.3).
enum SheetRoute: Hashable, Identifiable {
  case transaction(TxnID)
  case budget(CategoryID)
  case moveMoney(to: CategoryID?)
  case profile
  /// Connect a mailbox after setup, from Home's Needs-you card.
  case connectMailbox(MailboxOffer)

  var id: String {
    switch self {
    case .transaction(let id): "txn.\(id)"
    case .budget(let id): "budget.\(id)"
    case .moveMoney(let id): "move.\(id ?? "assign")"
    case .profile: "profile"
    case .connectMailbox(let offer): offer.id
    }
  }
}

/// Full-screen covers (spec 04 §13.3).
enum CoverRoute: Hashable, Identifiable {
  case review
  var id: Self { self }
}

/// App-wide UI state: the ledger the screens read and write, Hide amounts (which applies
/// to every screen, spec 04 §12), the transient toast with its Undo, and routing
/// (spec 04 §13.4: the selected tab, the presented sheet and cover).
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
  /// The mailbox lanes as setup uses them: what Home and Profile offer for the mailbox.
  @ObservationIgnored let mailbox: (any MailboxConnecting)?
  private(set) var amountsHidden: Bool
  private(set) var toast: Toast?
  var tab: AppTab = .home
  var sheet: SheetRoute?
  var cover: CoverRoute?
  /// Needs-you cards put off with "Later".
  // TODO(spec 04 §16.1 "Home · Default", 03a §6.15): device-local until the next local midnight,
  // kept in DevicePrefs so it survives a relaunch.
  private(set) var snoozed: Set<String> = []

  /// Pull to refresh on Home and Activity: a sync and a mailbox check now, set by the live
  /// graph once the account is open. Nil (the Maya mock) ends the pull at once.
  @ObservationIgnored var refreshWork: (@MainActor () async -> Void)?

  private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var homeMemo = Memo<Int, HomeSnapshot>()

  init(store: any LedgerStore, amountsHidden: Bool = false, mailbox: (any MailboxConnecting)? = nil) {
    self.store = store
    self.amountsHidden = amountsHidden
    self.mailbox = mailbox
  }

  /// "Connect your email" or "Reconnect Gmail" on Home and Profile, when the mailbox needs it.
  var mailboxOffer: MailboxOffer? { mailbox?.mailboxOffer }

  /// What Home draws, recomputed once per ledger change.
  var snapshot: HomeSnapshot {
    homeMemo.value(for: store.revision) { HomeEngine.snapshot(store.state, now: store.now) }
  }

  /// The header's avatar letter, without running the Home engine on every tab.
  var avatarInitial: String { store.state.profile.initial }

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

  func open(_ txn: TxnID) { sheet = .transaction(txn) }

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
