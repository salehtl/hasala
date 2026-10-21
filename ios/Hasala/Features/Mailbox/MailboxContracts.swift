import Foundation
import HasalaModels

// The mailbox contract the screens use (Paper P2.9 "Connect your email"; plan B4.3): one
// account reads its bank alerts from one or more mailboxes, each with a provider. It is the
// app's own and provider-neutral: views never import CoreMailbox or use its
// `MailProviderID`; the live mapping to the mail lanes lives only in `Live/Mailbox/`. In
// copy, lists and settings say "mailbox"; steps and buttons say "your email".

/// What the bell, the Profile card and Bank alerts offer for mail.
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
  /// Another iPhone holds the account's link (live: "Your email is read on your other
  /// iPhone."; that iPhone may read a different provider than the one asked for).
  case takenByOtherIPhone
  case offline
  case noMailbox(MailProviderKind)
  case permissionMissing(MailProviderKind)
  case switchDeclined
  /// Anything else, with its content-free copy.
  case failed(String)

  /// The line a screen shows for a connect to `provider`; nil when nothing is shown (a
  /// sign-in the person closed is not an error).
  func message(for provider: MailProviderKind) -> String? {
    switch self {
    case .cancelled, .switchDeclined: nil
    case .adminApprovalNeeded: "Your organisation needs to approve Hasala."
    case .alreadyConnected(let address): "\(address) is already connected."
    case .takenByOtherIPhone: "Your email is read on your other iPhone."
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .noMailbox(let account): Self.noMailboxLine(account)
    case .permissionMissing(let account): Self.permissionMissingLine(account)
    case .failed(let message): message
    }
  }

  static func permissionMissingLine(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail: "Hasala needs \u{201C}Read your email\u{201D} ticked. Try again and tick it."
    case .outlook: "Hasala needs permission to read your bank alerts. Try again and allow it."
    }
  }

  static func noMailboxLine(_ provider: MailProviderKind) -> String {
    switch provider {
    case .outlook:
      "This Microsoft account has no Outlook mailbox. Sign in with the account your bank alerts go to, such as you@outlook.com or you@hotmail.com."
    case .gmail:
      "This Google account has no Gmail. Sign in with the account your bank alerts go to."
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
  /// Without `.addSecond`: connecting another provider while a mailbox is linked replaces
  /// that link, once the person confirms it ("Change your email?"). Live holds one link
  /// per account, and the server swaps it in one step.
  static let replace = MailboxCapabilities(rawValue: 1 << 4)
  static let tryAgain = MailboxCapabilities(rawValue: 1 << 5)

  static let all: MailboxCapabilities = [.connect, .signInAgain, .disconnect, .addSecond, .tryAgain]
}

/// The mailboxes, their connect and the first scan, implemented by the live mail lane and
/// by the mock (`MockMailbox`).
@MainActor
protocol MailboxConnecting: AnyObject, Observable {
  /// The providers this build can connect, in the order the chooser lists them. A
  /// provider not listed is never shown (live: the providers the build has a client id
  /// for, Gmail first).
  var connectable: [MailProviderKind] { get }
  var capabilities: MailboxCapabilities { get }
  /// Every mailbox the account reads, observed (live: from the lane's status). Nothing
  /// here is sent to the server.
  var mailboxes: [MailboxSnapshot] { get }
  /// Whether `mailboxes` is known yet: false while the account's mailbox state is still
  /// being read (live: before the lane's first status), so screens show that they are
  /// checking rather than "not connected".
  var mailboxesKnown: Bool { get }
  /// What the bell, the Profile card and Bank alerts offer; nil when nothing needs doing,
  /// the lane's state isn't known yet, or the account loaded the App Review sample.
  var offer: MailOffer? { get }
  var connectRefused: Bool { get }
  /// The banks the account reads (its sender-trust ops).
  func chosenBanks() -> [SupportedBank]
  /// The provider the account's link is to, while there is one, known before the mailbox
  /// rows are (live: remembered on this iPhone, read before the lane's status is). Nil
  /// with no link.
  var linkedProvider: MailProviderKind? { get }
  /// The provider of the account's link while another iPhone holds it and this one reads
  /// nothing (live: a new install or a recovered account). A connect here then takes the
  /// link over, once the person confirmed it. Nil otherwise.
  var heldElsewhere: MailProviderKind? { get }
  /// The lane's state, as setup's facts name it.
  func linkState() async -> OnboardingStep.Facts.Mailbox
  /// Runs `provider`'s sign-in (read-only), the `mailbox.link` step-up and the first
  /// listing. Returns the new mailbox's id. With `.replace`, a link to another provider is
  /// replaced only when `replacing` says the person confirmed it; otherwise that connect
  /// fails and the link stays. While the link is `heldElsewhere`, `replacing` says the
  /// person confirmed taking it over.
  func connect(_ provider: MailProviderKind, replacing: Bool, removingOld: Bool, ask: @escaping MailSwitchAsk)
    async throws(MailConnectFailure) -> MailLinked
  /// A new sign-in for a mailbox whose provider ended Hasala's access.
  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked
  func tryAgain(_ mailboxID: String) async
  /// Stops reading the mailbox and forgets its sign-in.
  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure)
  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact?
  /// The first scan's progress: it reads the window and files what it finds, then ends
  /// with `.finished`, `.background` (it goes on later) or `.failed`, with the summary.
  func firstScan() -> AsyncStream<ScanProgress>
  var importing: MailImport? { get }
  /// Review accounts only (spec 04 §6.13): loads the synthetic sample instead of mail.
  var offersSampleData: Bool { get }
  func loadSampleData() async throws(SetupFailure)
}

