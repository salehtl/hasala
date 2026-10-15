#if HASALA_MOCKS
  import Foundation

  // Setup after the account (P2).
  extension ScreenLaunch {
    static let setupScreens: [Screen] = [
      Screen("setup.bank", scenario: "setupBank"),
      Screen("setup.scan", scenario: "setupEmail") { await setUp($0, to: .scan) },
      Screen("setup.income", scenario: "setupEmail") { await setUp($0, to: .income) },
      Screen("setup.plan", scenario: "setupEmail") { await setUp($0, to: .plan) },
      Screen("setup.result", scenario: "setupEmail") { await setUp($0, to: .result) },
      Screen("setup.notifications", scenario: "setupEmail") { await setUp($0, to: .notifications) },
      Screen("setup.done", scenario: "setupEmail") { await setUp($0, to: .done) },
    ]

    /// The store's setup model, its back stack built (once), as the setup screen gets it.
    static func setupModel(_ graph: MockGraph) -> SetupModel {
      let model = graph.onboarding.setupModel(
        displayName: graph.session.account.profile?.displayName ?? "", facts: graph.setupFacts)
      model.resume()
      return model
    }

    /// From the email step (Gmail): connect, then each step as a person fills it in
    /// (25,000 a month, the 50/30/20 plan, "Not now"), stopping on `stop`.
    static func setUp(_ graph: MockGraph, to stop: SetupRoute) async {
      let model = setupModel(graph)
      await model.connectMail(.gmail)
      guard stop != .scan else { return }
      model.planWhileScanning()
      guard stop != .income else { return }
      model.incomeText = "25000"
      model.continueWithIncome()
      guard stop != .plan else { return }
      await model.savePlan()
      guard stop != .result else { return }
      model.afterResult()
      guard stop != .notifications else { return }
      model.notNow()
    }
  }
#endif
