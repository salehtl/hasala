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
      Screen("setup.source", scenario: "setupTexts") { _ = setupModel($0) },
      Screen("setup.texts.banks", scenario: "setupTexts") { graph in
        setupModel(graph).chooseSource(.texts)
      },
      Screen("setup.texts", scenario: "setupTexts") { graph in
        let model = setupModel(graph)
        model.chooseSource(.texts)
        await model.continueWithTextBanks()
      },
      Screen("setup.texts.waiting", scenario: "setupTexts") { graph in
        await textsTest(graph, outcome: .received, after: .seconds(3600))
      },
      Screen("setup.texts.works", scenario: "setupTexts") { graph in
        await textsTest(graph, outcome: .received, after: .zero)
      },
      Screen("setup.texts.nothing", scenario: "setupTexts") { graph in
        await textsTest(graph, outcome: .nothing, after: .zero)
      },
    ]

    static func bankTexts(_ graph: MockGraph) -> MockBankTexts? {
      graph.session.services.bankTexts as? MockBankTexts
    }

    static func textsTest(_ graph: MockGraph, outcome: MockBankTexts.TestOutcome, after delay: Duration) async {
      bankTexts(graph)?.testOutcome = outcome
      bankTexts(graph)?.testDelay = delay
      let model = setupModel(graph)
      model.chooseSource(.texts)
      await model.continueWithTextBanks()
      model.sendTestText()
    }

    /// The store's setup model, its back stack built (once), as the setup screen gets it.
    static func setupModel(_ graph: MockGraph) -> SetupModel {
      let model = graph.onboarding.setupModel(
        displayName: graph.session.account.profile?.displayName ?? "", facts: graph.setupFacts)
      model.resume()
      return model
    }
  }

  @MainActor
  enum BankTextsLaunch {
    static var pasted: String?
    static var openPaste = false

    static func takePasted() -> String? {
      defer { pasted = nil }
      return pasted
    }

    static func takeOpenPaste() -> Bool {
      defer { openPaste = false }
      return openPaste
    }
  }
#endif
