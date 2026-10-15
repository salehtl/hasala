#if HASALA_MOCKS
  import Foundation
  import HasalaMocks
  import HasalaModels

  // Home and the bell (P5): spec 10, Paper boards 14O7-0, 2FS-0, 11Y9-0, 12AC-0, 2S7-0, 18WY-0.
  extension ScreenLaunch {
    static let homeScreens: [Screen] = [
      // Home · Default.
      Screen("home", scenario: "maya"),
      // Home · Amounts hidden.
      Screen("home.hidden", scenario: "mayaHidden"),
      // Home · Notifications (sheet): four things need a look.
      Screen("home.notifications", scenario: "maya", prepare: shell(.home, sheet: .notifications)),
      // Home · Notifications (all clear): the queue sorted, AXA paid, du's price accepted and the
      // found bill dismissed, as Maya would in Review and Bills.
      Screen("home.allClear", scenario: "mayaCaughtUp", prepare: { graph in
        edit(graph, [.markBillPaid("axa"), .acceptBillAmount("du"), .dismissCandidate("apple-bill")])
        shell(.home, sheet: .notifications)(graph)
      }),
      // Home · Over pace: Travel to 0 and Shopping to 100 make the plan 15,000, so day 10's
      // 10,288.34 is past the tick (9,926.84): ahead of pace, sand.
      Screen("home.overPace", scenario: "maya", prepare: { graph in
        edit(graph, [budget("travel", 0), budget("shopping", 100)])
      }),
      // Home · Over budget: Travel and Rent to 0 make the plan 9,000: over by 1,288.34, rose.
      Screen("home.overBudget", scenario: "maya", prepare: { graph in
        edit(graph, [budget("travel", 0), budget("rent", 0)])
      }),
    ]

    /// Maya's budget for a category this month, in dirhams.
    private static func budget(_ category: CategoryID, _ dirhams: Int64) -> LedgerEdit {
      .setBudget(category, MayaLedger.october, .aed(dirhams * 100))
    }

    /// Applies edits to the mock ledger before the window shows, without their toasts.
    @MainActor private static func edit(_ graph: MockGraph, _ edits: [LedgerEdit]) {
      for e in edits { _ = try? graph.app.store.apply(e) }
    }
  }
#endif
