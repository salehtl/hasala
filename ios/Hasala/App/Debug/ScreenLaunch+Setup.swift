#if HASALA_MOCKS
  import Foundation
  import HasalaDesign

  // Setup after the account (P2).
  extension ScreenLaunch {
    static let setupScreens: [Screen] = [
      Screen("setup.bank", scenario: "setupBank"),
      Screen("setup.chooseEmail", scenario: "setupBank") { graph in
        setupModel(graph).chooseEmail()
      },
    ]

    /// The store's setup model, its back stack built (once), as the setup screen gets it.
    static func setupModel(_ graph: MockGraph) -> SetupModel {
      let model = graph.onboarding.setupModel(
        displayName: graph.session.account.profile?.displayName ?? "", facts: graph.setupFacts)
      model.resume()
      return model
    }
  }
#endif
