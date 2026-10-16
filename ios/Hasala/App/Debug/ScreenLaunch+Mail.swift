#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  // Your email in setup, and Profile › Bank alerts (P3). The setup ids open setup's own
  // email step (P2 hosts the mailbox views there); the `mail.add.*` ids are the same screens
  // in the profile, from Bank alerts › Add a mailbox.
  extension ScreenLaunch {
    static let mailScreens: [Screen] = [
      // Setup, step 2 of 4.
      Screen("mail.connectGmail", scenario: "setupEmail") { _ = setupModel($0) },
      Screen("mail.connectOutlook", scenario: "setupEmail") { graph in
        // Outlook picked in "Choose your email": its read-only screen.
        let model = setupModel(graph)
        model.navigationPath = [.connect(.outlook)]
      },
      Screen("mail.connectedGmail", scenario: "setupEmail") { graph in
        // Connected, then Back from the first scan: the step shows it connected.
        let model = setupModel(graph)
        await model.connectMail(.gmail)
        model.back()
      },
      Screen("mail.errorAdmin", scenario: "outlookAdmin") { await setupOutlookFails($0) },
      Screen("mail.errorCancelled", scenario: "outlookCancelled") { await setupOutlookFails($0) },
      // The profile.
      Screen("bankAlerts", scenario: "mailboxes2", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.oneGmail", scenario: "passkeyUser", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.syncing", scenario: "passkeyUser", prepare: { graph in
        // Add a mailbox › Outlook › Continue with Microsoft: back on Bank alerts with the
        // toast while the new mailbox still syncs (its first scan slowed to stay in view).
        mock(graph)?.step = .seconds(2)
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("bankAlerts.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts])),
      Screen("mail.add", scenario: "passkeyUser", prepare: profile([.bankAlerts, .addMailbox])),
      // Outlook needs a new sign-in: its row says so, and leads to its sign-in again.
      Screen("mail.add.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .addMailbox])),
      Screen("mail.add.gmail", scenario: "noMailbox", prepare: profile([.bankAlerts, .addMailbox, .connectMail(.gmail)])),
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
      Screen("mail.detail", scenario: "mailboxes2", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.detailSignIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.disconnect", scenario: "mailboxes2", prepare: { graph in
        MailLaunch.disconnectAlert = "outlook-1"
        profile([.bankAlerts, .mailbox("outlook-1")])(graph)
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
      model.navigationPath = [.connect(.outlook)]
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
