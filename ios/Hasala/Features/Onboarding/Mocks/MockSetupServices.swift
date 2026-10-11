#if HASALA_MOCKS
  import Foundation

  /// The Gmail lane's stand-in for Debug scenarios and UI tests: a connect that always
  /// succeeds, a first scan of 268 synthetic alerts that runs in about two seconds, and
  /// the three cards of Paper's "Are these your cards?" (synthetic last-four digits).
  @MainActor
  final class MockMailbox: MailboxConnecting {
    var offersSampleData: Bool
    var total = 268
    var step: Duration = .milliseconds(120)
    private(set) var connected = false
    private(set) var sampleLoaded = false
    private(set) var confirmed: [DiscoveredCard] = []

    init(offersSampleData: Bool = false) {
      self.offersSampleData = offersSampleData
    }

    func connectGmail(banks: [SupportedBank]) async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      connected = true
    }

    func firstScan() -> AsyncStream<ScanProgress> {
      let total = total
      let step = step
      return AsyncStream { continuation in
        let task = Task {
          var read = 0
          while read < total {
            try? await Task.sleep(for: step)
            if Task.isCancelled { break }
            read = min(total, read + 24)
            continuation.yield(ScanProgress(phase: read < total / 3 ? .downloading : .sorting, read: read, total: total))
          }
          continuation.yield(ScanProgress(phase: .awaitingCards, read: total, total: total))
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    func discoveredCards() async -> [DiscoveredCard] {
      [
        DiscoveredCard(id: "card-enbd-1", bank: .enbd, last4: "4421", alertCount: 201, keep: true),
        DiscoveredCard(id: "card-dib-1", bank: .dib, last4: "0937", alertCount: 63, keep: true),
        DiscoveredCard(id: "card-enbd-2", bank: .enbd, last4: "1180", alertCount: 4, keep: false),
      ]
    }

    func confirmCards(_ cards: [DiscoveredCard]) async throws(SetupFailure) -> SortSummary {
      try? await Task.sleep(for: .milliseconds(200))
      confirmed = cards
      let kept = cards.filter(\.keep).reduce(0) { $0 + $1.alertCount }
      return SortSummary(total: kept, byRules: 0, byDictionary: Int(Double(kept) * 0.65), byModel: Int(Double(kept) * 0.21),
                         toReview: kept - Int(Double(kept) * 0.65) - Int(Double(kept) * 0.21))
    }

    func loadSampleData() async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      sampleLoaded = true
    }
  }

  /// Records the setup ops instead of authoring them.
  @MainActor
  final class MockSetupAuthoring: SetupAuthoring {
    private(set) var banks: [SupportedBank] = []
    private(set) var requestedBanks: [String] = []
    private(set) var income: Int64?
    private(set) var payday: Int?
    private(set) var plan: StartingPlan?
    private(set) var planSaved = false

    func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
      self.banks = banks
    }

    func requestBank(_ name: String) async throws(SetupFailure) {
      requestedBanks.append(name)
    }

    func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure) {
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
