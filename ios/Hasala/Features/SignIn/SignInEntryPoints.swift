import SwiftUI

// The sign-in, forgot-password and recovery screens' entry points (plan B7.3): each is
// `init(store: OnboardingStore)`, with the store's `signIn` model and the signed-out
// path (`store.signup.path`) for its navigation. The initializers are frozen; the bodies
// are the screens'. Back is the system's (decision 7): the stack pops itself.

extension SignInView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, capabilities: store.session().capabilities,
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

/// Forgot password · 2 of 4 · "Check your email" (Paper G2U).
struct ForgotCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeStepScreen(
      title: "Check your email",
      subtitle: "We sent a reset code to \(signIn.resetEmail). It works for 10 minutes.",
      steps: (2, 4), code: Bindable(signIn).resetCodeText, busy: signIn.busy,
      failure: signIn.failure(on: .forgotCode), sentAt: signIn.resetCodeSentAt,
      trailing: (title: "Change email", identifier: "code.changeEmail", action: { store.signup.back() }),
      onSubmit: { Task { if await signIn.submitResetCode() { store.signup.go(.forgotCheck) } } },
      onResend: { Task { _ = await signIn.submitResetEmail() } })
      .onChange(of: signIn.resetCodeText) { _, _ in signIn.resetCodeEdited() }
  }
}

extension ForgotCheckView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, onApprove: { store.signup.go(.forgotNewPassword) },
      onWords: { store.signup.go(.recoverWords) }, onNeither: { store.signup.go(.honestEnd) })
  }
}

extension ForgotNewPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onCancel: { store.signup.path = [.signIn] }) { store.signup.go(.forgotWaiting) }
  }
}

extension ForgotWaitingView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn) { store.signup.go(.recoverWords) }
  }
}

extension RecoverIntroView {
  init(store: OnboardingStore) {
    self.init(onStart: { store.signup.go(.recoverWords) }, onNoWords: { store.signup.go(.honestEnd) })
  }
}

extension RecoverWordsView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn) { store.signup.go(.recoverCode) }
  }
}

/// Recover account · the emailed code (Paper G5E). The service takes the words first, so
/// this is step 2 of 3 here; the code is checked with the new way to sign in.
struct RecoverCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeStepScreen(
      title: "Now, your email",
      subtitle: "We sent a code to \(signIn.recovery?.emailHint ?? "your account's address"). Email alone won't get you in; with your 12 words, it does.",
      steps: (2, 3), code: Bindable(signIn).recoverCode, busy: signIn.busy,
      failure: signIn.failure(on: .recoverCode), sentAt: signIn.recoverCodeSentAt,
      trailing: (title: "Change words", identifier: "code.changeWords", action: { store.signup.back() }),
      onSubmit: { if signIn.submitRecoveryCode() { store.signup.go(.recoverMethod) } },
      onResend: { Task { _ = await signIn.submitRecoveryWords() } })
  }
}

extension RecoverMethodView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onPassword: { store.signup.go(.recoverPassword) },
              onResult: { store.recoveryResult($0) })
  }
}

extension RecoverPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onResult: { store.recoveryResult($0) })
  }
}

/// "Without your recovery phrase, we can't open your data" (Paper H9F), signed out.
struct HonestEndView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    HonestEndScreen(context: .signedOut) {
      // "I found my words": the recovery's entry, in place of this page.
      if store.signup.path.last == .honestEnd { store.signup.path.removeLast() }
      store.signup.go(.recoverWords)
    }
  }
}

extension OnboardingStore {
  /// After `recover/verify` + `recover/finish`: "You're back in" shows in place (the model's
  /// `recovered`); a refused code goes back to the code page, which says why.
  func recoveryResult(_ r: SignInModel.RecoveryResult) {
    switch r {
    case .done, .failed: break
    case .codeRejected:
      if let i = signup.path.lastIndex(of: .recoverCode) { signup.path.removeSubrange((i + 1)...) }
    }
  }
}
