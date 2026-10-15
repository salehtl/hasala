#if HASALA_MOCKS
  import Foundation

  // Sign in, unlock, forgot password, recovery, reset approval, Sign-in & security and
  // freezes (P4).
  extension ScreenLaunch {
    static let signInScreens: [Screen] = [
      Screen("signin", scenario: "signInPassword", prepare: { $0.onboarding.signup.path = [.signIn] }),
      Screen("signin.wrongPassword", scenario: "signInPassword") { graph in
        graph.onboarding.signup.path = [.signIn]
        let signIn = graph.onboarding.signIn
        signIn.email = "maya@example.com"
        signIn.password = "not my password"
        await signIn.signInWithPassword()
      },
      Screen("unlock.words", scenario: "unlockPasswordOnly"),
      Screen("unlock.options", scenario: "unlockWithPasskey"),
      Screen("forgot.email", scenario: "signInPassword", prepare: { graph in
        graph.onboarding.signIn.startReset()
        graph.onboarding.signup.path = [.signIn, .forgotEmail]
      }),
      Screen("forgot.code", scenario: "signInPassword") { graph in
        let signIn = graph.onboarding.signIn
        signIn.startReset()
        graph.onboarding.signup.path = [.signIn, .forgotEmail]
        signIn.resetEmail = "maya@example.com"
        if await signIn.submitResetEmail() { graph.onboarding.signup.go(.forgotCode) }
      },
      Screen("recover.intro", scenario: "signInPassword",
             prepare: { $0.onboarding.signup.path = [.signIn, .recoverIntro] }),
      Screen("recover.words", scenario: "signInPassword",
             prepare: { $0.onboarding.signup.path = [.signIn, .recoverIntro, .recoverWords] }),
      Screen("approval.sheet", scenario: "resetApproval"),
      Screen("security", scenario: "passkeyUser", prepare: profile([.security])),
      Screen("security.passwordOnly", scenario: "passwordOnly", prepare: profile([.security])),
      Screen("frozen", scenario: "frozen"),
    ]
  }
#endif
