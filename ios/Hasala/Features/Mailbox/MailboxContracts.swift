import Foundation
import HasalaModels

// The mailbox contract the screens use (Paper P2.9 "Connect your email"; plan B4.3): one
// account reads its bank alerts from one or more mailboxes, each with a provider. It is the
// app's own and provider-neutral: views never import CoreMailbox or use its
// `MailProviderID`; the live mapping to the Gmail lane lives only in `Live/Mailbox/`. In
// copy, lists and settings say "mailbox"; steps and buttons say "your email".

/// What Home's bell, the Profile card and Bank alerts offer for mail.
enum MailOffer: Hashable, Identifiable {
  /// No mailbox is read: setup's email step was skipped, or the last one went.
  case connect
  /// A provider ended Hasala's access to this mailbox; a new sign-in fixes it.
  case signInAgain(mailboxID: String, provider: MailProviderKind)

  var id: String {
    switch self {
    case .connect: "connect"
    case .signInAgain(let mailboxID, _): "signIn.\(mailboxID)"
    }
  }
}

/// Why a connect, a sign-in again or a disconnect didn't happen (Paper "Connect email ·
/// Work or school account needs an admin", "Microsoft sign-in didn't finish").
enum MailConnectFailure: Error, Equatable {
  /// The person closed the provider's sign-in, or declined its permissions.
  case cancelled
  /// A work or school account whose admin hasn't approved Hasala.
  case adminApprovalNeeded(address: String)
  /// That mailbox is already read here.
  case alreadyConnected(address: String)
  /// Another iPhone holds the account's link (live: "Gmail is read on your other iPhone.").
  case takenByOtherIPhone
  case offline
  /// Anything else, with its content-free copy.
  case failed(String)

  /// The line a screen shows for a connect to `provider`; nil when nothing is shown (a
  /// sign-in the person closed is not an error).
  func message(for provider: MailProviderKind) -> String? {
    switch self {
    case .cancelled: nil
    case .adminApprovalNeeded: "Your organisation needs to approve Hasala."
    case .alreadyConnected(let address): "\(address) is already connected."
    case .takenByOtherIPhone: "\(provider.appName) is read on your other iPhone."
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .failed(let message): message
    }
  }
}

/// What this build can do with mailboxes (the Release gate beside `connectable`).
struct MailboxCapabilities: OptionSet, Sendable {
  let rawValue: Int

  static let connect = MailboxCapabilities(rawValue: 1 << 0)
  static let signInAgain = MailboxCapabilities(rawValue: 1 << 1)
  static let disconnect = MailboxCapabilities(rawValue: 1 << 2)
  /// A second mailbox beside one that works ("Add a mailbox"). The live server holds one
  /// link per account, so live never offers it.
  static let addSecond = MailboxCapabilities(rawValue: 1 << 3)

  static let all: MailboxCapabilities = [.connect, .signInAgain, .disconnect, .addSecond]
}

/// The mailboxes, their connect and the first scan, implemented by the live mail lane and
/// by the mock (`MockMailbox`).
@MainActor
protocol MailboxConnecting: AnyObject, Observable {
  /// The providers this build can connect, in the order the chooser lists them. A
  /// provider not listed is never shown (live: Gmail only, plan B4.6).
  var connectable: [MailProviderKind] { get }
  var capabilities: MailboxCapabilities { get }
  /// Every mailbox the account reads, observed (live: from the lane's status). Nothing
  /// here is sent to the server.
  var mailboxes: [MailboxSnapshot] { get }
  /// What the bell, the Profile card and Bank alerts offer; nil when nothing needs doing,
  /// the lane's state isn't known yet, or the account loaded the App Review sample.
  var offer: MailOffer? { get }
  /// The banks the account reads (its sender-trust ops).
  func chosenBanks() -> [SupportedBank]
  /// The lane's state, as setup's facts name it.
  func linkState() async -> OnboardingStep.Facts.Mailbox
  /// Runs `provider`'s sign-in (read-only), the `mailbox.link` step-up and the first
  /// listing. Returns the new mailbox's id.
  @discardableResult
  func connect(_ provider: MailProviderKind) async throws(MailConnectFailure) -> String
  /// A new sign-in for a mailbox whose provider ended Hasala's access.
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure)
  /// Stops reading the mailbox and forgets its sign-in. Past transactions stay.
  func disconnect(_ mailboxID: String) async throws(MailConnectFailure)
  /// The first scan's progress: it reads the window and files what it finds, then ends
  /// with `.finished`, `.background` (it goes on later) or `.failed`, with the summary.
  func firstScan() -> AsyncStream<ScanProgress>
  /// Review accounts only (spec 04 §6.13): loads the synthetic sample instead of mail.
  var offersSampleData: Bool { get }
  func loadSampleData() async throws(SetupFailure)
}

/// The one summary every surface draws from: the Profile card, Bank alerts' hero and the
/// bell's mail row (Paper "Bank alerts · Working", "Needs you", "Sign in again").
struct MailboxesSummary: Equatable {
  var title: String
  /// One or two lines under the title.
  var detail: String
  var hue: Hue
  /// Something the person has to do (the bell counts it).
  var needsYou: Bool

  init(_ mailboxes: [MailboxSnapshot], health: MailboxHealth, offer: MailOffer?) {
    let live = mailboxes.filter { $0.state != .disconnected }
    let broken = live.first { $0.state == .needsSignIn }
    if broken != nil || offer?.isSignInAgain == true {
      // "Microsoft ended access to maya@example.net on Wed. Your Gmail still works."
      let working = live.filter { $0.state == .connected || $0.state == .syncing }
      var detail = broken.map { "\($0.provider.company) ended access to \($0.address)." }
        ?? "Your email provider ended Hasala's access."
      if let other = working.first { detail += " Your \(other.provider.appName) still works." }
      self.init(title: "Sign in again", detail: detail, hue: .sand, needsYou: true)
    } else if live.isEmpty {
      self.init(
        title: "Your email isn't connected", detail: "Connect it so Hasala can read your bank alerts.", hue: .sky,
        needsYou: offer == .connect)
    } else if live.allSatisfy({ $0.state == .syncing }) || health.status == .importing {
      self.init(title: "Importing your bank alerts", detail: Self.lines(health) ?? "Checking now", hue: .mint,
                needsYou: false)
    } else if health.status == .quiet {
      self.init(title: "Bank alerts went quiet", detail: Self.lines(health) ?? "", hue: .sand, needsYou: true)
    } else {
      self.init(title: "Bank alerts are working", detail: Self.lines(health) ?? live[0].meta, hue: .mint,
                needsYou: false)
    }
  }

  init(title: String, detail: String, hue: Hue, needsYou: Bool) {
    self.title = title
    self.detail = detail
    self.hue = hue
    self.needsYou = needsYou
  }

  /// "Last email 4 min ago" over "Emirates NBD and DIB", when the lane has read them.
  private static func lines(_ health: MailboxHealth) -> String? {
    let lines = [health.lastEmail.isEmpty ? nil : "Last email \(health.lastEmail)", health.banks.isEmpty ? nil : health.banks]
      .compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}

extension MailOffer {
  var isSignInAgain: Bool {
    if case .signInAgain = self { return true }
    return false
  }
}
