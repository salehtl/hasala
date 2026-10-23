import CorePrimitives
import Foundation
import HasalaKeychain

/// What this iPhone notes about the open account outside its store, in `UserDefaults`
/// (spec 04 §4.5), and forgetting it when the account's data leaves this iPhone.
///
/// §4.5 allows no identifier there but `installID`, so nothing here names the account or
/// a transaction: the setup flag is a Bool (one account per iPhone, `BootController`
/// enforces it), and the keys that must tell values apart (the push registration, the
/// skipped review cards) keep `digest`s, which name nothing outside this install.
@MainActor
enum LocalAccountData {
  /// "Go to Home" on the last setup board ran on this iPhone (§4.5).
  static let setupFinishedKey = "app.hasala.prefs.setup.finished"
  /// The earlier form: an array of user ids. Read once at launch, then removed.
  static let legacySetupFinishedKey = "setup.finished.v1"
  /// Which mailbox provider the account's lane on this iPhone reads ("gmail" or "outlook").
  static let mailboxProviderKey = "app.hasala.prefs.mailbox.provider"

  static func mailboxProvider(_ defaults: UserDefaults = .standard) -> MailboxProvider? {
    defaults.string(forKey: mailboxProviderKey).flatMap(MailboxProvider.init(rawValue:))
  }

  static func setMailboxProvider(_ p: MailboxProvider, _ defaults: UserDefaults = .standard) {
    defaults.set(p.rawValue, forKey: mailboxProviderKey)
  }

  static func setupFinished(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: setupFinishedKey)
  }

  static func markSetupFinished(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: setupFinishedKey)
  }

  /// Moves the earlier array of user ids to the Bool (true when it named the bound
  /// account), then removes it.
  static func migrate(boundUserID: String?, defaults: UserDefaults = .standard) {
    guard let ids = defaults.stringArray(forKey: legacySetupFinishedKey) else { return }
    if let u = boundUserID, ids.contains(u) { markSetupFinished(defaults) }
    defaults.removeObject(forKey: legacySetupFinishedKey)
  }

  /// The account's data left this iPhone (deleted here or elsewhere, removed, wiped from
  /// a wall): forget the setup flag, the mailbox provider, the skipped review cards, the push registration,
  /// the recent searches (held in memory only) and, in Debug simulator runs, the simulator's
  /// approval keys.
  static func forget(defaults: UserDefaults = .standard) {
    SearchHistory.shared.clear()
    WidgetLinkInbox.shared.pending = nil
    defaults.removeObject(forKey: setupFinishedKey)
    defaults.removeObject(forKey: legacySetupFinishedKey)
    defaults.removeObject(forKey: mailboxProviderKey)
    DevicePrefsStore(defaults: defaults).forgetAccountData()
    MerchantSuggestionsSetting.forget(defaults)
    TrustCounts.forget(defaults)
    defaults.removeObject(forKey: "app.hasala.prefs.cloudSort.runOffer")
    defaults.removeObject(forKey: "app.hasala.prefs.cloudSort.dismissedRun")
    StoredUnseenPhrase.forget(defaults)
    ManualEntryChoice.forget(defaults)
    HomeLayoutStore.forgetAll(defaults)
    NotificationReads.forget(defaults)
    PushRegistrar.forgetRegistration(defaults)
    #if DEBUG && targetEnvironment(simulator)
      SimulatorApprovalKey.forgetAll(defaults)
    #endif
  }

  /// `value` as 16 hex digits of SHA-256 over this install's id and the value: equal
  /// values give equal digests on this iPhone, and a digest names nothing elsewhere.
  nonisolated static func digest(_ value: String, salt: String) -> String {
    Hex.encode(sha256(Data("\(salt)|\(value)".utf8)).prefix(8))
  }

  /// This install's salt for `digest` (`app.hasala.installID`, set by the purge).
  nonisolated static func salt(_ defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: InstallCheck.installIDKey) ?? ""
  }
}
