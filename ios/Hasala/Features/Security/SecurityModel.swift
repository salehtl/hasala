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
      case .deleteAccount:
        session.signedOut()
        return
      case .unfreeze:
        session.unfroze()
      default:
        break
      }
      await load()
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
    case .signOutEverywhere: "Signed out everywhere else."
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
