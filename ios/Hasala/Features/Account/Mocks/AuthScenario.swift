#if HASALA_MOCKS
  import Foundation
  import HasalaModels

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
    /// Signed in after skipping the email step: no mailbox, and Profile offers to connect
    /// one (the same as `noMailbox`).
    case gmailSkipped
    /// Signed in; Google ended Hasala's access: Gmail needs a new sign-in.
    case gmailReconnect
    /// Setup at the email step (step 2): the account exists and its banks are chosen.
    case setupEmail
    /// Signed in, reading Gmail and Outlook.
    case mailboxes2
    /// Signed in; Microsoft ended Hasala's access to Outlook, Gmail still works.
    case outlookSignIn
    /// Setup at the email step; an Outlook connect is a work account its admin hasn't
    /// approved.
    case outlookAdmin
    /// Setup at the email step; the Microsoft sign-in is closed or its permissions declined.
    case outlookCancelled
    /// Signed in with no mailbox.
    case noMailbox
    /// Signed in; Microsoft ended Hasala's access to Outlook, the account's one mailbox.
    case outlookReconnect
    /// Signed in, reading Gmail only (the same as `passkeyUser`): a switch to Outlook
    /// replaces it.
    case gmailLinked
    /// Signed in after skipping setup's bank step (manual entry): no bank and no mailbox,
    /// so a connect from the profile asks for the banks first.
    case noBanks
    case finishSetup
    case noAlerts
    case setupTexts
    case textsWorking
    case textsWaiting
    case gmailTexts

    static func fromLaunchArguments(_ arguments: [String]) -> AuthScenario? {
      guard let i = arguments.firstIndex(of: "-HasalaScenario"), i + 1 < arguments.count else { return nil }
      return AuthScenario(rawValue: arguments[i + 1])
    }

    /// The session for `scenario`; nil means the Maya scenarios (signed in, ready).
    ///
    /// The mock offers every account action, except on the Release surface
    /// (`BuildSurface`), where it offers the beta's, as the live service does (and its
    /// first scan, like the live lane's, sorts nothing with the on-device model). There the
    /// mailbox mock is narrowed to the live lane too: Gmail and Outlook (personal Microsoft
    /// accounts), as the build's client ids offer them, and one mailbox, which a connect of
    /// the other provider replaces after a confirmation. `releaseSurface` is the build's
    /// (tests pass it, so they check the narrowing the app runs).
    @MainActor
    static func session(
      for scenario: AuthScenario?, releaseSurface: Bool = !BuildSurface.showsUnfinished
    ) -> AccountSession {
      let session = makeSession(for: scenario, releaseSurface: releaseSurface)
      if releaseSurface {
        if let mock = session.account as? MockAccountService { mock.capabilities = .beta }
        if let mailbox = session.services.mailbox as? MockMailbox { mailbox.holdOneLink() }
      }
      return session
    }

    /// Where setup resumes: the email-step scenarios have chosen their banks.
    static func setupFacts(for scenario: AuthScenario?, texts: (any BankTextsConnecting)? = nil) -> OnboardingStep.Facts {
      var facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
      facts.textsChosen = BankTexts.setUpHere(texts)
      switch scenario {
      case .setupEmail, .outlookAdmin, .outlookCancelled: facts.banksChosen = true
      default: break
      }
      return facts
    }

    /// The mailboxes a signed-in scenario starts with (setup's start with none).
    static func mailboxes(for scenario: AuthScenario?) -> [MailboxSnapshot] {
      switch scenario {
      case nil, .passkeyUser, .passwordOnly, .mayaSample, .resetApproval, .frozen, .frozenOperator,
        .unlockPasswordOnly, .unlockWithPasskey, .relaunchSignedIn, .gmailLinked:
        [MockMailbox.gmail]
      case .outlookReconnect: [MockMailbox.needingSignIn(MockMailbox.outlook)]
      case .gmailReconnect: [MockMailbox.needingSignIn(MockMailbox.gmail)]
      case .mailboxes2: [MockMailbox.gmail, MockMailbox.outlook]
      case .outlookSignIn: [MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)]
      case .finishSetup, .noAlerts, .gmailTexts: [MockMailbox.gmail]
      case .gmailSkipped, .noMailbox, .noBanks, .newUser, .noPasscode, .signInPassword, .setupBank, .reviewAccount,
        .setupEmail, .outlookAdmin, .outlookCancelled, .relaunchInterrupted, .setupTexts, .textsWorking, .textsWaiting:
        []
      }
    }

    static func startsWithoutPlan(_ scenario: AuthScenario?) -> Bool {
      switch scenario {
      case .newUser, .noPasscode, .setupBank, .reviewAccount, .setupEmail, .outlookAdmin, .outlookCancelled,
        .relaunchInterrupted, .finishSetup, .noAlerts, .setupTexts:
        true
      default:
        false
      }
    }

    @MainActor
    static func bankTexts(for scenario: AuthScenario?, mailbox: MockMailbox? = nil) -> MockBankTexts? {
      guard BuildSurface.showsBankTexts else { return nil }
      let lane: MockBankTexts? =
        switch scenario {
        case .setupTexts: MockBankTexts(mailbox: mailbox)
        case .gmailTexts: MockBankTexts(mailbox: mailbox)
        case .textsWorking: MockBankTexts.working(mailbox: mailbox)
        case .textsWaiting: MockBankTexts.waiting(mailbox: mailbox)
        default: nil
        }
      let arguments = ProcessInfo.processInfo.arguments
      if let i = arguments.firstIndex(of: "-HasalaLockedTexts"), i + 1 < arguments.count, let n = Int(arguments[i + 1]) {
        lane?.lockedNotice = n
      }
      return lane
    }

    @MainActor
    private static func makeSession(for scenario: AuthScenario?, releaseSurface: Bool) -> AccountSession {
      let mailbox = MockMailbox(offersSampleData: scenario == .reviewAccount, mailboxes: mailboxes(for: scenario))
      mailbox.sortsWithModel = !releaseSurface
      mailbox.outlookAdmin = scenario == .outlookAdmin
      mailbox.outlookCancelled = scenario == .outlookCancelled
      if scenario == .noBanks { mailbox.banks = [] }
      if scenario == .noAlerts { mailbox.total = 0 }
      let fresh = startsWithoutPlan(scenario)
      let setup = MockSetupAuthoring(
        saved: fresh ? SetupReadBack() : SetupReadBack(incomeMinor: 25_000_00, payday: 28, split: StartingPlan()))
      // The bank ops are what the lane reads, as live's sender trust is.
      setup.choseBanks = { [weak mailbox] in mailbox?.banks = $0 }
      let cloudSort = MockCloudSort()
      let arguments = ProcessInfo.processInfo.arguments
      let unseenPhrase = InMemoryUnseenPhrase()
      if arguments.contains("-HasalaPhraseUnseen") { unseenPhrase.noteUnseen(at: .now) }
      let manualEntry = ManualEntryChoice()
      let bankTexts = bankTexts(for: scenario, mailbox: mailbox)
      func services(_ account: MockAccountService) -> AccountServices {
        account.passkeyPRF = !arguments.contains("-HasalaPasskeyNoPRF")
        account.passkeySynced = !arguments.contains("-HasalaPasskeyNotSynced")
        return AccountServices(
          account: account, mailbox: mailbox, setup: setup,
          notifications: MockNotificationPermission(answered: !fresh), hasPasscode: { scenario != .noPasscode },
          cloudSort: cloudSort, unseenPhrase: unseenPhrase, manualEntry: manualEntry, bankTexts: bankTexts)
      }
      switch scenario {
      case nil, .passkeyUser, .gmailSkipped, .gmailReconnect, .mailboxes2, .outlookSignIn, .noMailbox, .noBanks,
        .outlookReconnect, .gmailLinked, .finishSetup, .noAlerts, .textsWorking, .textsWaiting, .gmailTexts:
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
      case .setupBank, .reviewAccount, .setupTexts:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .onboarding(.bank))
      case .setupEmail, .outlookAdmin, .outlookCancelled:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .onboarding(.mail))
      }
    }
  }
#endif
