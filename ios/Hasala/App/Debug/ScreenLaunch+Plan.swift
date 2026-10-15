#if HASALA_MOCKS
  import Foundation

  // Plan, category and project detail, the budget sheet and Move money (P7).
  extension ScreenLaunch {
    static let planScreens: [Screen] = [
      Screen("plan", scenario: "maya", prepare: shell(.plan)),
      Screen("plan.dining", scenario: "maya", prepare: shell(.plan, plan: [.category("dining")])),
      Screen("plan.budget", scenario: "maya",
             prepare: shell(.plan, plan: [.category("dining")], sheet: .budget("dining"))),
      Screen("plan.move", scenario: "maya",
             prepare: shell(.plan, plan: [.category("groceries")], sheet: .moveMoney(to: "groceries"))),
      Screen("plan.project", scenario: "maya", prepare: shell(.plan, plan: [.project("japan")])),
    ]
  }
#endif
