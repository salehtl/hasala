#if HASALA_MOCKS
  import Foundation

  // The welcome stories, join, the recovery phrase and the interrupted signup (P1).
  extension ScreenLaunch {
    static let joinScreens: [Screen] = [
      Screen("welcome.story1", scenario: "newUser"),
      Screen("welcome.story2", scenario: "newUser", prepare: { $0.onboarding.storyPage = 1 }),
      Screen("welcome.story3", scenario: "newUser", prepare: { $0.onboarding.storyPage = 2 }),
      Screen("welcome.story4", scenario: "newUser", prepare: { $0.onboarding.storyPage = 3 }),
      // Story 3's link, as the person taps it.
      Screen("welcome.whoSees", scenario: "newUser", prepare: { graph in
        graph.onboarding.storyPage = 2
        graph.onboarding.signup.whoCanSeeOpen = true
      }),
      Screen("join.welcome", scenario: "newUser", prepare: { $0.onboarding.signup.path = [.welcome] }),
      // The code pasted from the invite email (Paper E47-0 "pasted").
      Screen("join.invite", scenario: "newUser") { graph in
        let signup = graph.onboarding.signup
        signup.path = [.welcome, .invite]
        signup.paste(InviteCode.group(inviteCode))
      },
      Screen("join.inviteNotFound", scenario: "newUser") { await signUp($0, to: .verifyEmail, invite: "ZZZZ") },
      Screen("join.inviteReady", scenario: "newUser", prepare: { $0.session.pendingInvite = inviteLink }),
      Screen("join.aboutTyped", scenario: "newUser") { await signUp($0, to: .aboutYou) },
      // The link confirmed the address: Continue went straight to the method, and Back shows
      // About you with the "Confirmed" chip (Paper E7J-0).
      Screen("join.aboutLink", scenario: "newUser") { graph in
        let signup = graph.onboarding.signup
        if let inviteLink { signup.applyInviteLink(inviteLink) }
        signup.path = [.welcome, .inviteReady]
        signup.submitInvite()
        signup.displayName = "Maya Rahman"
        signup.email = "maya@example.com"
        await signup.submitAboutYou()
        signup.back()
      },
      // Three digits typed (Paper EDW-0).
      Screen("join.code", scenario: "newUser") { graph in
        await signUp(graph, to: .verifyEmail)
        graph.onboarding.signup.code = "482"
      },
      Screen("join.codeWrong", scenario: "newUser") { graph in
        await signUp(graph, to: .verifyEmail)
        graph.onboarding.signup.code = "482931"
        await graph.onboarding.signup.submitCode()
      },
      Screen("join.codeExpired", scenario: "newUser") { graph in
        // Five wrong codes use the code up.
        await signUp(graph, to: .verifyEmail)
        for _ in 0..<5 {
          graph.onboarding.signup.code = "000000"
          await graph.onboarding.signup.submitCode()
        }
      },
      Screen("join.method", scenario: "newUser") { await signUp($0, to: .method) },
      Screen("join.passwordShort", scenario: "newUser") { graph in
        await signUp(graph, to: .password)
        // Eight characters, none of them the name or the address (Paper EQ6-0).
        graph.onboarding.signup.newPassword = "lantern4"
      },
      Screen("join.passwordStrong", scenario: "newUser") { graph in
        await signUp(graph, to: .password)
        graph.onboarding.signup.newPassword = "copper lantern quietly 42"
        graph.onboarding.signup.confirmPassword = "copper lantern quietly 42"
        // Shown in clear, as Paper EZU-0 draws it (the person tapped "Show").
        graph.onboarding.signup.passwordShown = true
      },
      Screen("phrase.why", scenario: "newUser") { await signUp($0, to: .phraseIntro) },
      Screen("phrase.hidden", scenario: "newUser") { await signUp($0, to: .phraseShow) },
      Screen("phrase.revealed", scenario: "newUser") { graph in
        await signUp(graph, to: .phraseShow)
        graph.onboarding.signup.phraseRevealed = true
      },
      Screen("phrase.saved", scenario: "newUser") { await signUp($0, to: .accountReady) },
      Screen("resume.interrupted", scenario: "relaunchInterrupted"),
    ]

    /// The synthetic invite code every join screen uses.
    static let inviteCode = "ABCDEFGHIJKLMNOPQRSTUVWX"

    /// A synthetic invite link with a link key, as the invite email opens the app.
    static let inviteLink: InviteLink? = InviteLink.parse(
      URL(string: "https://hasala.app/i/\(inviteCode)#" + String(repeating: "k", count: 43))!)

    enum JoinStop: Int, Comparable {
      case aboutYou, verifyEmail, method, password, phraseIntro, phraseShow, accountReady
      static func < (a: JoinStop, b: JoinStop) -> Bool { a.rawValue < b.rawValue }
    }

    /// Signs up as a person does (typed invite, About you, the emailed code, then a passkey,
    /// or a password for `.password`), stopping on `stop`.
    static func signUp(_ graph: MockGraph, to stop: JoinStop, invite prefix: String = "") async {
      let signup = graph.onboarding.signup
      signup.path = [.welcome, .invite]
      signup.inviteText = prefix + String(inviteCode.dropFirst(prefix.count))
      signup.submitInvite()
      signup.displayName = "Maya Rahman"
      signup.email = "maya@example.com"
      guard stop > .aboutYou else { return }
      await signup.submitAboutYou()
      guard stop > .verifyEmail else { return }
      signup.code = MockAccountService.emailCode
      await signup.submitCode()
      guard stop > .method else { return }
      if stop == .password {
        signup.method = .password
        await signup.continueWithMethod()
        return
      }
      signup.method = .passkey
      await signup.continueWithMethod()
      guard stop > .phraseIntro else { return }
      signup.go(.phraseShow)
      guard stop > .phraseShow else { return }
      signup.phraseRevealed = true
      await signup.finish()
    }
  }
#endif