struct MailboxDisconnectImpact: Equatable, Sendable {
  var transactions: Int
  var edited: Int
}

struct MailSwitchQuestion: Equatable, Sendable {
  var provider: MailProviderKind
  var oldAddress: String
  var newAddress: String
  var impact: MailboxDisconnectImpact?
  var oldHasNoMailbox = false
  var countUnknown = false

  var offersRemove: Bool { impact != nil || countUnknown }
}

enum MailSwitchChoice: Equatable, Sendable {
  case keep, remove, cancel
}

typealias MailSwitchAsk = @MainActor @Sendable (MailSwitchQuestion) async -> MailSwitchChoice

enum MailSwitchRemoval: Equatable, Sendable {
  case removed(Int?)
  case failed(from: String)
}

struct MailLinked: Equatable, Sendable {
  var mailboxID: String
  var nowReading: String?
  var removal: MailSwitchRemoval?

  init(mailboxID: String, nowReading: String? = nil, removal: MailSwitchRemoval? = nil) {
    self.mailboxID = mailboxID
    self.nowReading = nowReading
    self.removal = removal
  }
}

struct MailImport: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case reading
    case paused
    case offline
    case stopped(String)
  }

  var state: State
  var read: Int
  var total: Int

  var label: String {
    switch state {
    case .reading: "Reading your alerts"
    case .paused: "Reading paused"
    case .offline: "Offline"
    case .stopped(let message): message
    }
  }

  var count: String? {
    guard state != .offline, total > 0 else { return nil }
    if case .stopped = state { return nil }
    return "\(min(read, total)) of \(total)"
  }

  var busy: Bool { state == .reading }

  var opensBankAlerts: Bool {
    if case .stopped = state { return true }
    return false
  }
}

extension MailboxConnecting {
  var importing: MailImport? { nil }

  func disconnect(_ mailboxID: String) async throws(MailConnectFailure) {
    try await disconnect(mailboxID, removeTransactions: false)
  }

  /// Known at once where the mailboxes are held in memory (the mock).
  var mailboxesKnown: Bool { true }

  /// No other iPhone where the mailboxes are held in memory (the mock).
  var heldElsewhere: MailProviderKind? { nil }

  var connectRefused: Bool { false }

  /// A connect that replaces nothing: a first link, another mailbox beside one that works,
  /// or the same provider again.
  @discardableResult
  func connect(_ provider: MailProviderKind) async throws(MailConnectFailure) -> String {
    try await connect(provider, replacing: false)
  }

  @discardableResult
  func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
    try await connect(provider, replacing: replacing, removingOld: false, ask: { _ in .cancel }).mailboxID
  }

  @discardableResult
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) -> MailLinked {
    try await signInAgain(mailboxID, ask: { _ in .cancel })
  }

  /// Whether this build holds one mailbox at a time, so a connect of another provider
  /// replaces the link (live, and the Release surface).
  var holdsOneLink: Bool { capabilities.contains(.replace) && !capabilities.contains(.addSecond) }

  /// The mailbox a connect of `provider` would replace, after a confirmation: with one link
  /// held, the account's linked mailbox when it is another provider's.
  func replaced(by provider: MailProviderKind) -> MailboxSnapshot? {
    guard holdsOneLink else { return nil }
    // A mailbox read on another iPhone can't be replaced from here (the connect is refused).
    return mailboxes.first { $0.state != .disconnected && !$0.readElsewhere && $0.provider != provider }
  }
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

  /// `known`: false while the mailbox state is still being read, which says so rather
  /// than "not connected".
  init(_ mailboxes: [MailboxSnapshot], health: MailboxHealth, offer: MailOffer?, known: Bool = true) {
    let live = mailboxes.filter { $0.state != .disconnected }
    let broken = live.first { $0.state == .needsSignIn }
    if !known {
      self.init(title: "Checking your email", detail: "Reading your mailbox's state.", hue: .sky, needsYou: false)
    } else if broken != nil || offer?.isSignInAgain == true {
      // "Microsoft ended access to maya@example.net on Wed. Your Gmail still works."
      let working = live.filter { $0.state == .connected || $0.state == .syncing }
      // A note says what a new sign-in fixes when it isn't the provider ending access (live:
      // a Microsoft account with no Outlook mailbox).
      var detail = broken.map { $0.note ?? "\($0.provider.company) ended access to \($0.address)." }
        ?? "Your email provider ended Hasala's access."
      if let other = working.first { detail += " Your \(other.provider.appName) still works." }
      self.init(title: "Sign in again", detail: detail, hue: .sand, needsYou: true)
    } else if live.isEmpty {
      self.init(
        title: "Your email isn't connected", detail: "Connect it so Hasala can read your bank alerts.", hue: .sky,
        needsYou: offer == .connect)
    } else if health.status == .reconnect {
      // The lane halted for a reason a new sign-in doesn't fix (a full account, missing
      // templates): its row still reads connected, but nothing is being read.
      let stopped = live.first { $0.note != nil } ?? live[0]
      let working = live.filter { $0.id != stopped.id && ($0.state == .connected || $0.state == .syncing) }
      var detail = "Hasala stopped reading \(stopped.address)."
      if let other = working.first { detail += " Your \(other.provider.appName) still works." }
      self.init(title: "Bank alerts stopped", detail: detail, hue: .sand, needsYou: true)
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
