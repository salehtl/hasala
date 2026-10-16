#if HASALA_MOCKS
  import Foundation

  // Plan, category and project detail, the budget sheet and Move money (P7). Each opens the
  // way a person gets there: the Plan tab, a row pushed on its stack, a sheet over it.
  extension ScreenLaunch {
    static let planScreens: [Screen] = [
      // Plan · October (104-0).
      Screen("plan", scenario: "maya", prepare: shell(.plan)),
      // Plan · Dining (31L-0), from its budget row.
      Screen("plan.dining", scenario: "maya", prepare: shell(.plan, plan: [.category("dining")])),
      // Plan · Change Dining's budget (4B6-0): "Change budget" on Plan · Dining.
      Screen("plan.budget", scenario: "maya",
             prepare: shell(.plan, plan: [.category("dining")], sheet: .budget("dining"))),
      // Plan · Move money (54Y-0): Paper draws it moving money to Groceries, so "Move money
      // in" on Groceries' month.
      Screen("plan.move", scenario: "maya",
             prepare: shell(.plan, plan: [.category("groceries")], sheet: .moveMoney(to: "groceries"))),
      // Plan · Japan trip (5JD-0), from its project card.
      Screen("plan.project", scenario: "maya", prepare: shell(.plan, plan: [.project("japan")])),
      // Not drawn on their own: Assign from Ready to assign (Move money with no category),
      // a needs category's month (sand), a bill's month (no pace) and Dining with amounts hidden.
      Screen("plan.assign", scenario: "maya", prepare: shell(.plan, sheet: .moveMoney(to: nil))),
      Screen("plan.groceries", scenario: "maya", prepare: shell(.plan, plan: [.category("groceries")])),
      Screen("plan.rent", scenario: "maya", prepare: shell(.plan, plan: [.category("rent")])),
      Screen("plan.dining.hidden", scenario: "mayaHidden", prepare: shell(.plan, plan: [.category("dining")])),
    ]
  }
#endif
