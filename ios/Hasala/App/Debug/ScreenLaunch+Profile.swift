#if HASALA_MOCKS
  import Foundation

  // The profile sheet, Bills and Accounts (P8).
  extension ScreenLaunch {
    static let profileScreens: [Screen] = [
      Screen("profile", scenario: "passkeyUser", prepare: profile([])),
      Screen("profile.rules", scenario: "maya", prepare: profile([.rules])),
      Screen("profile.delete", scenario: "passkeyUser", prepare: profile([.deleteAccount])),
      Screen("bills", scenario: "maya", prepare: shell(.home, home: [.bills])),
      Screen("bills.axa", scenario: "maya", prepare: shell(.home, home: [.bill("axa")])),
      Screen("accounts", scenario: "maya", prepare: shell(.home, home: [.accounts])),
    ]
  }
#endif
