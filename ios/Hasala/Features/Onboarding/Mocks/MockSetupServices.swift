#if HASALA_MOCKS
  import Foundation
  import Observation

  /// The Gmail lane's stand-in for Debug scenarios and UI tests: a connect that always
  /// succeeds and a first scan of 268 synthetic alerts that files them in about two seconds,
  /// whether or not anyone is still watching. `gmailOffer` starts the Home and Profile Gmail
  /// actions (the `gmailSkipped` and `gmailReconnect` scenarios); a connect ends it.
  @MainActor
  @Observable
  final class MockMailbox: MailboxConnecting {
    var offersSampleData: Bool
    var gmailOffer: GmailOffer?
    /// The banks the account reads.
    var banks: [SupportedBank] = SupportedBank.allCases
    private(set) var link: OnboardingStep.Facts.Mailbox = .unlinked
    /// Whether the first scan reports alerts sorted by the on-device model. The beta has
    /// no model tier at ingest (a later sweep), so the Release surface turns this off, as
    /// the live lane reports none.
    var sortsWithModel = true
    var total = 268
    var step: Duration = .milliseconds(120)
    private(set) var connected = false
    private(set) var sampleLoaded = false

    init(offersSampleData: Bool = false) {
      self.offersSampleData = offersSampleData
    }

    func chosenBanks() -> [SupportedBank] { banks }

    func linkState() async -> OnboardingStep.Facts.Mailbox { link }

    func connectGmail(banks: [SupportedBank]) async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      connected = true
      // A reconnect picks up where the lane stopped; a first connect scans.
      if gmailOffer == .reconnect {
        link = .linked
      } else {
        link = .scanning
      }
      gmailOffer = nil
    }

    func firstScan() -> AsyncStream<ScanProgress> {
      let total = total
      let step = step
      let dictionary = Int(Double(total) * 0.65)
      let model = sortsWithModel ? Int(Double(total) * 0.21) : 0
      let summary = SortSummary(
        total: total, byRules: 0, byDictionary: dictionary, byModel: model, toReview: total - dictionary - model)
      return AsyncStream { continuation in
        // Like the live lane, the import outlives the stream.
        Task {
          var read = 0
          while read < total {
            try? await Task.sleep(for: step)
            read = min(total, read + 24)
            continuation.yield(ScanProgress(phase: read < total / 3 ? .downloading : .sorting, read: read, total: total))
          }
          self.link = .linked
          continuation.yield(ScanProgress(phase: .finished, read: total, total: total, summary: summary))
          continuation.finish()
        }
      }
    }

    func loadSampleData() async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      sampleLoaded = true
      gmailOffer = nil
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
