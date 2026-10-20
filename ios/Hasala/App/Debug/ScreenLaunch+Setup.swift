#if HASALA_MOCKS
  import Foundation
  import HasalaDesign

  // Setup after the account (P2).
  extension ScreenLaunch {
    static let setupScreens: [Screen] = [
      Screen("setup.bank", scenario: "setupBank"),
      Screen("setup.chooseEmail", scenario: "setupBank") { graph in
        // "Continue with 2 banks": the chooser over the bank step (Debug reads two providers).
        await setupModel(graph).continueWithBanks()
      },
      Screen("setup.scan", scenario: "setupEmail") { await setUp($0, to: .scan, scanStep: .milliseconds(450)) },
      Screen("setup.scanOutlook", scenario: "setupEmail") { graph in
        // Outlook connected, its first scan running (Paper 1NMP-0).
        scanPace(graph, .milliseconds(450))
        await setupModel(graph).connectMail(.outlook)
      },
      Screen("setup.income", scenario: "setupEmail") {
        await setUp($0, to: .income, scanStep: .milliseconds(450))
      },
      Screen("setup.plan", scenario: "setupEmail") { await setUp($0, to: .plan, scanStep: .milliseconds(450)) },
      // The import done by the time the result shows: "268 transactions, sorted."
      Screen("setup.result", scenario: "setupEmail") { await setUp($0, to: .result, scanStep: .milliseconds(5)) },
      Screen("setup.sort", scenario: "setupEmail", drive: { await setUp($0, to: .sort, scanStep: .milliseconds(450)) }) { graph in
        (graph.session.services.cloudSort as? MockCloudSort)?.isOffered = true
      },
      Screen("setup.notifications", scenario: "setupEmail") {
        await setUp($0, to: .notifications, scanStep: .milliseconds(5))
      },
      Screen("setup.done", scenario: "setupEmail") { await setUp($0, to: .done, scanStep: .milliseconds(5)) },
    ]

    /// The store's setup model, its back stack built (once), as the setup screen gets it.
    static func setupModel(_ graph: MockGraph) -> SetupModel {
      let model = graph.onboarding.setupModel(
        displayName: graph.session.account.profile?.displayName ?? "", facts: graph.setupFacts)
      model.resume()
      return model
    }

    /// The first scan at `step` per 24 alerts: slow, so a screenshot finds it running (the
    /// pill on income and plan, the count mid-way on the scan), or quick, so it has finished.
    static func scanPace(_ graph: MockGraph, _ step: Duration) {
      (graph.session.services.mailbox as? MockMailbox)?.step = step
    }

    /// From the email step (Gmail): connect, then each step as a person fills it in
    /// (25,000 a month on the keypad, payday the 28th, the 50/30/20 plan, "Not now"),
    /// stopping on `stop`.
    static func setUp(_ graph: MockGraph, to stop: SetupRoute, scanStep: Duration? = nil) async {
      if let scanStep { scanPace(graph, scanStep) }
      let model = setupModel(graph)
      await model.connectMail(.gmail)
      guard stop != .scan else { return }
      model.planWhileScanning()
      for key in "25000" { model.incomeEntry.type(.digit(key.wholeNumberValue ?? 0)) }
      model.paydayChoice = .day(28)
      guard stop != .income else { return }
      model.continueWithIncome()
      guard stop != .plan else { return }
      await model.savePlan()
      guard stop != .result else { return }
      model.afterResult()
      guard stop != .sort else { return }
      if model.path.last == .sort { model.cloudSortNotNow() }
      guard stop != .notifications else { return }
      model.notNow()
    }
  }
#endif
