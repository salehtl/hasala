import Foundation
import Observation

/// Profile › Sign-in & security (spec 04 §6.9; Paper P2.5, P2.6). Every change goes through
/// "Confirm it's you" first: a passkey account confirms with Face ID (the system's passkey
/// sheet), a password-only account types its password and this iPhone's key signs too.
@MainActor
@Observable
final class SecurityModel {
  /// What a "Confirm it's you" sheet confirms.
  enum Confirmation: Equatable, Identifiable {
    /// A change on the server, behind its step-up.
    case perform(SecurityAction)
    /// "View recovery phrase" (`phrase.view`, passkey accounts only).
    case viewPhrase
    /// The step-up before a new address is typed.
    case changeEmail

    var id: String {
      switch self {
      case .perform(let a): "perform.\(a.explainer)"
      case .viewPhrase: "viewPhrase"
      case .changeEmail: "changeEmail"
      }
    }
  }

  /// Which page presents the confirmation: the one on top, so the sheet never opens from a
  /// page under another (and only the profile's large sheet sits under it).
  enum Host: Equatable { case page, passwordEditor, lockdown }

  private let session: AccountSession
  private var account: AccountService { session.account }

  private(set) var state: SecurityState?
  var busy = false
  var failure: AuthFailure?
  /// A one-line confirmation after a change ("Removed from your Hasala account…").
  var notice: String?

  /// The change waiting in "Confirm it's you", and the page that shows the sheet.
  private(set) var confirming: Confirmation?
  private(set) var confirmHost: Host = .page
  var confirmPassword = ""
  /// This iPhone has no key to sign with (its data is still sealed): the sheet says so.
  private(set) var lacksDeviceKey = false

  /// Set or change the password: the page is open.
  var editingPassword = false
  var newPassword = ""
  var confirmNewPassword = ""

  /// The phrase while "View your 12 words" is open; cleared when it closes.
  var viewedPhrase: [String]?
  var phraseRevealed = false
  /// A change of address under way (its cover is open).
  var emailChange: EmailChangeTicket?

  /// What opens once the confirmation sheet has gone (a sheet and a cover never present
  /// together).
  private var pendingPhrase: [String]?
  private var pendingEmailChange: EmailChangeTicket?

  init(session: AccountSession) {
    self.session = session
  }

  var isFrozen: Bool { state?.frozen != nil }

  /// The account actions this build can carry out; the screen offers only these.
  var capabilities: AccountCapabilities { session.capabilities }

  /// The account's address, for the confirmations' "We email … about it".
  var email: String { state?.email ?? account.profile?.email ?? "" }

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

  // MARK: Confirm it's you

  /// Starts a change: "Confirm it's you" opens on `host` (P2.6: one pattern for every
  /// sensitive action).
  func request(_ action: SecurityAction, host: Host = .page) async {
    guard let state else { return }
    if isFrozen, action != .unfreeze, action != .deleteAccount {
      failure = .frozen
      return
    }
    // The app never attempts #66 for an operator freeze (spec 04 §6.11).
    if action == .unfreeze, state.frozen?.by != .holder { return }
    ask(.perform(action), host: host)
  }

  /// "View recovery phrase": passkey accounts only (S-41), never while frozen.
  func requestPhrase() {
    guard let state, state.hasPasskey, capabilities.contains(.viewPhrase) else { return }
    if isFrozen {
      failure = .frozen
      return
    }
    ask(.viewPhrase, host: .page)
  }

  /// Email "Change".
  func requestEmailChange() {
    guard state != nil, capabilities.contains(.changeEmail) else { return }
    if isFrozen {
      failure = .frozen
      return
    }
    ask(.changeEmail, host: .page)
  }

  private func ask(_ c: Confirmation, host: Host) {
    failure = nil
    notice = nil
    confirmPassword = ""
    lacksDeviceKey = false
    confirmHost = host
    confirming = c
  }

  /// How this account confirms.
  var confirmFactor: ConfirmRequest.Factor {
    if state?.hasPasskey == true { return .faceID }
    return lacksDeviceKey ? .noKey : .password
  }

  /// The sheet's words for the change waiting in it.
  var confirmRequest: ConfirmRequest? {
    guard let confirming else { return nil }
    let (title, bullets) = Self.words(for: confirming, email: email, state: state)
    return ConfirmRequest(title: title, factor: confirmFactor, bullets: bullets,
                          otherDevice: state?.devices.first { !$0.isThisDevice }?.title)
  }

