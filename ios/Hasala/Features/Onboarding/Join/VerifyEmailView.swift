import SwiftUI

/// "Check your email" in signup (Paper EDW-0, EID-0, EKX-0): the 6-digit code, checked on the
/// sixth digit.
///
/// The foundation's version (plan B7.3): today's code screen over signup's model.
// TODO(plan P1): CodeCells with the wrong and expired states.
struct VerifyEmailView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signup = store.signup
    CodeEntryView(
      email: signup.email, steps: (1, 3), code: Bindable(signup).code, busy: signup.busy, failure: signup.failure,
      sentAt: signup.codeSentAt, onBack: { signup.back() },
      onSubmit: { Task { await signup.submitCode() } },
      onResend: { Task { await signup.resendCode() } },
      onChangeEmail: { signup.back() })
  }
}
