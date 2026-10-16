import CoreMailbox
import Foundation
import Observation

/// Setup's Gmail step over the open account (spec 04 §7.4, §7.7): "Connect Gmail" runs
/// the Gmail lane's connect (Google sign-in, token custody, the `mailbox.link` step-up),
/// and the first scan streams its progress while it files what it reads (no cards step).
/// On a review account with an empty ledger the step offers "Use sample data" instead
/// (§6.13), which loads the bundled seed through the outbox. Home and Profile run the same
/// connect after setup, when `gmailOffer` says Gmail needs it.
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
  var gmailOffer: GmailOffer? { runtime()?.gmailOffer }

  func chosenBanks() -> [SupportedBank] {
    guard let rt = runtime() else { return [] }
    return Self.banks(trusted: BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:]))
  }

  func linkState() async -> OnboardingStep.Facts.Mailbox {
    guard let lane = runtime()?.lane else { return .unlinked }
    return BootController.mailboxFact(await lane.status().phase)
  }

  /// What Home and Profile offer for a lane `phase` (spec 04 §6.6 row 4, §7.4). Nothing
  /// once the account holds the App Review sample: loading it completed the Gmail step.
  /// An iPhone without a link offers it only once the server says no other iPhone holds
  /// one (`serverLink`): connecting there would take Gmail over from that iPhone. A halt
  /// is offered a reconnect only when signing in to Google again fixes it (`halt`).
  static func offer(
    phase: MailboxPhase, halt: MailboxHaltCode? = nil, sampleLoaded: Bool, serverLink: MailboxLinkStatus?
  ) -> GmailOffer? {
    guard !sampleLoaded else { return nil }
    switch phase {
    case .unlinked:
      switch serverLink {
      case .noLink?, .holder(true, _)?: return .connect
      case .holder(false, _)?, nil: return nil
      }
    case .reconnectRequired: return .reconnect
    case .halted:
      // A full account or missing templates aren't fixed by a new Google sign-in.
      switch halt {
      case nil, .gmail?, .reconnectRequired?: return .reconnect
      default: return nil
      }
    // The first import runs on its own (Profile and Home say "Importing").
    case .scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice: return nil
    }
  }

  /// Before a connect from an iPhone without a link, the server's answer asked just now:
  /// another iPhone holding the link refuses it (connecting would take Gmail over from
  /// that iPhone), and so does no answer (`nil`, offline), as Home shows no offer then.
  static func checkTakeover(_ link: MailboxLinkStatus?) throws(SetupFailure) {
    switch link {
    case .noLink?, .holder(true, _)?: return
    case .holder(false, _)?: throw .failed("Gmail is read on your other iPhone.")
    case nil: throw .failed(message(.offline))
    }
  }

  /// The banks whose alert senders are among the `trusted` domains (the bank step's ops).
  static func banks(trusted: [String]) -> [SupportedBank] {
    SupportedBank.allCases.filter { bank in
      GmailLane.senderDomains(bank: bank.rawValue).contains { trusted.contains($0) }
    }
  }

  private func lane() throws(SetupFailure) -> GmailLane {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Gmail isn't available in this build.") }
    return lane
  }

  func connectGmail(banks: [SupportedBank]) async throws(SetupFailure) {
    let lane = try lane()
    // The offer may be older than another iPhone's link: ask the server again first.
    if await lane.status().phase == .unlinked, let rt = runtime() {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link)
    }
    switch await lane.connect(backfillDays: 90) {
    case .connected:
      // Home and Profile follow the lane's new phase.
      await runtime()?.refreshMailbox()
    case .cancelled: throw .cancelled
    case .failed(let f): throw .failed(Self.message(f))
    }
  }

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
        // Home and Profile stop saying "Importing" (it runs on after setup is left).
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
    case .noMailbox: "This Microsoft account has no Outlook mailbox. Connect the account your bank alerts go to."
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .notConfigured: "Gmail isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      "Couldn't connect Gmail. Try again."
    }
  }
}
