#if HASALA_MOCKS
  import Foundation

  /// Records the setup ops instead of authoring them, and reads back what was saved.
  /// (The mail lane's stand-in is `MockMailbox`.)
  @MainActor
  final class MockSetupAuthoring: SetupAuthoring {
    private(set) var banks: [SupportedBank] = []
    private(set) var requestedBanks: [String] = []
    private(set) var income: Int64?
    private(set) var payday: Int?
    private(set) var plan: StartingPlan?
    private(set) var planSaved = false
    /// Each op call, counted (tests: an unchanged value is not sent again).
    private(set) var chooseBanksCalls = 0
    private(set) var savePlanCalls = 0
    /// After each `chooseBanks`, with its banks (a scenario hands them to its mailbox mock).
    var choseBanks: ([SupportedBank]) -> Void = { _ in }

    init(saved: SetupReadBack = SetupReadBack()) {
      income = saved.incomeMinor
      payday = saved.payday
      plan = saved.split
    }

    func readBack() -> SetupReadBack { SetupReadBack(incomeMinor: income, payday: payday, split: plan) }

    func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
      chooseBanksCalls += 1
      self.banks = banks
      choseBanks(banks)
    }

    func requestBank(_ name: String) async throws(SetupFailure) {
      requestedBanks.append(name)
    }

    func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure) {
      savePlanCalls += 1
      self.income = income
      self.payday = payday
      self.plan = plan
      planSaved = true
    }
  }

  @MainActor
  final class MockNotificationPermission: NotificationPermissionAsking {
    var showsDetails = false
    private(set) var asked = false

    func requestAuthorization() async -> Bool {
      asked = true
      return true
    }
  }
#endif