  /// The sheet's primary: the change, behind its step-up. A wrong password or a closed
  /// Face ID keeps the sheet; a missing key turns it into "can't confirm yet"; anything
  /// else closes it and the page says why.
  func confirm() async {
    guard let c = confirming else { return }
    let password = state?.hasPasskey == true ? nil : confirmPassword
    busy = true
    defer { busy = false }
    do throws(AuthFailure) {
      switch c {
      case .perform(let action):
        try await account.perform(action, password: password)
        closeConfirmation()
        await performed(action)
      case .viewPhrase:
        let words = try await account.viewRecoveryPhrase()
        closeConfirmation()
        pendingPhrase = words
      case .changeEmail:
        let ticket = try await account.beginEmailChange(password: password)
        closeConfirmation()
        pendingEmailChange = ticket
      }
    } catch .cancelled {
      // Face ID or the passkey sheet closed: still up, nothing to say.
    } catch .stepUpFailed {
      confirmPassword = ""
      failure = .stepUpFailed
    } catch .noDeviceKey {
      confirmPassword = ""
      failure = nil
      lacksDeviceKey = true
    } catch .frozenByOperator {
      // Only the operator lifts it: the banner and this page show their freeze instead.
      closeConfirmation()
      session.learnedOperatorFreeze()
      await load()
      failure = .frozenByOperator
    } catch .sessionEnded {
      // The server ended the session (an operator freeze revokes them all): sign in again.
      closeConfirmation()
      session.signedOut()
    } catch {
      closeConfirmation()
      failure = error
    }
  }

  /// Close (or a swipe down) on the sheet: nothing changes.
  func cancelConfirmation() {
    guard !busy else { return }
    closeConfirmation()
    failure = nil
  }

  private func closeConfirmation() {
    confirming = nil
    confirmPassword = ""
    lacksDeviceKey = false
  }

  /// The confirmation sheet has gone: what it opened can show now.
  func confirmationDismissed() {
    if let words = pendingPhrase {
      pendingPhrase = nil
      phraseRevealed = false
      viewedPhrase = words
    }
    if let ticket = pendingEmailChange {
      pendingEmailChange = nil
      emailChange = ticket
    }
  }

  private func performed(_ action: SecurityAction) async {
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
    case .setPassword, .changePassword:
      newPassword = ""
      confirmNewPassword = ""
      editingPassword = false
    default:
      break
    }
    await load()
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

  /// The sheet's title and bullets for each change (Paper IHY, INK; the rest in their
  /// voice).
  static func words(for c: Confirmation, email: String, state: SecurityState?) -> (String, [String]) {
    let weEmail = email.isEmpty ? "We email you about it" : "We email \(email) about it"
    switch c {
    case .viewPhrase:
      return ("Show your 12 words", ["Shown on this screen only", "They hide again when you leave"])
    case .changeEmail:
      return ("Change your email", ["A code goes to both addresses next", "Nothing changes until both match"])
    case .perform(let action):
      switch action {
      case .addPasskey:
        return ("Add a passkey", ["iOS asks where to save it next", weEmail])
      case .removePasskey(let id):
        let name = state?.passkeys.first { $0.id == id }?.provider ?? "this"
        return ("Remove the \(name) passkey", ["The \(name) passkey can't sign in any more", weEmail])
      case .setPassword:
        return ("Set a password", ["It signs you in; it never unlocks your data", weEmail])
      case .changePassword:
        return ("Change your password", ["Other devices are signed out", weEmail])
      case .removePassword:
        return ("Remove your password", ["You'll sign in with your passkey only", weEmail])
      case .removeDevice(let id):
        let name = state?.devices.first { $0.id == id }?.title ?? "this device"
        return ("Remove \(name)", ["It's signed out now", "Its copy of your data is erased the next time it opens Hasala"])
      case .signOutEverywhere:
        return ("Sign out everywhere", ["Every device signs out, this one too", "Your sealed backup stays"])
      case .freeze:
        return ("Freeze your account", ["Everyone is signed out", "Sign-in and key changes stop until you unfreeze it"])
      case .unfreeze:
        return ("Unfreeze your account", ["Sign-in and key changes work again"])
      case .deleteAccount:
        return ("Delete your account", ["Everything is erased, here and on our server",
                                        email.isEmpty ? "We email you to confirm" : "We email \(email) to confirm"])
      }
    }
  }

  // MARK: Password

  var newPasswordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [state?.email ?? "", session.account.profile?.displayName ?? ""])
  }

  var newPasswordReady: Bool {
    newPasswordAssessment.acceptable && !confirmNewPassword.isEmpty && newPassword == confirmNewPassword
  }

  /// "Save password" on the password page: its confirmation opens over the page, which
  /// closes once the change is through.
  func savePassword() async {
    guard newPasswordReady, let state else { return }
    // The typed password stays until the change is through: a cancelled confirmation
    // leaves the page as it was.
    let pw = newPassword
    await request(state.hasPassword ? .changePassword(new: pw) : .setPassword(new: pw), host: .passwordEditor)
  }

  // MARK: Phrase

  func closePhrase() {
    viewedPhrase = nil
    phraseRevealed = false
  }

  // MARK: Email change

  /// The change-email cover closed (done or cancelled).
  func finishEmailChange(to newEmail: String?) async {
    emailChange = nil
    if let newEmail {
      notice = "Email changed. Codes and alerts go to \(newEmail) now."
      await load()
    }
  }

  var accountForEmailChange: AccountService { account }

  // MARK: Sign out

  func signOut() async {
    await account.signOut()
    session.signedOut()
  }

  /// IYT "Enter my 12 words": this iPhone opens its data with the words, which gives it
  /// the key a password confirmation needs.
  func enterWordsToUnlock() {
    closeConfirmation()
    session.signedIn(.needsUnlock(passkeyCanUnlock: false))
  }
}
