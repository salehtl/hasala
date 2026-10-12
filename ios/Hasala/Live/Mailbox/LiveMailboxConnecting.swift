import CoreMailbox
import Foundation
import Observation

/// Setup's Gmail step over the open account (spec 04 §7.4, §7.7): "Connect Gmail" runs
/// the Gmail lane's connect (Google sign-in, token custody, the `mailbox.link` step-up),
/// the first scan streams its progress, and the cards found become `card_linked` ops.
/// On a review account with an empty ledger the step offers "Use sample data" instead
/// (§6.13), which loads the bundled seed through the outbox.
@MainActor
@Observable
final class LiveMailboxConnecting: MailboxConnecting {
  @ObservationIgnored private let runtime: @MainActor () -> AccountRuntime?

  init(runtime: @escaping @MainActor () -> AccountRuntime?) {
    self.runtime = runtime
  }

  /// Observed through the runtime: the review flag arrives with `GET /account`.
  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  private func lane() throws(SetupFailure) -> GmailLane {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Gmail isn't available in this build.") }
    return lane
  }

  func connectGmail(banks: [SupportedBank]) async throws(SetupFailure) {
    let lane = try lane()
    switch await lane.connect(backfillDays: 90) {
    case .connected: return
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
    let store = runtime()?.store
    return AsyncStream { continuation in
      let job = Task {
        var last = ScanProgress(phase: .downloading, read: 0, total: 0)
        for await p in lane.firstScan() {
          last = Self.progress(p)
          continuation.yield(last)
        }
        let summary = await lane.discoveredCards()
        switch summary.phase {
        case .awaitingCards:
          continuation.yield(ScanProgress(phase: .awaitingCards, read: last.total, total: last.total))
        case .active, .authoringBackfill:
          continuation.yield(ScanProgress(phase: .finished, read: last.total, total: last.total))
        case .halted, .reconnectRequired:
          continuation.yield(ScanProgress(phase: .failed("Reading your bank alerts stopped. Try again."), read: last.read, total: last.total))
        default:
          // Nothing to read yet (no alerts, or offline): the board waits for the cards.
          continuation.yield(ScanProgress(phase: .awaitingCards, read: last.total, total: last.total))
        }
        await store?.reload()
        continuation.finish()
      }
      continuation.onTermination = { _ in job.cancel() }
    }
  }

  func discoveredCards() async -> [DiscoveredCard] {
    guard let lane = try? lane() else { return [] }
    return await lane.discoveredCards().cards.compactMap { c in
      guard let bank = SupportedBank(rawValue: c.card.bank) else { return nil }
      return DiscoveredCard(id: "\(c.card.bank)-\(c.card.last4)", bank: bank, last4: c.card.last4, alertCount: c.count, keep: true)
    }
  }

  func confirmCards(_ cards: [DiscoveredCard]) async throws(SetupFailure) -> SortSummary {
    let lane = try lane()
    let decisions = cards.map {
      CardDecision(card: CardKey(bank: $0.bank.rawValue, last4: $0.last4), state: $0.keep ? .mine : .notMine)
    }
    let report = await lane.confirmCards(decisions)
    await runtime()?.store.reload()
    if report.haltedOn == .offline { throw .offline }
    let rules = report.sortedBy["rule"] ?? 0
    let dictionary = report.sortedBy["dictionary"] ?? 0
    let model = report.sortedBy["model"] ?? 0
    return SortSummary(total: report.ops, byRules: rules, byDictionary: dictionary, byModel: model, toReview: report.review)
  }

  func loadSampleData() async throws(SetupFailure) {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    try await rt.loadSample()
  }

  static func progress(_ p: MailboxProgress) -> ScanProgress {
    switch p.stage {
    case .listing, .downloading: ScanProgress(phase: .downloading, read: p.done, total: p.total)
    case .authoring: ScanProgress(phase: .sorting, read: p.done, total: p.total)
    case .awaitingCards: ScanProgress(phase: .awaitingCards, read: p.total, total: p.total)
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
