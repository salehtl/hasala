import SwiftUI

// The sign-in, forgot-password and recovery screens' entry points (plan B7.3): each is
// `init(store: OnboardingStore)`, with the store's `signIn` model and the signed-out
// path (`store.signup.path`) for its navigation. The initializers are frozen; the bodies
// are the screens'.

extension SignInView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, capabilities: store.session().capabilities, onBack: { store.signup.back() },
      onForgot: {
        store.signIn.startReset()
        store.signup.go(.forgotEmail)
      },
      onRecover: { store.signup.go(.recoverIntro) },
      onJoin: { store.signup.path = [.welcome, .invite] })
  }
}

extension ForgotEmailView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }) { store.signup.go(.forgotCode) }
  }
}

/// "Check your email" in a password reset (Paper G2U-0).
///
/// The foundation's version (plan B7.3): today's code screen over sign-in's model.
struct ForgotCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeEntryView(
      email: signIn.resetEmail, steps: (2, 4), code: Bindable(signIn).resetCodeText, busy: signIn.busy,
      failure: signIn.failure, sentAt: signIn.resetCodeSentAt, onBack: { store.signup.back() },
      onSubmit: { Task { if await signIn.submitResetCode() { store.signup.go(.forgotCheck) } } },
      onResend: { Task { _ = await signIn.submitResetEmail() } },
      onChangeEmail: { store.signup.back() })
  }
}

extension ForgotCheckView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, onBack: { store.signup.back() }, onApprove: { store.signup.go(.forgotNewPassword) },
      onWords: { store.signup.go(.recoverWords) }, onNeither: { store.signup.go(.honestEnd) })
  }
}

extension ForgotNewPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }) { store.signup.go(.forgotWaiting) }
  }
}

extension ForgotWaitingView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }) { store.signup.go(.recoverWords) }
  }
}

extension RecoverIntroView {
  init(store: OnboardingStore) {
    self.init(
      onBack: { store.signup.back() }, onStart: { store.signup.go(.recoverWords) },
      onNoWords: { store.signup.go(.honestEnd) })
  }
}

extension RecoverWordsView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }) { store.signup.go(.recoverCode) }
  }
}

/// The emailed code in access recovery (Paper G5E-0).
///
/// The foundation's version (plan B7.3): today's code screen over sign-in's model.
struct RecoverCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeEntryView(
      email: signIn.recovery?.emailHint ?? "your email", steps: (2, 3), code: Bindable(signIn).recoverCode,
      busy: signIn.busy, failure: signIn.failure, sentAt: signIn.recoverCodeSentAt, onBack: { store.signup.back() },
      onSubmit: { if signIn.submitRecoveryCode() { store.signup.go(.recoverMethod) } },
      onResend: { Task { _ = await signIn.submitRecoveryWords() } })
  }
}

extension RecoverMethodView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, onBack: { store.signup.back() }, onPassword: { store.signup.go(.recoverPassword) },
      onResult: { store.recoveryResult($0) })
  }
}

extension RecoverPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }, onResult: { store.recoveryResult($0) })
  }
}

extension HonestEndView {
  init(store: OnboardingStore) {
    self.init(onBack: { store.signup.back() })
  }
}

extension OnboardingStore {
  /// After `recover/verify` + `recover/finish`: in, or back to the code when it was refused.
  func recoveryResult(_ r: SignInModel.RecoveryResult) {
    switch r {
    case .done: signIn.recoveryDone()
    case .codeRejected:
      if let i = signup.path.lastIndex(of: .recoverCode) { signup.path.removeSubrange((i + 1)...) }
    case .failed: break
    }
  }
}
