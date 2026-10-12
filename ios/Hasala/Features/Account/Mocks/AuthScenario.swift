#if HASALA_MOCKS
  import Foundation

  /// The page-14 and setup scenarios of spec 04 §15.3, read from the same
  /// `-HasalaScenario <name>` argument as the Maya scenarios. Unknown names (including
  /// `maya` and `mayaHidden`) start signed in with a passkey account, so the existing
  /// Home scenarios run unchanged.
  enum AuthScenario: String, CaseIterable {
    /// Signed out: the welcome stories, then page 14's signup and row 10's setup.
    case newUser
    /// Signed in with a passkey account (Sign-in & security, passkey board).
    case passkeyUser
    /// Signed in with a password-only account (Sign-in & security, password-only board).
    case passwordOnly
    /// Signed out, with an existing password-only account to sign in to.
    case signInPassword
    /// Signed in, data sealed: 12 words only.
    case unlockPasswordOnly
    /// Signed in, data sealed: passkey or 12 words.
    case unlockWithPasskey
    /// "Your account is frozen" (holder's freeze).
    case frozen
    /// An operator freeze: no "Unfreeze".
    case frozenOperator
    /// Setup at the bank step, a normal account.
    case setupBank
    /// Setup at the bank step on a review account ("Use sample data").
    case reviewAccount
    /// Signed out on an iPhone without a passcode (S-24).
    case noPasscode
    /// Signed in; another iPhone asks this one to approve a password reset.
    case resetApproval
    /// Relaunch after C1 was killed before its bootstrap: a new phrase, then Face ID.
    case relaunchInterrupted
    /// Relaunch after a new-iPhone sign-in was killed before unlock.
    case relaunchSignedIn
    /// Signed in on the App Review demo account (`review_account`), over HasalaMocks'
    /// `mayaSample` ledger: Home says "Sample data".
    case mayaSample
    /// Signed in after skipping the Gmail step: Home and Profile offer "Connect Gmail".
    case gmailSkipped
    /// Signed in; Google wants a new sign-in: Home and Profile offer "Reconnect Gmail".
    case gmailReconnect

    static func fromLaunchArguments(_ arguments: [String]) -> AuthScenario? {
      guard let i = arguments.firstIndex(of: "-HasalaScenario"), i + 1 < arguments.count else { return nil }
      return AuthScenario(rawValue: arguments[i + 1])
    }

    /// The session for `scenario`; nil means the Maya scenarios (signed in, ready).
    ///
    /// The mock offers every account action, except on the Release surface
    /// (`BuildSurface`), where it offers the beta's, as the live service does (and its
    /// first scan, like the live lane's, sorts nothing with the on-device model).
    @MainActor
    static func session(for scenario: AuthScenario?) -> AccountSession {
      let session = makeSession(for: scenario)
      if let mock = session.account as? MockAccountService, !BuildSurface.showsUnfinished {
        mock.capabilities = .beta
      }
      return session
    }

    @MainActor
    private static func makeSession(for scenario: AuthScenario?) -> AccountSession {
      let mailbox = MockMailbox(offersSampleData: scenario == .reviewAccount)
      mailbox.sortsWithModel = BuildSurface.showsUnfinished
      mailbox.gmailOffer = scenario == .gmailSkipped ? .connect : scenario == .gmailReconnect ? .reconnect : nil
      func services(_ account: MockAccountService) -> AccountServices {
        AccountServices(account: account, mailbox: mailbox, setup: MockSetupAuthoring(),
                        notifications: MockNotificationPermission(), hasPasscode: { scenario != .noPasscode })
      }
      switch scenario {
      case nil, .passkeyUser, .gmailSkipped, .gmailReconnect:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)), phase: .ready)
      case .mayaSample:
        let session = AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                                     phase: .ready)
        session.reviewAccount = true
        return session
      case .resetApproval:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        account.pendingReset = PendingReset(id: "reset-1", askedAgo: "1 minute ago", email: MockAccountService.existingEmail)
        return AccountSession(services: services(account), phase: .ready)
      case .passwordOnly:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly, signedIn: true)),
                              phase: .ready)
      case .newUser, .noPasscode:
        return AccountSession(services: services(MockAccountService(existing: .none)), phase: .signedOut)
      case .signInPassword:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly)), phase: .signedOut)
      case .unlockPasswordOnly:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly, signedIn: true)),
                              phase: .needsUnlock(passkeyCanUnlock: false))
      case .unlockWithPasskey:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .needsUnlock(passkeyCanUnlock: true))
      case .frozen, .frozenOperator:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        let by: FreezeInfo.By = scenario == .frozen ? .holder : .operator
        account.freezeForScenario(by: by)
        return AccountSession(services: services(account),
                              phase: .frozen(FreezeInfo(by: by, when: "on Sun 11 Oct at 21:20")))
      case .relaunchInterrupted, .relaunchSignedIn:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        account.resumeOutcome = scenario == .relaunchInterrupted ? .needsKeys : .needsUnlock(passkeyCanUnlock: true)
        return AccountSession(services: services(account), phase: .checking)
      case .setupBank, .reviewAccount:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .onboarding(.bank))
      }
    }
  }
#endif
