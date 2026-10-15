#if HASALA_MOCKS
  import Foundation

  // Your email in setup, and Profile › Bank alerts (P3).
  extension ScreenLaunch {
    static let mailScreens: [Screen] = [
      Screen("mail.connectGmail", scenario: "setupEmail") { _ = setupModel($0) },
      Screen("mail.connectedGmail", scenario: "setupEmail") { graph in
        // Connected, then Back from the first scan: the step shows it connected.
        let model = setupModel(graph)
        await model.connectMail(.gmail)
        model.back()
      },
      Screen("mail.connectOutlook", scenario: "passkeyUser",
             prepare: profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])),
      Screen("mail.add", scenario: "passkeyUser", prepare: profile([.bankAlerts, .addMailbox])),
      Screen("mail.detail", scenario: "mailboxes2", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.detailSignIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("bankAlerts", scenario: "mailboxes2", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts])),
    ]
  }
#endif
