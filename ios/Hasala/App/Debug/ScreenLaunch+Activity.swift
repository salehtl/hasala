#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  // Activity, the transaction sheet, Review and the Debug Search (P6). Each screen is reached
  // the way a person reaches it: a tab, a row, a sheet; the review screens run the deck's own
  // session model through the steps a person takes (start at a row, Use, a pill).
  extension ScreenLaunch {
    static let activityScreens: [Screen] = [
      // Activity · Overview (Paper 1QG-0).
      Screen("activity", scenario: "maya", prepare: shell(.activity)),
      // Activity · Transaction detail (Carrefour) (3FZ-0).
      Screen("activity.txn", scenario: "maya", prepare: shell(.activity, sheet: .transaction("carrefour"))),
      // Activity · Choose a category (Lulu) (5PR-0): a to-review row's sheet, then Category.
      Screen("activity.category", scenario: "maya",
             prepare: shell(.activity, sheet: .transaction("lulu"), transaction: [.category])),
      // Activity · Split (Carrefour) (6N5-0): the board's split, saved earlier (297.00 in
      // Groceries, 45.15 in Shopping with its note), opened again from the sheet.
      Screen("activity.split", scenario: "maya", prepare: { graph in
        graph.app.perform(.split("carrefour", [
          SplitLine(id: 1, categoryID: "groceries", amount: .aed(297_00)),
          SplitLine(id: 2, categoryID: "shopping", amount: .aed(45_15), note: "Kitchen towels and batteries"),
        ]))
        graph.app.dismissToast()
        shell(.activity, sheet: .transaction("carrefour"), transaction: [.split])(graph)
      }),
      // Activity · Filtered (Dining) · October (7LT-0): Search's Dining row opens it.
      Screen("activity.filtered", scenario: "maya", prepare: { graph in
        ActivityRequests.shared.show(TxnFilter(category: "dining"), in: graph.app)
      }),
      // Review · Tab · To sort (6) (NPV-0).
      Screen("review", scenario: "maya", prepare: shell(.review)),
      // Review · Deck (2 of 6) (26H-0): the Apple.com row opens the deck, "Use" files it, and
      // Lulu Hypermarket is on top, 2 of 6.
      Screen("review.deck", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "apple") { $0.useSuggestion("apple") }
      }),
      // Review · Pick a need (sheet) (3SH-0): the same, then the Need pill.
      Screen("review.pick", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "apple") { deck in
          deck.useSuggestion("apple")
          deck.pick("lulu", .need)
        }
      }),
      // Review · All caught up (4MY-0): every card sorted in one session, in the board's order,
      // three of them teaching a rule; the last sort's toast stays, as the board draws it.
      Screen("review.done", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "lulu", keepsToast: true) { deck in
          deck.sort("lulu", into: "groceries", alwaysUse: true, project: nil)
          deck.sort("dubai-taxi", into: "transport", alwaysUse: true, project: nil)
          deck.useSuggestion("apple")
          deck.sort("steam", into: "entertainment", alwaysUse: true, project: nil)
          deck.sort("transfer-in", into: "freelance", alwaysUse: false, project: nil)
          deck.useSuggestion("atm")
        }
      }),
      // Nothing to sort: the Review tab on the caught-up ledger.
      Screen("review.empty", scenario: "mayaCaughtUp", prepare: shell(.review)),
      // Search · Ready (Debug only).
      Screen("search", scenario: "maya", prepare: shell(.search)),
      // Search · Results as you type ("carre").
      Screen("search.results", scenario: "maya", prepare: { graph in
        SearchHistory.launchQuery = "carre"
        shell(.search)(graph)
      }),
    ]

    /// The Review tab, then the deck opened at `card`, then `steps` on the deck's session.
    /// The boards draw no toast over the deck, so the last step's toast goes unless asked to
    /// stay.
    private static func startDeck(
      _ graph: MockGraph, at card: TxnID, keepsToast: Bool = false, _ steps: @escaping (ReviewViewModel) -> Void
    ) {
      shell(.review, cover: .review)(graph)
      ReviewEntry.request(graph.app, at: card)
      let app = graph.app
      ReviewEntry.onNextSession(of: app) { deck in
        steps(deck)
        if !keepsToast { app.dismissToast() }
      }
    }
  }
#endif
