import Foundation

// The setup steps after the account (spec 04 §6.6, Paper row 10): bank → read-only Gmail →
// first scan → income → starting plan → your cards → result → notifications → done.
// The Gmail lane implements `MailboxConnecting` (spec 04 §7); the op-authoring lane
// implements `SetupAuthoring` over OpAuthor + Outbox (§6.6 "When ops are authored").

/// The banks the beta reads (spec 04 §6.6 step 3).
enum SupportedBank: String, CaseIterable, Identifiable, Sendable {
  case enbd
  case dib

  var id: String { rawValue }

  var name: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "Dubai Islamic Bank"
    }
  }

  var shortName: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "DIB"
    }
  }

  var monogram: String {
    switch self {
    case .enbd: "ENBD"
    case .dib: "DIB"
    }
  }

  var note: String? {
    switch self {
    case .enbd: nil
    case .dib: "Arabic alerts supported"
    }
  }
}

/// The first scan's progress (Paper "Reading your bank alerts, on this iPhone").
struct ScanProgress: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    /// Listing and downloading the banks' alerts.
    case downloading
    /// Parsing and sorting on device.
    case sorting
    /// Waiting for the user to confirm the cards found.
    case awaitingCards
    /// Done: cards confirmed and the backfill authored.
    case finished
    case failed(String)
  }

  var phase: Phase
  var read: Int
  var total: Int

  var isRunning: Bool { phase == .downloading || phase == .sorting }
  var fraction: Double { total == 0 ? 0 : min(1, Double(read) / Double(total)) }
}

/// A card found in the alerts, before the user confirms it (spec 04 §7.7, PO-16).
struct DiscoveredCard: Identifiable, Equatable, Sendable {
  var id: String
  var bank: SupportedBank
  /// The last four digits as the alerts show them (masked; never the full number).
  var last4: String
  var alertCount: Int
  var keep: Bool
}

/// How the scan sorted the transactions (Paper "264 transactions, sorted.").
struct ScanSummary: Equatable, Sendable {
  var total: Int
  var byRules: Int
  var byDictionary: Int
  var byModel: Int
  var toReview: Int

  var sortedThemselves: Int { byRules + byDictionary + byModel }
}

/// The Gmail link and first scan, implemented by the Gmail lane (spec 04 §7.4, §7.7).
@MainActor
protocol MailboxConnecting: AnyObject {
  /// Runs Google's sign-in (read-only scope), the `mailbox.link` step-up and the first
  /// listing for `banks`' senders. Throws `.cancelled` when the user closes Google's sheet.
  func connectGmail(banks: [SupportedBank]) async throws(SetupFailure)
  /// The first scan's progress; the stream ends when the scan reaches `.awaitingCards`
  /// or fails.
  func firstScan() -> AsyncStream<ScanProgress>
  /// The cards found so far (complete once the scan is `.awaitingCards`).
  func discoveredCards() async -> [DiscoveredCard]
  /// Authors `account_set` / `card_linked` for the kept cards and starts the backfill.
  func confirmCards(_ cards: [DiscoveredCard]) async throws(SetupFailure) -> ScanSummary
  /// Review accounts only (spec 04 §6.13): loads the synthetic sample instead of Gmail.
  var offersSampleData: Bool { get }
  func loadSampleData() async throws(SetupFailure)
}

/// The plan the starting-plan step proposes (50/30/20, `03a` §6.12).
struct StartingPlan: Equatable, Sendable {
  var needsPercent: Int = 50
  var wantsPercent: Int = 30
  var savingsPercent: Int = 20

  func amounts(income: Int64) -> (needs: Int64, wants: Int64, savings: Int64) {
    let needs = income * Int64(needsPercent) / 100
    let wants = income * Int64(wantsPercent) / 100
    return (needs, wants, income - needs - wants)
  }

  var isValid: Bool {
    needsPercent >= 0 && wantsPercent >= 0 && savingsPercent >= 0 && needsPercent + wantsPercent + savingsPercent == 100
  }
}

/// The setup ops (spec 04 §6.6). Each call is one `Outbox.enqueue`.
@MainActor
protocol SetupAuthoring: AnyObject {
  /// `sender_trust_set` for each bank's alert senders and `bank_declared`.
  func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure)
  /// "Another bank? Tell us": a bank request to the operator (`07` P4). Content: the name only.
  func requestBank(_ name: String) async throws(SetupFailure)
  /// The income (`income_source_set`) and plan (`budget_split_set`, `budget_set`) in one
  /// enqueue; `income` nil when skipped, `plan` nil when skipped.
  func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure)
}

/// Notification permission (spec 04 §9.3). Notifications are generic by default (PO-7).
@MainActor
protocol NotificationPermissionAsking: AnyObject {
  /// Asks iOS; returns whether the user allowed.
  func requestAuthorization() async -> Bool
  /// "Show amounts and merchants" on the Lock Screen (off by default).
  var showsDetails: Bool { get set }
}

enum SetupFailure: Error, Equatable, Sendable {
  case cancelled
  case offline
  case failed(String)

  var message: String? {
    switch self {
    case .cancelled: nil
    case .offline: "Can't finish setup offline. Try again when you're connected."
    case .failed(let s): s
    }
  }
}
