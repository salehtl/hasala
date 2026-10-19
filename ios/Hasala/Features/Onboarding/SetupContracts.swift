import Foundation

// The setup steps after the account (spec 04 §6.6, Paper row 10): bank → your email (read
// only) → first scan → income → starting plan → result → notifications → done. There is no
// cards step: the scan files what it reads, and it carries on in the background if setup
// ends first. The mail lane implements `MailboxConnecting` (Features/Mailbox); the
// op-authoring lane implements `SetupAuthoring` over OpAuthor + Outbox (§6.6 "When ops are
// authored").

/// The banks the beta reads (spec 04 §6.6 step 3).
enum SupportedBank: String, CaseIterable, Identifiable, Sendable {
  case enbd
  case dib
  case adib

  var id: String { rawValue }

  var name: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "Dubai Islamic Bank"
    case .adib: "Abu Dhabi Islamic Bank"
    }
  }

  var shortName: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "DIB"
    case .adib: "ADIB"
    }
  }

  var monogram: String {
    switch self {
    case .enbd: "ENBD"
    case .dib: "DIB"
    case .adib: "ADIB"
    }
  }

  var note: String? {
    switch self {
    case .enbd: nil
    case .dib: "Arabic alerts supported"
    case .adib: nil
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
    /// The whole window is read and filed.
    case finished
    /// The foreground run stopped first (no trusted sender yet, offline, or the run limit);
    /// the import carries on in the background.
    case background
    case failed(String)
  }

  var phase: Phase
  var read: Int
  var total: Int
  /// How what was filed so far was sorted (with `.finished` and `.background`).
  var summary: SortSummary?

  var isRunning: Bool { phase == .downloading || phase == .sorting }
  var fraction: Double { total == 0 ? 0 : min(1, Double(read) / Double(total)) }
}

/// How the scan sorted the transactions (Paper "264 transactions, sorted.").
struct SortSummary: Equatable, Sendable {
  var total: Int
  var byRules: Int
  var byDictionary: Int
  var byModel: Int
  var toReview: Int

  /// Filed with a category and nothing to check; the rest wait in Review.
  var sortedThemselves: Int { max(0, total - toReview) }
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

/// What the account already holds for setup's typed values (plan B3.3), read back after a
/// relaunch so the steps show them again. Nil where nothing was saved.
struct SetupReadBack: Equatable, Sendable {
  /// The salary, in fils.
  var incomeMinor: Int64?
  /// The salary's day of the month.
  var payday: Int?
  var split: StartingPlan?
}

/// The setup ops (spec 04 §6.6). Each call is one `Outbox.enqueue`.
@MainActor
protocol SetupAuthoring: AnyObject {
  /// What the account holds for income, payday and the split. Reads only.
  func readBack() -> SetupReadBack
  /// `sender_trust_set` for each bank's alert senders and `bank_declared`.
  func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure)
  func setBanks(_ banks: [SupportedBank]) async throws(SetupFailure)
  /// "Another bank? Tell us": a bank request to the operator (`07` P4). Content: the name only.
  func requestBank(_ name: String) async throws(SetupFailure)
  func requestBank(slug: String, senderDomain: String?) async throws(SetupFailure)
  func bankRequests() async throws(SetupFailure) -> BankRequestsSnapshot
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
