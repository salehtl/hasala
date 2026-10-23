#if HASALA_MOCKS
  import Foundation

  // The profile sheet, Bills and Accounts (P8).
  extension ScreenLaunch {
    static let profileScreens: [Screen] = [
      // Your profile (5DE-0, HI3-0): a passkey account, bank alerts working.
      Screen("profile", scenario: "passkeyUser", prepare: profile([])),
      // The card when mail needs a new sign-in, and Sign-in & security on a password only.
      Screen("profile.signInAgain", scenario: "gmailReconnect", prepare: profile([])),
      Screen("profile.passwordOnly", scenario: "passwordOnly", prepare: profile([])),
      Screen("profile.hidden", scenario: "mayaHidden", prepare: profile([])),
      // Categories and rules (68S-0).
      Screen("profile.rules", scenario: "maya", prepare: profile([.rules])),
      // A rule learned today: Lulu's card sorted into Groceries with "Always use", as the
      // review deck files it, then the rules (68S-0's "Learned today" chip).
      Screen("profile.rulesLearned", scenario: "maya", drive: { graph in
        graph.app.perform(.categorize("lulu", "groceries", learnRule: true, project: nil))
      }, prepare: profile([.rules])),
      Screen("profile.categoryNew", scenario: "maya", prepare: profile([.rules, .categoryEditor(nil)])),
      Screen("profile.categoryEdit", scenario: "maya", prepare: profile([.rules, .categoryEditor("dining")])),
      Screen("profile.categoryCustom", scenario: "maya", prepare: profile([.rules, .categoryEditor("emergency-fund")])),
      // Delete your account (69M-0; Sign-in & security's view).
      Screen("profile.delete", scenario: "passkeyUser", prepare: profile([.deleteAccount])),
      Screen("profile.help", scenario: "maya", prepare: profile([.help])),
      Screen("profile.bills", scenario: "maya", prepare: profile([.bills])),
      Screen("profile.accounts", scenario: "maya", prepare: profile([.accounts])),
      Screen("profile.cloudSort", scenario: "maya", prepare: cloudSort(.done, then: profile([]))),
      // Bills · Coming up and found (1K9-0), pushed from Home.
      Screen("bills", scenario: "maya", prepare: shell(.home, home: [.bills])),
      // Bills · AXA Insurance (late) (1UD-0), and the other states one bill can be in.
      Screen("bills.axa", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("axa")])),
      Screen("bills.du", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("du")])),
      Screen("bills.dewa", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("dewa")])),
      // Accounts · Net worth (1W6-0), pushed from Home.
      Screen("accounts", scenario: "maya", prepare: shell(.home, home: [.accounts])),
    ]
  }
#endif
