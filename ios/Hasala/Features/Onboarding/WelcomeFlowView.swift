import HasalaDesign
import SwiftUI

/// Everything a signed-out iPhone shows (spec 04 §13.1 BootWalls › signedOut): the stories,
/// join and the recovery phrase, sign-in, forgot password and recovery, on one navigation
/// stack. The models and the path are the onboarding store's (plan B3), so a re-made gate
/// keeps what was typed; each screen is `init(store:)` (plan B7.3) and does its own
/// navigation through `store.signup.path`.
struct WelcomeFlowView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  private var session: AccountSession { store.session() }

  var body: some View {
    NavigationStack(path: Bindable(store.signup).navigationPath) {
      StoriesView(store: store)
        .navigationDestination(for: WelcomeRoute.self) { route in
          destination(route)
        }
    }
    .onAppear(perform: consumeInvite)
    .onChange(of: session.pendingInvite) { _, _ in consumeInvite() }
  }

  /// An invite link opens "Your invite is ready" prefilled, never auto-submitted (§13.5).
  /// What was typed in About you stays.
  private func consumeInvite() {
    guard let link = session.pendingInvite else { return }
    session.pendingInvite = nil
    store.signup.applyInviteLink(link)
    store.signup.path = [.welcome, .inviteReady]
  }

  @ViewBuilder private func destination(_ route: WelcomeRoute) -> some View {
    switch route {
    case .welcome: JoinWelcomeView(store: store)
    case .invite: InviteCodeView(store: store)
    case .inviteReady: InviteReadyView(store: store)
    case .aboutYou: AboutYouView(store: store)
    case .verifyEmail: VerifyEmailView(store: store)
    case .method: SignInMethodView(store: store)
    case .password: CreatePasswordView(store: store)
    case .phraseIntro: PhraseIntroView(store: store)
    case .phraseShow: PhraseShowView(store: store)
    // The account exists from here: no way back.
    case .accountReady: AccountReadyView(store: store).navigationBarBackButtonHidden()
    case .signIn: SignInView(store: store)
    case .forgotEmail: ForgotEmailView(store: store)
    case .forgotCode: ForgotCodeView(store: store)
    case .forgotCheck: ForgotCheckView(store: store)
    case .forgotNewPassword: ForgotNewPasswordView(store: store)
    case .forgotWaiting: ForgotWaitingView(store: store)
    case .recoverIntro: RecoverIntroView(store: store)
    case .recoverWords: RecoverWordsView(store: store)
    case .recoverCode: RecoverCodeView(store: store)
    case .recoverMethod: RecoverMethodView(store: store)
    case .recoverPassword: RecoverPasswordView(store: store)
    case .honestEnd: HonestEndView(store: store)
    }
  }
}
