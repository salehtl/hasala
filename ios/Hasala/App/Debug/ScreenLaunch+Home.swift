#if HASALA_MOCKS
  import Foundation

  // Home and the bell (P5).
  extension ScreenLaunch {
    static let homeScreens: [Screen] = [
      Screen("home", scenario: "maya"),
      Screen("home.hidden", scenario: "mayaHidden"),
      Screen("home.notifications", scenario: "maya", prepare: shell(.home, sheet: .notifications)),
    ]
  }
#endif
