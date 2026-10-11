import HasalaDesign
import SwiftUI

/// Everything a signed-out iPhone shows (spec 04 §13.1 BootWalls › signedOut): the stories,
/// signup, sign-in, forgot password and recovery, on one navigation stack.
struct WelcomeFlowView: View {
  let session: AccountSession
  @State private var signup: SignupModel
  @State private var signIn: SignInModel

  init(session: AccountSession) {
    self.session = session
    _signup = State(initialValue: SignupModel(account: session.account))
    _signIn = State(initialValue: SignInModel(account: session.account, onOutcome: { [weak session] outcome in
      session?.signedIn(outcome)
    }))
  }

  var body: some View {
    NavigationStack(path: $signup.path) {
      StoriesView(onGetStarted: { signup.go(.welcome) }, onSignIn: { signup.go(.signIn) })
        .navigationDestination(for: WelcomeRoute.self) { route in
          destination(route)
        }
    }
    .onAppear(perform: consumeInvite)
    .onChange(of: session.pendingInvite) { _, _ in consumeInvite() }
  }

  /// An invite link opens the invite screen prefilled, never auto-submitted (§13.5).
  private func consumeInvite() {
    guard let link = session.pendingInvite else { return }
    session.pendingInvite = nil
    signup.applyInviteLink(link)
    signup.path = [.welcome, .invite]
  }

  /// After `recover/verify` + `recover/finish`: in, or back to the code when it was refused.
  private func recoveryResult(_ r: SignInModel.RecoveryResult) {
    switch r {
    case .done: signIn.recoveryDone()
    case .codeRejected:
      if let i = signup.path.lastIndex(of: .recoverCode) { signup.path.removeSubrange((i + 1)...) }
    case .failed: break
    }
  }

  @ViewBuilder private func destination(_ route: WelcomeRoute) -> some View {
    switch route {
    case .welcome:
      WelcomeView(onJoin: { signup.go(.invite) }, onSignIn: { signup.go(.signIn) }, onBack: signup.back)
    case .invite:
      InviteCodeView(model: signup)
    case .aboutYou:
      AboutYouView(model: signup, onSignIn: { signup.path = [.signIn] })
    case .verifyEmail:
      CodeEntryView(
        email: signup.email, steps: (1, 3), code: $signup.code, busy: signup.busy, failure: signup.failure,
        sentAt: signup.codeSentAt, onBack: signup.back,
        onSubmit: { Task { await signup.submitCode() } },
        onResend: { Task { await signup.resendCode() } },
        onChangeEmail: signup.back)
    case .method:
      SignInMethodView(model: signup)
    case .password:
      CreatePasswordView(model: signup)
    case .phraseIntro:
      PhraseIntroView(model: signup)
    case .phraseShow:
      PhraseShowView(revealed: $signup.phraseRevealed, words: signup.phrase?.words ?? [], onBack: signup.back,
                     onContinue: { signup.go(.phraseConfirm) })
    case .phraseConfirm:
      PhraseConfirmView(model: signup)
    case .accountReady:
      AccountReadyView(profile: signup.profile) { session.accountCreated() }
        .navigationBarBackButtonHidden()
    case .signIn:
      SignInView(model: signIn, onBack: signup.back,
                 onForgot: {
                   signIn.startReset()
                   signup.go(.forgotEmail)
                 },
                 onRecover: { signup.go(.recoverIntro) },
                 onJoin: { signup.path = [.welcome, .invite] })
    case .forgotEmail:
      ForgotEmailView(model: signIn, onBack: signup.back) { signup.go(.forgotCode) }
    case .forgotCode:
      CodeEntryView(
        email: signIn.resetEmail, steps: (2, 4), code: $signIn.resetCodeText, busy: signIn.busy,
        failure: signIn.failure, sentAt: signIn.resetCodeSentAt, onBack: signup.back,
        onSubmit: { Task { if await signIn.submitResetCode() { signup.go(.forgotCheck) } } },
        onResend: { Task { _ = await signIn.submitResetEmail() } },
        onChangeEmail: signup.back)
    case .forgotCheck:
      ForgotCheckView(model: signIn, onBack: signup.back,
                      onApprove: { signup.go(.forgotNewPassword) },
                      onWords: { signup.go(.recoverWords) },
                      onNeither: { signup.go(.honestEnd) })
    case .forgotNewPassword:
      ForgotNewPasswordView(model: signIn, onBack: signup.back) { signup.go(.forgotWaiting) }
    case .forgotWaiting:
      ForgotWaitingView(model: signIn, onBack: signup.back) { signup.go(.recoverWords) }
    case .recoverIntro:
      RecoverIntroView(onBack: signup.back, onStart: { signup.go(.recoverWords) },
                       onNoWords: { signup.go(.honestEnd) })
    case .recoverWords:
      RecoverWordsView(model: signIn, onBack: signup.back) { signup.go(.recoverCode) }
    case .recoverCode:
      CodeEntryView(
        email: signIn.recovery?.emailHint ?? "your email", steps: (2, 3), code: $signIn.recoverCode,
        busy: signIn.busy, failure: signIn.failure, sentAt: signIn.recoverCodeSentAt, onBack: signup.back,
        onSubmit: { if signIn.submitRecoveryCode() { signup.go(.recoverMethod) } },
        onResend: { Task { _ = await signIn.submitRecoveryWords() } })
    case .recoverMethod:
      RecoverMethodView(model: signIn, onBack: signup.back, onPassword: { signup.go(.recoverPassword) },
                        onResult: recoveryResult)
    case .recoverPassword:
      RecoverPasswordView(model: signIn, onBack: signup.back, onResult: recoveryResult)
    case .honestEnd:
      HonestEndView(onBack: signup.back)
    }
  }
}
