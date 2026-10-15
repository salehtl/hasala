import CoreMailbox
import CoreTime
import Foundation
import HasalaModels
import Observation

/// The mailbox contract over the open account's Gmail lane (spec 04 §7.4, §7.7; plan B4.4):
/// "Continue with Google" runs the lane's connect (Google sign-in, token custody, the
/// `mailbox.link` step-up), and the first scan streams its progress while it files what it
/// reads (no cards step). On a review account with an empty ledger setup offers "Use sample
/// data" instead (§6.13), which loads the bundled seed through the outbox.
///
/// This build reads Gmail only: `connectable` lists nothing else, and the server holds one
/// link per account, so there is no second mailbox. The lane's status gives the one row.
@MainActor
@Observable
final class LiveMailboxConnecting: MailboxConnecting, BankAlertsReporting {
  @ObservationIgnored private let runtime: @MainActor () -> AccountRuntime?

  init(runtime: @escaping @MainActor () -> AccountRuntime?) {
    self.runtime = runtime
  }

  /// The live mailbox's id: there is one lane.
  static let gmailID = "gmail"

  /// Gmail when this build has a Google client (the runtime built a lane), else nothing.
  /// Outlook is never listed until a live Outlook lane exists.
  var connectable: [MailProviderKind] { Self.connectable(hasLane: runtime()?.lane != nil) }

  /// The providers for a runtime with or without a Gmail lane (the Release gate, plan B4.6).
  static func connectable(hasLane: Bool) -> [MailProviderKind] { hasLane ? [.gmail] : [] }

  /// No `.addSecond`: linking one mailbox replaces the account's link on the server.
  var capabilities: MailboxCapabilities { [.connect, .signInAgain, .disconnect] }

  /// Observed through the runtime: the lane's status is read when the account opens and
  /// after every run and connect.
  var mailboxes: [MailboxSnapshot] {
    guard let rt = runtime(), let status = rt.store.mailboxStatus else { return [] }
    return Self.mailboxes(status, nowMs: rt.context.clock.nowMs())
  }

  /// Observed through the runtime: the review flag arrives with `GET /account`.
  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  /// Observed through the runtime, like `mailboxes`.
  var offer: MailOffer? { runtime()?.mailOffer }

