import Foundation
import Observation

/// Profile › Sign-in & security (spec 04 §6.9). Every change runs behind a step-up: a
/// passkey account confirms with Face ID in the system sheet; a password-only account
/// types its password in the "Confirm it's you" sheet and this iPhone's key signs too.
@MainActor
@Observable
final class SecurityModel {
  private let session: AccountSession
  private var account: AccountService { session.account }

  private(set) var state: SecurityState?
  var busy = false
  var failure: AuthFailure?
  /// A one-line confirmation after a change ("Removed from your Hasala account…").
  var notice: String?

  /// The pending change waiting for the password sheet (password-only accounts).
  var confirming: SecurityAction?
  var confirmPassword = ""

  /// Password set / change sheet.
  var editingPassword = false
  var newPassword = ""
  var confirmNewPassword = ""

  /// The phrase while "View your 12 words" is open.
  var viewedPhrase: [String]?
  var phraseRevealed = false

  init(session: AccountSession) {
    self.session = session
  }

  var isFrozen: Bool { state?.frozen != nil }

  /// The account actions this build can carry out; the screen offers only these.
  var capabilities: AccountCapabilities { session.capabilities }

  /// "Let's lock it down" (spec 04 §6.12) is a checklist of these steps; a build that can't
  /// carry them out doesn't offer it (Sign out everywhere and support stay on the page).
  var offersLockdown: Bool {
    capabilities.isSuperset(of: [
      .signOutEverywhere, .removePasskey, .removeDevice, .changePassword, .rotatePhrase, .freeze,
    ])
  }

  /// Whether any action Sign-in & security can show is missing from this build, so the
  /// screen points to support for it instead.
  var lacksAnAction: Bool {
    !capabilities.isSuperset(of: [
      .changeEmail, .addPasskey, .removePasskey, .changePassword, .removeDevice, .rotatePhrase, .freeze,
    ])
  }

  func load() async {
    do {
      state = try await account.securityState()
      failure = nil
    } catch {
      failure = error
    }
  }

  /// Starts a change: passkey accounts go straight to the step-up; password-only
  /// accounts confirm with their password first.
  func request(_ action: SecurityAction) async {
    guard let state else { return }
    if isFrozen, action != .unfreeze, action != .deleteAccount {
      failure = .frozen
      return
    }
    // The app never attempts #66 for an operator freeze (spec 04 §6.11).
    if action == .unfreeze, state.frozen?.by != .holder { return }
    if state.hasPasskey {
      await run(action, password: nil)
    } else {
      confirmPassword = ""
      confirming = action
    }
  }

  /// The "Confirm" button of the password sheet.
  func confirm() async {
    guard let action = confirming else { return }
    let pw = confirmPassword
    confirmPassword = ""
    confirming = nil
    await run(action, password: pw)
  }

  private func run(_ action: SecurityAction, password: String?) async {
    busy = true
    defer { busy = false }
    do {
      try await account.perform(action, password: password)
      failure = nil
      notice = Self.notice(for: action)
      switch action {
      case .freeze:
        session.froze(FreezeInfo(by: .holder, when: "just now"))
      case .deleteAccount, .signOutEverywhere:
        // Delete ends the account; sign out everywhere ends this iPhone's session too
        // (`02` §9.3: every session, the caller's included). Its keys stay here.
        session.signedOut()
        return
      case .unfreeze:
        session.unfroze()
      default:
        break
      }
      await load()
    } catch .frozenByOperator {
      // Only the operator lifts it: the banner and this page show their freeze instead.
      session.learnedOperatorFreeze()
      await load()
      failure = .frozenByOperator
    } catch {
      failure = error
    }
  }

  static func notice(for action: SecurityAction) -> String? {
    switch action {
    case .removePasskey: "Removed from your Hasala account. To remove it from this iPhone too, delete it in the Passwords app."
    case .addPasskey: "Passkey added."
    case .setPassword: "Password set. It signs you in; it never unlocks your data."
    case .changePassword: "Password changed. Your other devices were signed out."
    case .removePassword: "Password removed."
    case .removeDevice: "Device removed."
    default: nil
    }
  }

  // MARK: Password

  var newPasswordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [state?.email ?? "", session.account.profile?.displayName ?? ""])
  }

  var newPasswordReady: Bool {
    newPasswordAssessment.acceptable && !confirmNewPassword.isEmpty && newPassword == confirmNewPassword
  }

  func savePassword() async {
    guard newPasswordReady, let state else { return }
    let pw = newPassword
    newPassword = ""
    confirmNewPassword = ""
    editingPassword = false
    await request(state.hasPassword ? .changePassword(new: pw) : .setPassword(new: pw))
  }

  // MARK: Phrase

  func viewPhrase() async {
    busy = true
    defer { busy = false }
    do {
      viewedPhrase = try await account.viewRecoveryPhrase()
      phraseRevealed = false
    } catch {
      failure = error
    }
  }

  func closePhrase() {
    viewedPhrase = nil
    phraseRevealed = false
  }

  // MARK: Sign out

  func signOut() async {
    await account.signOut()
    session.signedOut()
  }
}
