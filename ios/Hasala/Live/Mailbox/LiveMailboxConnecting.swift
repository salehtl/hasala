import CoreMailbox
import Foundation
import Observation

/// Setup's mailbox step over the open account (spec 04 §7.4, §7.7): "Connect Gmail" or
/// "Connect Outlook" runs that provider's lane connect (its sign-in, token custody, the
/// `mailbox.link` step-up), and the first scan streams its progress while it files what it
/// reads (no cards step). On a review account with an empty ledger the step offers "Use
/// sample data" instead (§6.13), which loads the bundled seed through the outbox. Home and
/// Profile run the same connect after setup, when `mailboxOffer` says the mailbox needs it.
///
/// One link per account: connecting one provider replaces the other's link on the server.
/// Here the new lane clears the shared mailbox tables only once its link is made, then the
/// old lane ends its grant (its watch or subscription, its tokens).
@MainActor
@Observable
final class LiveMailboxConnecting: MailboxConnecting {
  @ObservationIgnored private let runtime: @MainActor () -> AccountRuntime?

  init(runtime: @escaping @MainActor () -> AccountRuntime?) {
    self.runtime = runtime
  }

  /// Observed through the runtime: the review flag arrives with `GET /account`.
  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  /// Observed through the runtime: the lane's phase is read when the account opens and
  /// after every run and connect.
  var mailboxOffer: MailboxOffer? { runtime()?.mailboxOffer }

  var linkedProvider: MailboxProvider? { runtime()?.linkedProvider }

  var providers: [MailboxProvider] { runtime()?.providers ?? [] }

  var haltMessage: String? { runtime()?.haltMessage }

  func chosenBanks() -> [SupportedBank] {
    guard let rt = runtime() else { return [] }
    return Self.banks(trusted: BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:]))
  }

  func linkState() async -> OnboardingStep.Facts.Mailbox {
    guard let lane = runtime()?.lane else { return .unlinked }
    return BootController.mailboxFact(await lane.status().phase)
  }

  /// What Home and Profile offer for a lane `phase` of `provider`'s lane (spec 04 §6.6 row
  /// 4, §7.4). Nothing once the account holds the App Review sample: loading it completed
  /// the mailbox step. An iPhone without a link offers it only once the server says no
  /// other iPhone holds one (`serverLink`): connecting there would take the link over from
  /// that iPhone. A halt is offered a reconnect only when signing in again (to this provider
  /// or the other) fixes it (`halt`). A link that works offers the other provider, when the
  /// build has one (`providers`).
  static func offer(
    phase: MailboxPhase, halt: MailboxHaltCode? = nil, sampleLoaded: Bool, serverLink: MailboxLinkStatus?,
    provider: MailboxProvider = .gmail, providers: [MailboxProvider] = [.gmail]
  ) -> MailboxOffer? {
    guard !sampleLoaded else { return nil }
    switch phase {
    case .unlinked:
      switch serverLink {
      case .noLink?, .holder(true, _)?: return .connect
      case .holder(false, _)?, nil: return nil
      }
    case .reconnectRequired: return .reconnect(provider)
    case .halted:
      // A full account or missing templates aren't fixed by a new sign-in.
      switch halt {
      case nil, .gmail?, .reconnectRequired?, .noMailbox?: return .reconnect(provider)
      default: return nil
      }
    case .active: return providers.contains { $0 != provider } ? .change(provider) : nil
    // The first import runs on its own (Profile and Home say "Importing").
    case .scanning, .awaitingCards, .authoringBackfill, .otherDevice: return nil
    }
  }

  /// Before a connect from an iPhone without a link, the server's answer asked just now:
  /// another iPhone holding the link refuses it (connecting would take the link over from
  /// that iPhone), and so does no answer (`nil`, offline), as Home shows no offer then.
  static func checkTakeover(_ link: MailboxLinkStatus?) throws(SetupFailure) {
    switch link {
    case .noLink?, .holder(true, _)?: return
    case .holder(false, _)?: throw .failed("Your email is read on your other iPhone.")
    case nil: throw .failed(message(.offline))
    }
  }

  /// The banks whose alert senders are among the `trusted` domains (the bank step's ops).
  static func banks(trusted: [String]) -> [SupportedBank] {
    SupportedBank.allCases.filter { bank in
      MailboxLane.senderDomains(bank: bank.rawValue).contains { trusted.contains($0) }
    }
  }

  private func lane() throws(SetupFailure) -> MailboxLane {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Email isn't available in this build.") }
    return lane
  }

  func connectMailbox(_ provider: MailboxProvider, banks: [SupportedBank]) async throws(SetupFailure) {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lanes[provider] else { throw .failed("\(provider.name) isn't available in this build.") }
    let current = rt.lane
    let phase = await (current ?? lane).status().phase
    // The offer may be older than another iPhone's link: ask the server again first.
    if phase == .unlinked {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link)
    }
    // The tables hold the other provider's lane: the new link starts a fresh scan.
    let switching = current.map { $0.provider != provider } ?? false
    switch await lane.connect(backfillDays: 90, replacing: switching && phase != .unlinked) {
    case .connected:
      rt.activate(provider)
      // The server replaced the old link; end the old provider's grant here.
      if switching, let old = current { await old.endGrant() }
      // Home and Profile follow the lane's new phase.
      await rt.refreshMailbox()
    case .cancelled: throw .cancelled
    case .failed(let f): throw .failed(Self.message(f, provider: provider))
    }
  }

  func firstScan() -> AsyncStream<ScanProgress> {
    guard let lane = try? lane() else {
      return AsyncStream { c in
        c.yield(ScanProgress(phase: .failed("Your email isn't connected."), read: 0, total: 0))
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
        // Home and Profile stop saying "Importing" (it runs on after setup is left).
        await rt?.refreshMailbox()
        continuation.finish()
      }
    }
  }

  /// Where the first scan's foreground runs left it, with what they filed.
  static func ended(_ t: MailboxLane.FirstScanTotals, last: ScanProgress) -> ScanProgress {
    let summary = SortSummary(
      total: t.ops, byRules: t.byRules, byDictionary: t.byDictionary, byModel: t.byModel, toReview: t.toReview)
    switch t.phase {
    case .active:
      return ScanProgress(phase: .finished, read: last.total, total: last.total, summary: summary)
    case .halted, .reconnectRequired, .otherDevice:
      return ScanProgress(
        phase: .failed(stopped(t.haltedOn)), read: last.read, total: last.total, summary: summary)
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
    case .failed(let code): ScanProgress(phase: .failed(stopped(code)), read: p.done, total: p.total)
    }
  }

  /// Why the first scan stopped, in words.
  static func stopped(_ code: MailboxHaltCode?) -> String {
    code == .noMailbox ? message(.noMailbox) : "Reading your bank alerts stopped. Try again."
  }

  /// Plain-language copy for a failed connect (spec 04 §7.11; content-free).
  static func message(_ f: ConnectFailure, provider: MailboxProvider = .gmail) -> String {
    switch f {
    case .offline: "You're offline. Connect \(provider.name) when you're back online."
    case .permissionMissing: "Hasala needs permission to read your bank alerts. Try again and allow it."
    case .noMailbox: "This Microsoft account has no Outlook mailbox. Connect the account your bank alerts go to."
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .notConfigured: "\(provider.name) isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      provider == .outlook
        ? "Couldn't connect Outlook. Only personal Microsoft accounts work. Try again."
        : "Couldn't connect Gmail. Try again."
    }
  }
}