  func chosenBanks() -> [SupportedBank] {
    guard let rt = runtime() else { return [] }
    return Self.banks(trusted: BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:]))
  }

  func linkState() async -> OnboardingStep.Facts.Mailbox {
    guard let lane = runtime()?.lane else { return .unlinked }
    return BootController.mailboxFact(await lane.status().phase)
  }

  // MARK: Bank by bank (Bank alerts)

  /// How long ago the lane's newest alert from `bank` arrived, from its bank health rows.
  func lastEmail(_ bank: SupportedBank) -> String? {
    guard let rt = runtime(), let status = rt.store.mailboxStatus else { return nil }
    return Self.lastEmail(bank, health: status.health, nowMs: rt.context.clock.nowMs())
  }

  /// The alerts the lane read this month, from its bank health rows.
  var readThisMonth: MonthRead? {
    guard let rt = runtime(), let status = rt.store.mailboxStatus else { return nil }
    return Self.readThisMonth(status.health, nowMs: rt.context.clock.nowMs())
  }

  /// The newest `lastEmailAtMs` among the rows of `bank`'s sender domains, as "4 min ago".
  static func lastEmail(_ bank: SupportedBank, health: [BankHealthRow], nowMs: Int64) -> String? {
    let domains = GmailLane.senderDomains(bank: bank.rawValue)
    let newest = health.filter { BankDomains.isMember($0.domain, of: domains) }.compactMap(\.lastEmailAtMs).max()
    return newest.map { LedgerStateMapper.ago(nowMs - $0) }
  }

  /// The rows' `readThisMonth` for the local month of `nowMs` ("214 read in October"); a
  /// row last bumped in an earlier month read none this month.
  static func readThisMonth(_ health: [BankHealthRow], nowMs: Int64) -> MonthRead? {
    guard let month = LocalClock.localMonth(nowMs) else { return nil }
    let count = health.filter { $0.month == month.description }.reduce(0) { $0 + $1.readThisMonth }
    guard count > 0 else { return nil }
    return MonthRead(count: count, month: YearMonth(month.year, month.month).name)
  }

  // MARK: The row (plan B4.4's table)

  /// The lane's one mailbox as a row, or none while it is unlinked.
  static func mailboxes(_ s: MailboxStatus, nowMs: Int64) -> [MailboxSnapshot] {
    mailboxes(phase: s.phase, halt: s.haltedOn, address: s.address, lastSuccessAtMs: s.lastSuccessAtMs,
              bankDomains: s.health.map(\.domain), nowMs: nowMs)
  }

  /// The row from the status's parts (the table in plan B4.4). The mailbox page's "Last
  /// checked" is the last good run on this iPhone's clock, at the ledger's local time
  /// (`LocalClock`, as every transaction time is).
  static func mailboxes(
    phase: MailboxPhase, halt: MailboxHaltCode?, address: String?, lastSuccessAtMs: Int64?, bankDomains: [String],
    nowMs: Int64, timeZone: TimeZone = localTimeZone
  ) -> [MailboxSnapshot] {
    let checked = lastSuccessAtMs.map { "Checked \(LedgerStateMapper.ago(nowMs - $0))" } ?? "Not checked yet"
    var row = MailboxSnapshot(
      id: gmailID, provider: .gmail, address: address ?? "Gmail", state: .connected, meta: checked,
      banks: Set(bankDomains.compactMap { LedgerStateMapper.bankName(domain: $0) }).sorted(),
      lastChecked: lastSuccessAtMs.map { checkedAt($0, timeZone: timeZone) })
    switch phase {
    case .unlinked:
      return []
    case .scanning, .awaitingCards:
      row.state = .syncing
      row.meta = "Checking now"
    case .authoringBackfill, .active:
      break
    case .reconnectRequired:
      row.state = .needsSignIn
    case .halted:
      if offer(phase: .halted, halt: halt, sampleLoaded: false, serverLink: .noLink) != nil {
        row.state = .needsSignIn
      } else {
        row.note = "Reading your bank alerts stopped."
      }
    case .otherDevice:
      row.note = "Read on your other iPhone"
    }
    return [row]
  }

  /// The ledger's local time (+04:00, `LocalClock`), in which every date the app shows is
  /// written.
  static let localTimeZone = TimeZone(secondsFromGMT: Int(LocalClock.offsetMinutes) * 60) ?? .gmt

  /// "Wed 7 Oct, 09:14": when the lane last read the mailbox, as the mailbox page says it.
  static func checkedAt(_ ms: Int64, timeZone: TimeZone = localTimeZone) -> String {
    let format = Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: "en_GB"),
                                  calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let day = date.formatted(format.weekday(.abbreviated).day(.defaultDigits).month(.abbreviated))
    let time = date.formatted(format.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    return "\(day), \(time)"
  }

  /// What the bell, Profile and Bank alerts offer for a lane `phase` (spec 04 §6.6 row 4,
  /// §7.4). Nothing once the account holds the App Review sample: loading it completed the
  /// email step. An iPhone without a link offers it only once the server says no other
  /// iPhone holds one (`serverLink`): connecting there would take Gmail over from that
  /// iPhone. A halt is offered a new sign-in only when signing in to Google again fixes it.
  static func offer(
    phase: MailboxPhase, halt: MailboxHaltCode? = nil, sampleLoaded: Bool, serverLink: MailboxLinkStatus?
  ) -> MailOffer? {
    guard !sampleLoaded else { return nil }
    let signInAgain = MailOffer.signInAgain(mailboxID: gmailID, provider: .gmail)
    switch phase {
    case .unlinked:
      switch serverLink {
      case .noLink?, .holder(true, _)?: return .connect
      case .holder(false, _)?, nil: return nil
      }
    case .reconnectRequired: return signInAgain
    case .halted:
      // A full account or missing templates aren't fixed by a new Google sign-in.
      switch halt {
      case nil, .gmail?, .reconnectRequired?: return signInAgain
      default: return nil
      }
    // The first import runs on its own (Profile says "Importing").
    case .scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice: return nil
    }
  }

  /// Before a connect from an iPhone without a link, the server's answer asked just now:
  /// another iPhone holding the link refuses it (connecting would take Gmail over from
  /// that iPhone), and so does no answer (`nil`, offline), as no offer shows then.
  static func checkTakeover(_ link: MailboxLinkStatus?) throws(MailConnectFailure) {
    switch link {
    case .noLink?, .holder(true, _)?: return
    case .holder(false, _)?: throw .takenByOtherIPhone
    case nil: throw .offline
    }
  }

  /// The banks whose alert senders are among the `trusted` domains (the bank step's ops).
  static func banks(trusted: [String]) -> [SupportedBank] {
    SupportedBank.allCases.filter { bank in
      GmailLane.senderDomains(bank: bank.rawValue).contains { trusted.contains($0) }
    }
  }

  // MARK: Connect, sign in again, disconnect

  private func lane() throws(MailConnectFailure) -> GmailLane {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Gmail isn't available in this build.") }
    return lane
  }

  @discardableResult
  func connect(_ provider: MailProviderKind) async throws(MailConnectFailure) -> String {
    // Unreachable: only Gmail is in `connectable`, and no copy here names another provider.
    guard provider == .gmail else { throw .failed("Hasala reads Gmail only.") }
    let lane = try lane()
    // The offer may be older than another iPhone's link: ask the server again first.
    if await lane.status().phase == .unlinked, let rt = runtime() {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link)
    }
    try await Self.linked(lane.connect(backfillDays: 90))
    // The bell, Profile and Bank alerts follow the lane's new phase.
    await runtime()?.refreshMailbox()
    return Self.gmailID
  }

  /// The same lane connect: Google's sign-in and the step-up again, then the lane picks up
  /// where it stopped.
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) {
    let lane = try lane()
    try await Self.linked(lane.connect(backfillDays: 90))
    await runtime()?.refreshMailbox()
  }

  /// CoreMailbox's disconnect: the `mailbox.unlink` step-up, the watch stopped, the grant
  /// revoked at Google, the server's link deleted. Live keeps no row for it afterwards.
  func disconnect(_ mailboxID: String) async throws(MailConnectFailure) {
    let lane = try lane()
    guard await lane.disconnect() else { throw .failed("Couldn't disconnect Gmail. Try again.") }
    await runtime()?.refreshMailbox()
  }

  private static func linked(_ result: ConnectResult) throws(MailConnectFailure) {
    switch result {
    case .connected: return
    case .cancelled: throw .cancelled
    case .failed(.offline): throw .offline
    case .failed(let f): throw .failed(message(f))
    }
  }

  // MARK: The first scan

  func firstScan() -> AsyncStream<ScanProgress> {
    guard let lane = try? lane() else {
      return AsyncStream { c in
        c.yield(ScanProgress(phase: .failed("Gmail isn't connected."), read: 0, total: 0))
        c.finish()
      }
    }
    let rt = runtime()
    return AsyncStream { continuation in
      // Not cancelled with the stream: the import outlives the setup screens.
      Task {
        var last = ScanProgress(phase: .downloading, read: 0, total: 0)
        for await event in lane.firstScan() {
          switch event {
          case .progress(let p):
            last = Self.progress(p)
            continuation.yield(last)
          case .ended(let t):
            continuation.yield(Self.ended(t, last: last))
          }
        }
        // Profile stops saying "Importing" (it runs on after setup is left).
        await rt?.refreshMailbox()
        continuation.finish()
      }
    }
  }

  /// Where the first scan's foreground runs left it, with what they filed.
  static func ended(_ t: GmailLane.FirstScanTotals, last: ScanProgress) -> ScanProgress {
    let summary = SortSummary(
      total: t.ops, byRules: t.byRules, byDictionary: t.byDictionary, byModel: t.byModel, toReview: t.toReview)
    switch t.phase {
    case .active:
      return ScanProgress(phase: .finished, read: last.total, total: last.total, summary: summary)
    case .halted, .reconnectRequired, .otherDevice:
      return ScanProgress(
        phase: .failed("Reading your bank alerts stopped. Try again."), read: last.read, total: last.total,
        summary: summary)
    case .unlinked, .scanning, .awaitingCards, .authoringBackfill:
      return ScanProgress(phase: .background, read: last.read, total: last.total, summary: summary)
    }
  }

  func loadSampleData() async throws(SetupFailure) {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    try await rt.loadSample()
  }

  static func progress(_ p: MailboxProgress) -> ScanProgress {
    switch p.stage {
    case .listing, .downloading: ScanProgress(phase: .downloading, read: p.done, total: p.total)
    case .authoring: ScanProgress(phase: .sorting, read: p.done, total: p.total)
    case .done: ScanProgress(phase: .finished, read: p.total, total: p.total)
    case .failed: ScanProgress(phase: .failed("Reading your bank alerts stopped. Try again."), read: p.done, total: p.total)
    }
  }

  /// Plain-language copy for a failed connect (spec 04 §7.11; content-free).
  static func message(_ f: ConnectFailure) -> String {
    switch f {
    case .offline: "You're offline. Connect Gmail when you're back online."
    case .permissionMissing: "Hasala needs permission to read your bank alerts. Try again and allow it."
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .notConfigured: "Gmail isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      "Couldn't connect Gmail. Try again."
    }
  }
}
