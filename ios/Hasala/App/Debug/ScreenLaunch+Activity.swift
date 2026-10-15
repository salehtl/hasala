#if HASALA_MOCKS
  import Foundation

  // Activity, the transaction sheet, Review and the Debug Search (P6).
  extension ScreenLaunch {
    static let activityScreens: [Screen] = [
      Screen("activity", scenario: "maya", prepare: shell(.activity)),
      Screen("activity.txn", scenario: "maya", prepare: shell(.activity, sheet: .transaction("carrefour"))),
      Screen("activity.category", scenario: "maya",
             prepare: shell(.activity, sheet: .transaction("lulu"), transaction: [.category])),
      Screen("activity.split", scenario: "maya",
             prepare: shell(.activity, sheet: .transaction("carrefour"), transaction: [.split])),
      Screen("review", scenario: "maya", prepare: shell(.review)),
      Screen("review.deck", scenario: "maya", prepare: shell(.review, cover: .review)),
      Screen("review.done", scenario: "mayaCaughtUp", prepare: shell(.review, cover: .review)),
      Screen("search", scenario: "maya", prepare: shell(.search)),
    ]
  }
#endif
