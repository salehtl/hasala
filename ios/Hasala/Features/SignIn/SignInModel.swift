import Foundation
import Observation

/// Sign in (C2, C2-P), forgot password on a new iPhone (C9 side N) and access recovery
/// (C4), Paper page 14 sections 14.3-14.4. Shares the signed-out navigation path with
/// `SignupModel`.
@MainActor
@Observable
final class SignInModel {
  private let account: AccountService
  private let onOutcome: (SignInOutcome) -> Void

  var email = ""
  var password = ""
  var busy = false
  var failure: AuthFailure?

  // Forgot password
  var resetEmail = ""
  var resetCodeText = ""
  private(set) var reset: ResetTicket?
  var newPassword = ""
  var confirmPassword = ""
  private(set) var waiting = false

  // Recovery
  var phraseText = ""
  private(set) var recovery: RecoveryTicket?
  var recoverCode = ""
  var recoverMethod: SignInMethod = .passkey

  init(account: AccountService, onOutcome: @escaping (SignInOutcome) -> Void) {
    self.account = account
    self.onOutcome = onOutcome
  }

  // MARK: Sign in

  func signInWithPasskey() async {
    busy = true
    defer { busy = false }
    do {
      let outcome = try await account.signInWithPasskey()
      failure = nil
      onOutcome(outcome)
    } catch {
      failure = error
    }
  }

  var passwordSignInReady: Bool { AccountFields.email(email) != nil && !password.isEmpty }

  func signInWithPassword() async {
    guard passwordSignInReady else { return }
    busy = true
    defer { busy = false }
    do {
      let outcome = try await account.signInWithPassword(email: email, password: password)
      password = ""
      failure = nil
      onOutcome(outcome)
    } catch {
      failure = error
      password = ""
    }
  }

  // MARK: Forgot password (C9 side N)

  func startReset() {
    resetEmail = email
    resetCodeText = ""
    reset = nil
    failure = nil
  }

  func submitResetEmail() async -> Bool {
    busy = true
    defer { busy = false }
    do {
      reset = try await account.beginPasswordReset(email: resetEmail)
      failure = nil
      return true
    } catch {
      failure = error
      return false
    }
  }

  func submitResetCode() async -> Bool {
    guard let reset, resetCodeText.count == 6 else { return false }
    busy = true
    defer { busy = false }
    do {
      self.reset = try await account.verifyPasswordReset(reset, code: resetCodeText)
      failure = nil
      return true
    } catch {
      failure = error
      resetCodeText = ""
      return false
    }
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
      failure = nil
      return true
    } catch {
      failure = error
      return false
    }
  }

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
          failure = nil
          // Signed in, data still locked here (Paper "Signed in, data still locked").
          onOutcome(.needsUnlock(passkeyCanUnlock: false))
          return
        }
      } catch {
        failure = error
        return
      }
      if ContinuousClock.now - start > limit {
        failure = .approvalExpired
        return
      }
      try? await Task.sleep(for: interval)
    }
  }

  // MARK: Recovery (C4): the words first, then the code

  func submitRecoveryWords() async -> Bool {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      failure = f
      return false
    case .success(let words):
      busy = true
      defer { busy = false }
      do {
        recovery = try await account.beginRecovery(words: words)
        failure = nil
        return true
      } catch {
        failure = error
        return false
      }
    }
  }

  func submitRecoveryCode() async -> Bool {
    guard let recovery, recoverCode.count == 6 else { return false }
    busy = true
    defer { busy = false }
    do {
      try await account.verifyRecovery(recovery, code: recoverCode)
      failure = nil
      return true
    } catch {
      failure = error
      recoverCode = ""
      return false
    }
  }

  func finishRecovery(_ credential: NewCredential) async -> Bool {
    guard let recovery else { return false }
    busy = true
    defer { busy = false }
    do {
      try await account.finishRecovery(recovery, credential: credential)
      phraseText = ""
      newPassword = ""
      confirmPassword = ""
      failure = nil
      return true
    } catch {
      failure = error
      return false
    }
  }

  /// "Open Hasala" after "You're back in": the phrase opened the keys already.
  func recoveryDone() {
    onOutcome(.ready)
  }
}
