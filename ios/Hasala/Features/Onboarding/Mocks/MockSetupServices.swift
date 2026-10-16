#if HASALA_MOCKS
  import Foundation
  import Observation

  /// The mailbox lanes' stand-in for Debug scenarios and UI tests: a connect that always
  /// succeeds and a first scan of 268 synthetic alerts that files them in about two seconds,
  /// whether or not anyone is still watching. `mailboxOffer` starts the Home and Profile
  /// mailbox actions (the `gmailSkipped`, `gmailReconnect`, `outlookReconnect` and
  /// `gmailLinked` scenarios); a connect ends it.
  ///
  /// Outlook is offered as the live build offers it: always on the full Debug surface, and on
  /// the Release surface only when the build has an Outlook client. `-HasalaOutlookConfigured`
  /// plays a build that has one.
  @MainActor
  @Observable
  final class MockMailbox: MailboxConnecting {
    var offersSampleData: Bool
    var mailboxOffer: MailboxOffer?
    var linkedProvider: MailboxProvider?
    var providers: [MailboxProvider] = MockMailbox.defaultProviders
    var haltMessage: String?
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

    static var defaultProviders: [MailboxProvider] {
      BuildSurface.showsUnfinished || ProcessInfo.processInfo.arguments.contains("-HasalaOutlookConfigured")
        ? MailboxProvider.allCases : [.gmail]
    }

    /// Linked to `provider` and working: Profile offers the other provider, if any.
    func linkTo(_ provider: MailboxProvider) {
      linkedProvider = provider
      link = .linked
      mailboxOffer = providers.count > 1 ? .change(provider) : nil
    }

    func connectMailbox(_ provider: MailboxProvider, banks: [SupportedBank]) async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      connected = true
      // A reconnect picks up where the lane stopped; a first connect, or a switch, scans.
      if linkedProvider == provider, link != .unlinked {
        link = .linked
      } else {
        link = .scanning
      }
      linkedProvider = provider
      haltMessage = nil
      mailboxOffer = providers.count > 1 ? .change(provider) : nil
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
      mailboxOffer = nil
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
