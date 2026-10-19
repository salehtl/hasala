#if HASALA_MOCKS
  import Foundation
  import HasalaModels
  import Observation

  /// The mail lane's stand-in for Debug scenarios, previews and UI tests (plan B4.5): Gmail
  /// and Outlook both connect, a connect adds a syncing mailbox that the first scan turns
  /// connected, and the first scan files 268 synthetic alerts in about two seconds,
  /// whether or not anyone is still watching. The scenario flags make the Outlook failures
  /// and "Already connected" happen.
  ///
  /// Fixtures (synthetic, one set; spec 06 open question 1): Gmail `maya@example.com`;
  /// Outlook `maya.k@example.com`, a personal Microsoft account connected on 2 Oct; the work
  /// account `maya@contoso.com` for the admin case. A scenario that starts with Maya's Gmail
  /// also has the one alert Paper shows it couldn't read ("Needs a look", Debug).
  @MainActor
  @Observable
  final class MockMailbox: MailboxConnecting, UnreadableMailReporting, BankAlertsReporting {
    /// A mailbox of a provider this build can't connect can't exist either, so the
    /// scenario's go. The Release surface keeps both, as the live build's client ids do.
    var connectable: [MailProviderKind] = MailProviderKind.allCases {
      didSet { mailboxes.removeAll { !connectable.contains($0.provider) } }
    }
    var capabilities: MailboxCapabilities = .all
    private(set) var mailboxes: [MailboxSnapshot] = []
    var offersSampleData: Bool
    /// The banks the account reads.
    var banks: [SupportedBank] = SupportedBank.allCases
    /// Whether the first scan reports alerts sorted by the on-device model. The beta has
    /// no model tier at ingest (a later sweep), so the Release surface turns this off, as
    /// the live lane reports none.
    var sortsWithModel = true
    var total = 268
    var step: Duration = .milliseconds(120)
    /// How long a provider's sign-in takes.
    var connectDelay: Duration = .milliseconds(600)
    /// An Outlook connect is a work account its admin hasn't approved.
    var outlookAdmin = false
    /// An Outlook sign-in is closed, or its permissions declined.
    var outlookCancelled = false
    var outlookNoMailbox = false
    /// Every connect finds the mailbox already connected.
    var alreadyConnected = false
    /// Every connect finds no network.
    var offline = false
    /// Each `connect` call, whatever its outcome (tests: no second sign-in on Back).
    private(set) var connectCalls = 0
    /// Each `signInAgain` call.
    private(set) var signInCalls = 0
    private(set) var sampleLoaded = false
    /// The alerts a mailbox fetched but couldn't read.
    var unreadableMail: [UnreadableMail] = []
    var importing: MailImport?

    init(offersSampleData: Bool = false, mailboxes: [MailboxSnapshot] = []) {
      self.offersSampleData = offersSampleData
      self.mailboxes = mailboxes
      if mailboxes.contains(where: { $0.id == Self.gmail.id }) { unreadableMail = [Self.unreadable] }
    }

    /// The Release surface's narrowing (`AuthScenario.session`), the live lane's shape: one
    /// mailbox per account, which a connect of the other provider replaces once confirmed
    /// (`.replace`, no `.addSecond`). The scenario keeps its first mailbox still read, and the
    /// disconnected rows (`mailboxes2` and `outlookSignIn` read Gmail only).
    func holdOneLink() {
      capabilities.remove(.addSecond)
      capabilities.insert(.replace)
      if let first = mailboxes.first(where: { $0.state != .disconnected }) {
        mailboxes.removeAll { $0.state != .disconnected && $0.id != first.id }
      }
    }

    // MARK: Fixtures

    static let gmailAddress = "maya@example.com"
    static let outlookAddress = "maya.k@example.com"
    static let workAddress = "maya@contoso.com"

    static let gmail = MailboxSnapshot(
      id: "gmail-1", provider: .gmail, address: gmailAddress, state: .connected, meta: "Checked 4 min ago",
      banks: ["Emirates NBD", "Dubai Islamic Bank"], lastChecked: "Sat 10 Oct, 13:36", connectedOn: "11 Sep")
    static let outlook = MailboxSnapshot(
      id: "outlook-1", provider: .outlook, address: outlookAddress, state: .connected, meta: "Checked 1 h ago",
      accountKind: "Personal Microsoft", banks: ["Dubai Islamic Bank"], lastChecked: "Sat 10 Oct, 12:40",
      connectedOn: "2 Oct")

    /// The debit card alert Maya's Gmail fetched on Thu 8 Oct and couldn't read (Paper 64L).
    static let unreadable = UnreadableMail(kind: "Debit card alert", provider: .gmail, day: "Thu 8 Oct")

    /// A mailbox whose provider ended Hasala's access on Wed 7 Oct.
    static func needingSignIn(_ m: MailboxSnapshot) -> MailboxSnapshot {
      var m = m
      m.state = .needsSignIn
      m.meta = "Checked Wed"
      m.lastChecked = "Wed 7 Oct, 09:14"
      return m
    }

    /// The address a new connect of `provider` reads (a second Google account has its own).
    private func nextAddress(_ provider: MailProviderKind) -> String? {
      let addresses = provider == .gmail ? [Self.gmailAddress, "maya.home@example.com"] : [Self.outlookAddress]
      let taken = Set(mailboxes.filter { $0.state != .disconnected }.map(\.address))
      return addresses.first { !taken.contains($0) }
    }

    // MARK: MailboxConnecting

    var offer: MailOffer? {
      guard !sampleLoaded else { return nil }
      if let m = mailboxes.first(where: { $0.state == .needsSignIn }) {
        return .signInAgain(mailboxID: m.id, provider: m.provider)
      }
      return mailboxes.contains { $0.state != .disconnected } ? nil : .connect
    }

    /// The provider of the first mailbox still read (any state but disconnected).
    var linkedProvider: MailProviderKind? { mailboxes.first { $0.state != .disconnected }?.provider }

    func chosenBanks() -> [SupportedBank] { banks }

    func linkState() async -> OnboardingStep.Facts.Mailbox {
      if mailboxes.contains(where: { $0.state == .syncing }) { return .scanning }
      return mailboxes.contains { $0.state == .connected || $0.state == .needsSignIn } ? .linked : .unlinked
    }

    @discardableResult
    func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
      connectCalls += 1
      try? await Task.sleep(for: connectDelay)
      if offline { throw .offline }
      if provider == .outlook, outlookAdmin { throw .adminApprovalNeeded(address: Self.workAddress) }
      if provider == .outlook, outlookCancelled { throw .cancelled }
      if provider == .outlook, outlookNoMailbox {
        outlookNoMailbox = false
        throw .noMailbox(.outlook)
      }
      if holdsOneLink {
        // One link, as live holds it: the same provider working is already connected; the
        // other provider's link goes only on a confirmed switch, and its row with it (the
        // live lane reports the one link).
        let live = mailboxes.filter { $0.state != .disconnected }
        if let i = mailboxes.firstIndex(where: { $0.provider == provider && $0.state == .needsSignIn }) {
          // The same provider's broken link: a new sign-in, as live's connect is then.
          mailboxes[i].state = .connected
          mailboxes[i].meta = "Checked just now"
          return mailboxes[i].id
        }
        if let same = live.first(where: { $0.provider == provider }) {
          throw .alreadyConnected(address: same.address)
        }
        if let other = live.first(where: { $0.provider != provider }) {
          guard replacing else {
            throw .failed("Disconnect \(other.provider.appName) first, then connect \(provider.appName).")
          }
          mailboxes.removeAll { $0.id == other.id }
        }
      }
      guard !alreadyConnected, let address = nextAddress(provider) else {
        throw .alreadyConnected(address: provider == .gmail ? Self.gmailAddress : Self.outlookAddress)
      }
      // The same mailbox connected again after a disconnect: its grey row comes back to
      // life (one row per address, as Bank alerts lists them), checking from now.
      if let i = mailboxes.firstIndex(where: { $0.provider == provider && $0.address == address && $0.state == .disconnected }) {
        mailboxes[i].state = .syncing
        mailboxes[i].meta = "Checking now"
        mailboxes[i].banks = banks.map(\.name)
        mailboxes[i].connectedOn = "10 Oct"
        return mailboxes[i].id
      }
      let n = mailboxes.filter { $0.provider == provider }.count + 1
      let id = "\(provider.rawValue)-\(n)"
      mailboxes.append(MailboxSnapshot(
        id: id, provider: provider, address: address, state: .syncing, meta: "Checking now",
        accountKind: provider == .outlook ? "Personal Microsoft" : nil,
        banks: banks.map(\.name), connectedOn: "10 Oct"))
      return id
    }

    func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) {
      signInCalls += 1
      try? await Task.sleep(for: connectDelay)
      if offline { throw .offline }
      guard let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { throw .failed("That mailbox is gone.") }
      if mailboxes[i].provider == .outlook, outlookCancelled { throw .cancelled }
      if mailboxes[i].provider == .outlook, outlookNoMailbox {
        outlookNoMailbox = false
        throw .noMailbox(.outlook)
      }
      // It picks up where it stopped: connected, checking from the last check.
      mailboxes[i].state = .connected
      mailboxes[i].meta = "Checked just now"
      mailboxes[i].lastChecked = "Sat 10 Oct, 13:40"
    }

    var imported: [String: MailboxDisconnectImpact] = [
      gmail.id: MailboxDisconnectImpact(transactions: 42, edited: 3),
      "outlook-1": MailboxDisconnectImpact(transactions: 12, edited: 0),
    ]
    private(set) var removed: [String] = []

    func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? {
      guard let impact = imported[mailboxID], impact.transactions > 0 else { return nil }
      return impact
    }

    func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
      try? await Task.sleep(for: connectDelay)
      guard let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { return }
      mailboxes[i].state = .disconnected
      mailboxes[i].meta = "Off since 10 Oct"
      if removeTransactions {
        removed.append(mailboxID)
        imported[mailboxID] = nil
      }
    }

    func firstScan() -> AsyncStream<ScanProgress> {
      let total = total
      let step = step
      // One link held, as live: an Outlook import sends every alert to review while its
      // trust gate is closed (HasalaCore's Outlook shipping gate).
      let unproven = holdsOneLink && mailboxes.contains { $0.state == .syncing && $0.provider == .outlook }
      let dictionary = unproven ? 0 : Int(Double(total) * 0.65)
      let model = sortsWithModel && !unproven ? Int(Double(total) * 0.21) : 0
      let summary = SortSummary(
        total: total, byRules: 0, byDictionary: dictionary, byModel: model, toReview: total - dictionary - model)
      return AsyncStream { continuation in
        // Like the live lane, the import outlives the stream.
        Task {
          var read = 0
          self.importing = MailImport(state: .reading, read: 0, total: total)
          while read < total {
            try? await Task.sleep(for: step)
            read = min(total, read + 24)
            self.importing = MailImport(state: .reading, read: read, total: total)
            continuation.yield(ScanProgress(phase: read < total / 3 ? .downloading : .sorting, read: read, total: total))
          }
          self.importing = nil
          self.scanFinished()
          continuation.yield(ScanProgress(phase: .finished, read: total, total: total, summary: summary))
          continuation.finish()
        }
      }
    }

    /// The first scan read its window: every syncing mailbox is connected.
    private func scanFinished() {
      for i in mailboxes.indices where mailboxes[i].state == .syncing {
        mailboxes[i].state = .connected
        mailboxes[i].meta = "Checked just now"
        mailboxes[i].lastChecked = "Sat 10 Oct, 13:40"
      }
    }

    func loadSampleData() async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      sampleLoaded = true
    }

    // MARK: BankAlertsReporting (Paper 1NS8's numbers)

    /// When each bank's newest alert arrived, once a mailbox has read it.
    static let lastEmails: [SupportedBank: String] = [.enbd: "4 min ago", .dib: "2 h ago"]

    /// A bank's last alert, when a mailbox that has already read (not one on its first
    /// import) reads its alerts.
    func lastEmail(_ bank: SupportedBank) -> String? {
      let read = mailboxes.contains { m in
        (m.state == .connected || m.state == .needsSignIn) && m.banks.contains { $0 == bank.name || $0 == bank.shortName }
      }
      return read ? Self.lastEmails[bank] : nil
    }

    /// "214 read in October", once a mailbox has read.
    var readThisMonth: MonthRead? {
      mailboxes.contains { $0.state == .connected || $0.state == .needsSignIn } ? MonthRead(count: 214, month: "October") : nil
    }
  }
#endif
