import Foundation

/// The signed-out routes, pushed over the welcome stories: join and the recovery phrase
/// (C1, C1-P; Paper P2.1, P2.2), sign-in (C2, C2-P), forgot password (C9 side N) and access
/// recovery (C4). Each screen is `init(store: OnboardingStore)` (plan B7.3). There is no
/// word check after the phrase (`docs/decisions/recovery-phrase-no-quiz.md`).
enum WelcomeRoute: Hashable {
  case invite
  /// "Your invite is ready": an invite link opened the app with the code filled in.
  case inviteReady
  case aboutYou
  case verifyEmail
  case method
  case password
  case phraseIntro
  case phraseShow
  case accountReady
  case signIn
  case forgotEmail
  case forgotCode
  case forgotCheck
  case forgotNewPassword
  case forgotWaiting
  case recoverIntro
  case recoverWords
  case recoverCode
  case recoverMethod
  case recoverPassword
  case honestEnd
}
