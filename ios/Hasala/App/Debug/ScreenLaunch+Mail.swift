#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  // Your email in setup, and Profile › Bank alerts (P3). The setup ids open setup's own
  // email step (P2 hosts the mailbox views there); the `mail.add.*` ids are the same screens
  // in the profile, from Bank alerts › Add a mailbox.
  extension ScreenLaunch {
    static let mailScreens: [Screen] = [
      Screen("mail.connectGmail", scenario: "setupEmail") { _ = setupModel($0) },
      Screen("mail.connectOutlook", scenario: "setupEmail") { graph in
        setupModel(graph).pickProvider(.outlook)
      },
      Screen("mail.permissionMissing", scenario: "setupEmail") { graph in
        mock(graph)?.gmailPermissionMissing = true
        await setupModel(graph).connectMail(.gmail)
      },
      Screen("mail.errorAdmin", scenario: "outlookAdmin") { await setupOutlookFails($0) },
      Screen("mail.errorCancelled", scenario: "outlookCancelled") { await setupOutlookFails($0) },
      // An App Review account: "Use sample data" leads, the provider's sign-in follows.
      Screen("mail.connectGmail.review", scenario: "reviewAccount") { _ = setupModel($0) },
      // The profile.
      Screen("bankAlerts", scenario: "mailboxes2", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.oneGmail", scenario: "passkeyUser", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts", scenario: "textsWorking", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts.waiting", scenario: "textsWaiting", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts.paste", scenario: "textsWorking", prepare: { graph in
        BankTextsLaunch.pasted = MockBankTexts.sampleText
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.emailOrTexts", scenario: "gmailTexts", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.emailIgnored", scenario: "gmailTexts", prepare: { graph in
        bankTexts(graph)?.ignoredLast30Days = 3
        profile([.bankAlerts])(graph)
      }),
      Screen("mail.disconnectTexts", scenario: "gmailTexts", prepare: { graph in
        bankTexts(graph)?.ignoredLast30Days = 3
        MailLaunch.disconnectAlert = "gmail-1"
        profile([.bankAlerts, .mailbox("gmail-1")])(graph)
      }),
      Screen("bankAlerts.none", scenario: "noMailbox", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.refused", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.connectRefusal = .sampleData
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.refusedReview", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.connectRefusal = .reviewAccount
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.syncing", scenario: "passkeyUser", prepare: { graph in
        // Add a mailbox › Outlook › Continue with Microsoft: back on Bank alerts with the
        // toast while the new mailbox still syncs (its first scan slowed to stay in view).
        mock(graph)?.step = .seconds(2)
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("bankAlerts.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.signInNoMailbox", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.outlookNoMailbox = true
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.signInOtherAddress", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.signInAgainReads = "maya.other@example.com"
        profile([.bankAlerts])(graph)
      }),
      Screen("mail.detailSignInOtherAddress", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.signInAgainReads = "maya.other@example.com"
        profile([.bankAlerts, .mailbox("outlook-1")])(graph)
      }),
      Screen("mail.add", scenario: "passkeyUser", prepare: profile([.bankAlerts, .addMailbox])),
      // Outlook needs a new sign-in: its row says so, and leads to its sign-in again.
      Screen("mail.add.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .addMailbox])),
      Screen("mail.add.gmail", scenario: "noMailbox", prepare: profile([.bankAlerts, .addMailbox, .connectMail(.gmail)])),
      // The Profile card's "Connect your email": Gmail's screen straight away, with
      // "Not your email? Choose a different one." (no providers behind it).
      Screen("mail.profile.gmail", scenario: "noMailbox", prepare: profile([.connectMail(.gmail)])),
      Screen("mail.add.outlook", scenario: "passkeyUser",
             prepare: profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])),
      Screen("mail.add.errorAdmin", scenario: "passkeyUser", prepare: { graph in
        // A work account its admin hasn't approved.
        mock(graph)?.outlookAdmin = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorCancelled", scenario: "passkeyUser", prepare: { graph in
        // Microsoft's sign-in closed, or its permissions declined.
        mock(graph)?.outlookCancelled = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorNoMailbox", scenario: "passkeyUser", prepare: { graph in
        mock(graph)?.outlookNoMailbox = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorNoMailboxGmail", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.gmailNoMailbox = true
        MailLaunch.connectOnAppear = .gmail
        profile([.bankAlerts, .addMailbox, .connectMail(.gmail)])(graph)
      }),
      Screen("mail.detail", scenario: "mailboxes2", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.detailSignIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.disconnect", scenario: "mailboxes2", prepare: { graph in
        MailLaunch.disconnectAlert = "outlook-1"
        profile([.bankAlerts, .mailbox("outlook-1")])(graph)
      }),
      Screen("mail.disconnectGmail", scenario: "passkeyUser", prepare: { graph in
        MailLaunch.disconnectAlert = "gmail-1"
        profile([.bankAlerts, .mailbox("gmail-1")])(graph)
      }),
      Screen("mail.disconnected", scenario: "mailboxes2", drive: { graph in
        // Disconnected: the grey row stays (past transactions stay).
        try? await mock(graph)?.disconnect("outlook-1")
      }, prepare: profile([.bankAlerts])),
    ]

    /// The scenario's mail lane.
    static func mock(_ graph: MockGraph) -> MockMailbox? {
      graph.session.services.mailbox as? MockMailbox
    }

    /// Setup's email step with Outlook picked, then "Continue with Microsoft", which the
    /// scenario makes fail (an admin's approval, a sign-in that didn't finish).
    static func setupOutlookFails(_ graph: MockGraph) async {
      let model = setupModel(graph)
      model.pickProvider(.outlook)
      await model.connectMail(.outlook)
    }
  }

  /// The taps a mailbox screen id stands in for, taken once by the screen that does them:
  /// "Continue with <provider>" on a connect screen, "Disconnect this mailbox" on a mailbox.
  @MainActor
  enum MailLaunch {
    static var connectOnAppear: MailProviderKind?
    static var disconnectAlert: String?

    static func takeConnect(_ provider: MailProviderKind) -> Bool {
      guard connectOnAppear == provider else { return false }
      connectOnAppear = nil
      return true
    }

    static func takeDisconnect(_ mailboxID: String) -> Bool {
      guard disconnectAlert == mailboxID else { return false }
      disconnectAlert = nil
      return true
    }
  }
#endif
