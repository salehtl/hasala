import HasalaModels
import Observation

/// Pages pushed inside the profile sheet (spec 04 §13.3 `.profile(ProfileRoute?)`).
enum ProfileRoute: Hashable {
  case bankAlerts, accounts, bills, rules, security, notifications, privacy, help
}

/// Profile · Your profile and its settings pages (spec 04 §16.1 "Profile · Your profile" and its page-14 variant, "Profile · Categories and rules";
/// §16.2 X2, X6).
@MainActor
protocol ProfileModel: AnyObject, Observable {
  var snapshot: ProfileSnapshot { get }
  var rules: [RuleRowModel] { get }
  var hidden: Bool { get }
  var exportRows: [ExportRow] { get }
  var today: LocalDate { get }
  func setFaceIDLock(_ on: Bool)
  func setNotifications(_ level: DevicePrefs.NotificationLevel)
  func setRule(_ id: RuleID, enabled: Bool)
  func signOut()
  func deleteAccount()
}

@MainActor
@Observable
final class ProfileViewModel: ProfileModel {
  private let app: AppModel

  @ObservationIgnored private var memo = Memo<Int, ProfileSnapshot>()
  @ObservationIgnored private var rulesMemo = Memo<Int, [RuleRowModel]>()

  init(app: AppModel) { self.app = app }

  var snapshot: ProfileSnapshot {
    memo.value(for: app.store.revision) { ProfileEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var rules: [RuleRowModel] { rulesMemo.value(for: app.store.revision) { ProfileEngine.rules(app.store.state) } }
  var hidden: Bool { app.amountsHidden }
  var today: LocalDate { app.store.now.date }

  /// Everything, archived rows included (Settings › Export your data, spec 04 §16.2 X6).
  var exportRows: [ExportRow] {
    let s = app.store.state
    return s.txns.sorted { $0.postedAt > $1.postedAt }.map { ExportRow($0, s) }
  }

  // TODO(spec 04 §11, §16.2 X3): the toggle drives AppLockController (Face ID + grace).
  func setFaceIDLock(_ on: Bool) { app.perform(.setFaceIDLock(on)) }

  // TODO(spec 04 §9.3): asking for notification permission and the planner (§9.2).
  func setNotifications(_ level: DevicePrefs.NotificationLevel) { app.perform(.setNotifications(level)) }

  func setRule(_ id: RuleID, enabled: Bool) { app.perform(.setRuleEnabled(id, enabled)) }

  // TODO(spec 04 §6.2, §4.7 row 1; S-26): sign-out alerts and wiping this iPhone's keys
  // belong to the accounts lane; the button is wired to its confirmation only.
  func signOut() { app.say("Sign out arrives with accounts", systemImage: "rectangle.portrait.and.arrow.right") }

  // TODO(spec 04 §16.1 "Profile · Delete your account"; S-22): DeleteAccountView.
  func deleteAccount() { app.say("Deleting an account arrives with accounts", systemImage: "trash") }
}
