import Foundation

// The setup steps after the account (spec 04 §6.6, Paper row 10): bank → read-only email →
// first scan → income → starting plan → result → notifications → done. There is no cards
// step: the scan files what it reads, and it carries on in the background if setup ends first.
// The mailbox lanes implement `MailboxConnecting` (spec 04 §7); the op-authoring lane
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

/// The mailboxes Hasala reads bank alerts from (one at a time per account). The raw values
/// are the provider ids of the wire and the database.
nonisolated enum MailboxProvider: String, CaseIterable, Identifiable, Sendable {
  case gmail
  case outlook

  var id: String { rawValue }

  var name: String {
    switch self {
    case .gmail: "Gmail"
    case .outlook: "Outlook"
    }
  }
}

/// What Home and Profile offer for the mailbox once setup is done: "Connect your email" when
/// the step was skipped (spec 04 §6.6 row 4), "Reconnect Gmail" (or Outlook) when the
/// provider wants a new sign-in or the lane stopped (§7.4), and, from Profile only, a change
/// of provider while the link works.
nonisolated enum MailboxOffer: Hashable, Identifiable, Sendable {
  case connect
  case reconnect(MailboxProvider)
  case change(MailboxProvider)

  var id: String {
    switch self {
    case .connect: "mailbox.connect"
    case .reconnect(let p): "mailbox.reconnect.\(p.rawValue)"
    case .change(let p): "mailbox.change.\(p.rawValue)"
    }
  }

  /// The provider the account is linked to now, if any.
  var current: MailboxProvider? {
    switch self {
    case .connect: nil
    case .reconnect(let p), .change(let p): p
    }
  }

  /// The action's title.
  var action: String {
    switch self {
    case .connect: "Connect your email"
    case .reconnect(let p): "Reconnect \(p.name)"
    case .change: "Use another email"
    }
  }

  /// What the Profile card says.
  var status: String {
    switch self {
    case .connect: "Email isn't connected"
    case .reconnect(let p): "\(p.name) needs reconnecting"
    case .change(let p): "\(p.name) is connected"
    }
  }
}

/// The mailbox link and first scan, implemented by the mailbox lanes (spec 04 §7.4, §7.7).
@MainActor
protocol MailboxConnecting: AnyObject {
  /// Home's Needs-you card and the Profile card's action, once setup is done; nil when
  /// the mailbox works, the lane's state isn't known yet, the build connects no mailbox, or
  /// the account loaded the App Review sample (§6.13, which completes the mailbox step).
  var mailboxOffer: MailboxOffer? { get }
  /// The provider the account's link is with on this iPhone; nil before any link.
  var linkedProvider: MailboxProvider? { get }
  /// The providers this build can connect, Gmail first. Outlook only once its client is
  /// configured (`HASALA_OUTLOOK_CLIENT_ID`).
  var providers: [MailboxProvider] { get }
  /// Why the lane stopped, in words, when the user must act on something a reconnect alone
  /// doesn't fix (a Microsoft account with no Outlook mailbox); nil otherwise.
  var haltMessage: String? { get }
  /// The banks the account reads (its sender-trust ops), for a connect after setup.
  func chosenBanks() -> [SupportedBank]
  /// The lane's state, as setup's facts name it.
  func linkState() async -> OnboardingStep.Facts.Mailbox
  /// Runs `provider`'s sign-in (read-only mail scope), the `mailbox.link` step-up and the
  /// first listing for `banks`' senders. Linking one provider replaces the account's link to
  /// the other. Throws `.cancelled` when the user closes the provider's sheet.
  func connectMailbox(_ provider: MailboxProvider, banks: [SupportedBank]) async throws(SetupFailure)
  /// The first scan's progress: it reads the window and files what it finds, then ends
  /// with `.finished`, `.background` (it goes on later) or `.failed`, with the summary.
  func firstScan() -> AsyncStream<ScanProgress>
  /// Review accounts only (spec 04 §6.13): loads the synthetic sample instead of a mailbox.
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
