import Foundation
import Observation

/// Sign in (C2, C2-P), forgot password on a new iPhone (C9 side N) and access recovery
/// (C4), Paper P2.3–P2.4. Shares the signed-out navigation path with `SignupModel`; the
/// onboarding store keeps it for the life of the process (plan B3), so Back and Forward
/// never clear what was typed.
@MainActor
@Observable
final class SignInModel {
  private let account: AccountService
  private let onOutcome: (SignInOutcome) -> Void

  var email = ""
  var password = ""
  var busy = false
  /// Which sign-in is under way, so only its button turns.
  private(set) var signingIn: SignInMethod?
  var failure: AuthFailure?
  /// The screen the failure belongs to: one model serves the whole signed-out stack, and a
  /// failure is shown only where it happened (a reset's error never shows on Sign in).
  private(set) var failureOn: WelcomeRoute?
  /// How the last sign-in failed was tried, so the passkey's failure shows by its button and
  /// the password's under its field.
  private(set) var lastTried: SignInMethod?

  // Forgot password
  var resetEmail = ""
  var resetCodeText = ""
  private(set) var reset: ResetTicket?
  /// When the last reset code was sent (the resend countdown runs from it).
  private(set) var resetCodeSentAt: Date?
  var newPassword = ""
  var confirmPassword = ""
  private(set) var waiting = false
  /// When the request to the other iPhone runs out (the countdown on "Check your other
  /// iPhone").
  private(set) var approvalDeadline: Date?
  /// The other iPhone said yes: signed in, data still locked here (Paper GUM).
  private(set) var resetApproved = false

  // Recovery
  var phraseText = ""
  private(set) var recovery: RecoveryTicket?
  private(set) var recoverCodeSentAt: Date?
  var recoverCode = ""
  /// The way to sign in `recover/verify` was sent with (`02` #48 binds the ceremony to it).
  private(set) var verifiedRecoveryKind: SignInMethod?
  /// Recovery finished with this new way to sign in ("You're back in", Paper H5V).
  private(set) var recovered: SignInMethod?
  /// The pasteboard's `changeCount` when the phrase field received a paste, so the
  /// pasteboard is cleared only if it still holds that paste (spec 04 §6.7).
  var pastedPhraseChangeCount: Int?

  /// How long the other iPhone has to answer (spec 04 §16.4: the request lives 10 minutes).
  static let approvalWindow: TimeInterval = 600

  init(account: AccountService, onOutcome: @escaping (SignInOutcome) -> Void) {
    self.account = account
    self.onOutcome = onOutcome
  }

  var capabilities: AccountCapabilities { account.capabilities }

  /// The failure to show on `route`, if it happened there.
  func failure(on route: WelcomeRoute) -> AuthFailure? {
    failureOn == route ? failure : nil
  }

  private func fail(_ f: AuthFailure, on route: WelcomeRoute) {
    failure = f
    failureOn = route
  }

  private func clearFailure() {
    failure = nil
    failureOn = nil
  }

  // MARK: Sign in

  func signInWithPasskey() async {
    busy = true
    signingIn = .passkey
    lastTried = .passkey
    defer {
      busy = false
      signingIn = nil
    }
    do {
      let outcome = try await account.signInWithPasskey()
      clearFailure()
      onOutcome(outcome)
    } catch {
      fail(error, on: .signIn)
    }
  }

  var passwordSignInReady: Bool { AccountFields.email(email) != nil && !password.isEmpty }

  func signInWithPassword() async {
    guard passwordSignInReady else { return }
    busy = true
    signingIn = .password
    lastTried = .password
    defer {
      busy = false
      signingIn = nil
    }
    do {
      let outcome = try await account.signInWithPassword(email: email, password: password)
      password = ""
      clearFailure()
      onOutcome(outcome)
    } catch {
      fail(error, on: .signIn)
      password = ""
    }
  }

  /// Typing again clears a wrong-password answer (page 11 §05: errors go when the person
  /// fixes the field).
  func passwordEdited() {
    if failureOn == .signIn, lastTried == .password, failure == .wrongCredentials { clearFailure() }
  }

  // MARK: Forgot password (C9 side N)

  func startReset() {
    resetEmail = email
    resetCodeText = ""
    reset = nil
    resetApproved = false
    clearFailure()
  }

  func submitResetEmail() async -> Bool {
    busy = true
    defer { busy = false }
    do {
      reset = try await account.beginPasswordReset(email: resetEmail)
      resetCodeSentAt = .now
      resetCodeText = ""
      clearFailure()
      return true
    } catch {
      fail(error, on: reset == nil ? .forgotEmail : .forgotCode)
      return false
    }
  }

  func submitResetCode() async -> Bool {
    guard let reset, resetCodeText.count == 6 else { return false }
    busy = true
    defer { busy = false }
    do {
      self.reset = try await account.verifyPasswordReset(reset, code: resetCodeText)
      clearFailure()
      return true
    } catch {
      // The digits stay, so the person can compare them with the email (page 11 §05).
      fail(error, on: .forgotCode)
      return false
    }
  }

