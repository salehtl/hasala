#if HASALA_MOCKS
  import Foundation
  import HasalaMocks
  import HasalaModels

  // Home and the bell (P5): spec 10, Paper boards 14O7-0, 2FS-0, 11Y9-0, 12AC-0, 2S7-0, 18WY-0.
  extension ScreenLaunch {
    static let homeScreens: [Screen] = [
      // Home · Default.
      Screen("home", scenario: "maya"),
      // Home · Amounts hidden, as the board draws it: Maya has just tapped the eye, so the
      // toast confirms it ("Amounts hidden · Until you tap the eye again · Show"). The
      // `mayaHidden` scenario starts hidden without the toast.
      Screen("home.hidden", scenario: "maya") { graph in graph.app.toggleAmountsHidden() },
      // Home · Notifications (sheet): four things need a look.
      Screen("home.notifications", scenario: "maya", prepare: shell(.home, sheet: .notifications)),
      // Home · Notifications (all clear): the queue sorted, AXA paid, du's price accepted and the
      // found bill dismissed, as Maya would in Review and Bills.
      Screen("home.allClear", scenario: "mayaCaughtUp", prepare: { graph in
        edit(graph, [.markBillPaid("axa"), .acceptBillAmount("du"), .dismissCandidate("apple-bill")])
        shell(.home, sheet: .notifications)(graph)
      }),
      // Home · Over pace: a tighter plan of 11,000 (needs 9,300, wants 1,700, both still
      // under) puts the tick at 8,636.52, so day 10's 10,288.34 is well past it with 711.66
      // left: ahead of pace, sand, amber from the tick to the end of spent (the board's day 22
      // needs spending the mock can't add).
      Screen("home.overPace", scenario: "maya", prepare: { graph in
        edit(graph, [
          budget("groceries", 0), budget("transport", 50), budget("travel", 0), budget("shopping", 0),
          budget("entertainment", 0), budget("dining", 1_350),
        ])
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
