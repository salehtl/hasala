#if HASALA_MOCKS
  import Foundation
  import HasalaMocks
  import HasalaModels

  /// Records the setup ops instead of authoring them, and reads back what was saved.
  /// (The mail lane's stand-in is `MockMailbox`.)
  @MainActor
  final class MockSetupAuthoring: SetupAuthoring, SetupClock {
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
    var setBanksCalls = 0
    /// The ledger's today: Maya's Saturday 10 October.
    var day = MayaLedger.now.date

    init(saved: SetupReadBack = SetupReadBack()) {
      income = saved.incomeMinor
      payday = saved.payday
      plan = saved.split
    }

    func readBack() -> SetupReadBack { SetupReadBack(incomeMinor: income, payday: payday, split: plan) }

    func today() -> LocalDate { day }

    func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
      chooseBanksCalls += 1
      self.banks = banks
      choseBanks(banks)
    }

    func setBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
      setBanksCalls += 1
      self.banks = banks
      choseBanks(banks)
    }

    func requestBank(_ name: String) async throws(SetupFailure) {
      guard BankName.valid(BankName.normalized(name)) else { throw .failed(BankName.hint) }
      requestedBanks.append(name)
      if !requests.contains(where: { $0.name == name }) {
        requests.append(RequestedBank(bank: "other", name: name, state: .requested))
      }
    }

    var requests: [RequestedBank] = []

    static let worstRequests = [
      RequestedBank(bank: "other", name: "Commercial Bank of Dubai", state: .templateInProgress),
      RequestedBank(bank: "other", name: "بنك المشرق", state: .declined),
      RequestedBank(bank: "other", name: "bank", state: .supported),
      RequestedBank(bank: "other", name: "Commercial Bank International – Ras Al Khaimah Branch Accounts", state: .requested),
      RequestedBank(bank: "other", name: "مَصْرِف عجمان الإسلامي", state: .collectingSamples),
    ]
    private(set) var senderDomains: [String: String] = [:]

    func requestBank(slug: String, senderDomain: String?) async throws(SetupFailure) {
      requestedBanks.append(slug)
      if let senderDomain { senderDomains[slug] = senderDomain }
      guard !requests.contains(where: { $0.bank == slug }) else { return }
      let name = BankCandidate.all.first { $0.slug == slug }?.name ?? slug
      requests.append(RequestedBank(bank: slug, name: name, state: .requested))
    }

    func bankRequests() async throws(SetupFailure) -> BankRequestsSnapshot {
      BankRequestsSnapshot(
        requests: requests,
        catalog: BankCandidate.all.map { BankCatalogChoice(slug: $0.slug, name: $0.name, state: .requested) })
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
  final class MockCloudSort: CloudSortOffering {
    static let argument = "-HasalaCloudSort"

    var isOffered: Bool
    private(set) var isOn = false
    private(set) var declined = false
    private(set) var turnOnCalls = 0

    init(offered: Bool = ProcessInfo.processInfo.arguments.contains(MockCloudSort.argument), on: Bool = false) {
      isOffered = offered
      isOn = on
    }

    var answered: Bool { isOn || declined }

    func turnOn() {
      turnOnCalls += 1
      isOn = true
    }

    func notNow() {
      declined = true
    }
  }

  @MainActor
  final class MockNotificationPermission: NotificationPermissionAsking {
    var showsDetails = false
    private(set) var asked = false
    private(set) var declined = false

    init(answered: Bool = false) {
      asked = answered
    }

    var answered: Bool { asked || declined }

    func decline() {
      declined = true
    }

    func requestAuthorization() async -> Bool {
      asked = true
      return true
    }
  }
#endif