  /// The person changes the code after a wrong one: the cells go back to typing.
  func resetCodeEdited() {
    if failureOn == .forgotCode, case .codeWrong = failure { clearFailure() }
  }

  var canApproveOnOtherPhone: Bool { reset?.approvers ?? false }

  var newPasswordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [resetEmail])
  }

  var newPasswordReady: Bool {
    newPasswordAssessment.acceptable && !confirmPassword.isEmpty && confirmPassword == newPassword
  }

  /// The new password comes before the request (finish binds it; spec 04 §16.4).
  func requestApproval() async -> Bool {
    guard let reset, newPasswordReady else { return false }
    busy = true
    defer { busy = false }
    do {
      self.reset = try await account.requestResetApproval(reset, newPassword: newPassword)
      newPassword = ""
      confirmPassword = ""
      approvalDeadline = .now.addingTimeInterval(Self.approvalWindow)
      clearFailure()
      return true
    } catch {
      fail(error, on: .forgotNewPassword)
      return false
    }
  }

  /// The reset code in four groups of four, as the other iPhone asks for it.
  var resetCodeGroups: String {
    guard let c = reset?.resetCode else { return "" }
    var out = ""
    for (i, ch) in c.enumerated() {
      if i > 0, i % 4 == 0 { out.append(" ") }
      out.append(ch)
    }
    return out
  }

  /// Polls every 3 s while on screen until approved, failed or the 10 minutes pass.
  func waitForApproval(interval: Duration = .seconds(3), limit: Duration = .seconds(600)) async {
    guard let reset else { return }
    waiting = true
    defer { waiting = false }
    let start = ContinuousClock.now
    while !Task.isCancelled {
      do {
        if try await account.pollResetApproval(reset) {
          clearFailure()
          resetApproved = true
          // Signed in, data still locked here (Paper GUM "You're in. Your data is still
          // locked."): the unlock screen says so.
          onOutcome(.needsUnlock(passkeyCanUnlock: false))
          return
        }
      } catch {
        fail(error, on: .forgotWaiting)
        return
      }
      if ContinuousClock.now - start > limit {
        fail(.approvalExpired, on: .forgotWaiting)
        return
      }
      try? await Task.sleep(for: interval)
    }
  }

  // MARK: Recovery (C4): the words first, then the code

  func submitRecoveryWords() async -> Bool {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      fail(f, on: .recoverWords)
      return false
    case .success(let words):
      busy = true
      defer { busy = false }
      do {
        recovery = try await account.beginRecovery(words: words)
        recoverCodeSentAt = .now
        recoverCode = ""
        verifiedRecoveryKind = nil
        clearFailure()
        return true
      } catch {
        fail(error, on: .recoverWords)
        return false
      }
    }
  }

  /// The six digits are only kept here: `recover/verify` needs the new way to sign in
  /// too (spec 04 §6.2 C4 step 3), so it is sent from the method screen.
  func submitRecoveryCode() -> Bool {
    guard recovery != nil, recoverCode.count == 6, recoverCode.allSatisfy(\.isASCII), recoverCode.allSatisfy(\.isNumber)
    else { return false }
    clearFailure()
    return true
  }

  enum RecoveryResult: Equatable {
    case done
    /// The code was refused: back to the code screen, whose line says why.
    case codeRejected
    case failed
  }

  /// `recover/verify {code, kind}` (once), then `recover/finish` with the new credential.
  func finishRecovery(_ credential: NewCredential) async -> RecoveryResult {
    guard let recovery else { return .failed }
    let screen: WelcomeRoute = credential.method == .passkey ? .recoverMethod : .recoverPassword
    busy = true
    defer { busy = false }
    if let kind = verifiedRecoveryKind, kind != credential.method {
      // The ceremony is bound to the kind it was verified with; its code is spent.
      fail(.badPhrase("This recovery was started for a \(kind == .passkey ? "passkey" : "password"). Go back to your words to choose again."),
           on: screen)
      return .failed
    }
    if verifiedRecoveryKind == nil {
      do {
        try await account.verifyRecovery(recovery, code: recoverCode, kind: credential.method)
        verifiedRecoveryKind = credential.method
      } catch {
        recoverCode = ""
        switch error {
        case .codeWrong, .codeExpired:
          fail(error, on: .recoverCode)
          return .codeRejected
        default:
          fail(error, on: screen)
          return .failed
        }
      }
    }
    do {
      try await account.finishRecovery(recovery, credential: credential)
      phraseText = ""
      recoverCode = ""
      newPassword = ""
      confirmPassword = ""
      clearFailure()
      recovered = credential.method
      return .done
    } catch {
      fail(error, on: screen)
      return .failed
    }
  }

  /// The first name for "You're back in, Maya." (empty when the service doesn't know it).
  var firstName: String { account.profile?.firstName ?? "" }
  /// The account's address for the done screens.
  var accountEmail: String { account.profile?.email ?? "" }

  /// "Go to Home" after "You're back in": the phrase opened the keys already.
  func recoveryDone() {
    onOutcome(.ready)
  }
}
