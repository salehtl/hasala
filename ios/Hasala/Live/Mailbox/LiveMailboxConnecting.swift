import CoreMailbox
import CoreTime
import Foundation
import HasalaModels
import Observation

/// The mailbox contract over the open account's mail lanes (spec 04 §7.4, §7.7; plan
/// B4.4), a thin adapter over main's `AccountRuntime.lanes` / `MailboxLane`: "Continue with
/// Google" or "Continue with Microsoft" runs that lane's connect (the provider's sign-in,
/// token custody, the `mailbox.link` step-up), and the first scan streams its progress
/// while it files what it reads (no cards step). On a review account with an empty ledger
/// setup offers "Use sample data" instead (§6.13), which loads the bundled seed through the
/// outbox.
///
/// The build connects the providers it has a client id for (Gmail, and Outlook for
/// personal Microsoft accounts). The server holds one link per account, so there is no
/// second mailbox: connecting the other provider replaces the link, and only once the
/// person confirmed it (`connect(_:replacing:)`). The lane's status gives the one row.
@MainActor
@Observable
final class LiveMailboxConnecting: MailboxConnecting, BankAlertsReporting {
  @ObservationIgnored private let runtime: @MainActor () -> AccountRuntime?
  /// The providers this build has a client for, listed before an account opens ("Who can
  /// see what" and the stories run before any runtime exists).
  @ObservationIgnored private let buildProviders: [MailProviderKind]

  init(runtime: @escaping @MainActor () -> AccountRuntime?, buildProviders: [MailProviderKind] = []) {
    self.runtime = runtime
    self.buildProviders = buildProviders
  }

  /// The providers `build` has a client for, Gmail first: the same test as
  /// `MailboxLane.init?`, so it lists what an opened runtime's lanes will.
  static func providers(build: BuildInfo) -> [MailProviderKind] {
    MailProviderKind.allCases.filter { provider in
      switch provider {
      case .gmail:
        GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme).isConfigured
      case .outlook:
        MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme).isConfigured
      }
    }
  }

  /// The live mailbox's id: the provider of the one link ("gmail" or "outlook").
  static func mailboxID(_ provider: MailProviderKind) -> String { provider.rawValue }

  /// The providers this build has a client for (the runtime built their lanes), Gmail
  /// first: the Release gate is the build's client ids (`HASALA_OUTLOOK_CLIENT_ID`).
  var connectable: [MailProviderKind] { runtime()?.providers ?? buildProviders }

  /// No `.addSecond`: the server holds one link per account. `.replace`: linking the other
  /// provider replaces it, after the screens' confirmation ("Change your email?").
  ///
  /// `.disconnect` is the one live mailbox action no test reaches (the step-up, Google's
  /// revoke and the server's link delete; plan D.1 risk 8). It ships only after one run on
  /// QA with the owner, with a passkey account and with a password-only one; if either
  /// fails, take `.disconnect` out of this set and the button goes from every surface.
  var capabilities: MailboxCapabilities { [.connect, .signInAgain, .disconnect, .replace] }

  /// The provider of the account's link, known from this iPhone's memory (or the grant it
  /// holds) before the lane's status is read; nil once the status says unlinked.
  var linkedProvider: MailProviderKind? {
    guard let rt = runtime(), rt.store.mailboxPhase != .unlinked else { return nil }
    return rt.activeProvider
  }

  /// Observed through the runtime: the lane's status is read when the account opens and
  /// after every run and connect.
  var mailboxes: [MailboxSnapshot] {
    guard let rt = runtime(), let status = rt.store.mailboxStatus else { return [] }
    return Self.mailboxes(
      status, provider: rt.lane?.provider ?? .gmail, serverLink: rt.serverLink, nowMs: rt.context.clock.nowMs())
  }

  /// Known once the account is open and its lane's status was read (a build with no lane
  /// has none to read).
  var mailboxesKnown: Bool {
    guard let rt = runtime() else { return false }
    return rt.lane == nil || rt.store.mailboxStatus != nil
  }

  /// Observed through the runtime: the review flag arrives with `GET /account`.
  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  /// Observed through the runtime, like `mailboxes`.
  var offer: MailOffer? { runtime()?.mailOffer }

  var importing: MailImport? {
    guard let rt = runtime(), !rt.store.holdsSample else { return nil }
    return Self.importing(
      phase: rt.store.mailboxPhase, halt: rt.store.mailboxHalt, seen: rt.store.importSeen,
      progress: rt.store.importProgress)
  }

  static func importing(
    phase: MailboxPhase?, halt: MailboxHaltCode?, seen: Bool, progress: MailboxProgress?
  ) -> MailImport? {
    let read = progress?.done ?? 0
    let total = progress?.total ?? 0
    switch phase {
    case .scanning?, .awaitingCards?, .authoringBackfill?:
      if case .failed(.offline)? = progress?.stage { return MailImport(state: .offline, read: read, total: total) }
      return MailImport(state: .reading, read: read, total: total)
    case .halted?:
      guard seen else { return nil }
      return MailImport(state: .stopped(stopped(halt)), read: read, total: total)
    case .reconnectRequired?:
      guard seen else { return nil }
      return MailImport(state: .stopped("Sign in again"), read: read, total: total)
    case .active?, .unlinked?, .otherDevice?, nil:
      return nil
    }
  }

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
    let domains = MailboxLane.senderDomains(bank: bank.rawValue)
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
  static func mailboxes(
    _ s: MailboxStatus, provider: MailProviderKind = .gmail, serverLink: MailboxLinkStatus? = nil, nowMs: Int64
  ) -> [MailboxSnapshot] {
    mailboxes(phase: s.phase, halt: s.haltedOn, address: s.address, lastSuccessAtMs: s.lastSuccessAtMs,
              bankDomains: s.health.map(\.domain), provider: provider, serverLink: serverLink, nowMs: nowMs)
  }

  /// The row from the status's parts (the table in plan B4.4). The mailbox page's "Last
  /// checked" is the last good run on this iPhone's clock, at the ledger's local time
  /// (`LocalClock`, as every transaction time is).
  static func mailboxes(
    phase: MailboxPhase, halt: MailboxHaltCode?, address: String?, lastSuccessAtMs: Int64?, bankDomains: [String],
    provider: MailProviderKind = .gmail, serverLink: MailboxLinkStatus? = nil, nowMs: Int64,
    timeZone: TimeZone = localTimeZone
  ) -> [MailboxSnapshot] {
    let checked = lastSuccessAtMs.map { "Checked \(LedgerStateMapper.ago(nowMs - $0))" } ?? "Not checked yet"
    var row = MailboxSnapshot(
      id: mailboxID(provider), provider: provider, address: address ?? provider.appName, state: .connected, meta: checked,
      accountKind: provider == .outlook ? "Personal Microsoft" : nil,
      banks: Set(bankDomains.compactMap { LedgerStateMapper.bankName(domain: $0) }).sorted(),
      lastChecked: lastSuccessAtMs.map { checkedAt($0, timeZone: timeZone) })
    switch phase {
    case .unlinked:
      // This iPhone holds no link, but the server says another iPhone does (a new install,
      // or a recovered account, before this lane ever read the mailbox): the account's
      // mailbox is still listed, as read there, rather than no mailbox at all.
      guard case .holder(false, _)? = serverLink else { return [] }
      row.address = address ?? provider.appName
      row.meta = otherIPhone
      row.note = otherIPhone
      row.readElsewhere = true
    case .scanning, .awaitingCards:
      row.state = .syncing
      row.meta = "Checking now"
    case .authoringBackfill, .active:
      break
    case .reconnectRequired:
      row.state = .needsSignIn
    case .halted:
      if offer(phase: .halted, halt: halt, sampleLoaded: false, serverLink: .noLink, provider: provider) != nil {
        row.state = .needsSignIn
        // Not the provider ending access: the account has no mailbox to read.
        if halt == .noMailbox { row.note = message(.noMailbox) }
      } else {
        row.note = "Reading your bank alerts stopped."
      }
    case .otherDevice:
      row.note = otherIPhone
      // The server deletes the account's link whichever iPhone holds it, so this iPhone
      // offers no Disconnect and no switch.
      row.readElsewhere = true
    }
    return [row]
  }

  /// A mailbox row read on another iPhone.
  static let otherIPhone = "Read on your other iPhone"

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
  /// iPhone holds one (`serverLink`): connecting there would take the link over from that
  /// iPhone. A halt is offered a new sign-in only when signing in to the provider again
  /// fixes it (a Microsoft account with no mailbox: another account's sign-in).
  static func offer(
    phase: MailboxPhase, halt: MailboxHaltCode? = nil, sampleLoaded: Bool, serverLink: MailboxLinkStatus?,
    provider: MailProviderKind = .gmail
  ) -> MailOffer? {
    guard !sampleLoaded else { return nil }
    let signInAgain = MailOffer.signInAgain(mailboxID: mailboxID(provider), provider: provider)
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
      case nil, .gmail?, .reconnectRequired?, .noMailbox?: return signInAgain
      default: return nil
      }
    // The first import runs on its own (Profile says "Importing").
    case .scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice: return nil
    }
  }

  /// Before a connect from an iPhone without a link, the server's answer asked just now:
  /// another iPhone holding the link refuses it (connecting would take the link over from
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
      MailboxLane.senderDomains(bank: bank.rawValue).contains { trusted.contains($0) }
    }
  }

  // MARK: Connect, sign in again, disconnect

  private func lane() throws(MailConnectFailure) -> MailboxLane {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Email isn't available in this build.") }
    return lane
  }

  /// Whether `requested` may connect now, and whether that connect replaces the account's
  /// link (the server keeps one link per account). A working link, or a broken one of the
  /// other provider, is replaced only when the person confirmed it (`replacing`); the same
  /// provider again is a new sign-in when its link is broken and "already connected" when
  /// it works. The switch has no `default`, so a new `MailboxPhase` breaks the build.
  static func admit(
    _ requested: MailProviderKind, current: MailProviderKind?, phase: MailboxPhase, address: String?,
    replacing: Bool
  ) throws(MailConnectFailure) -> Bool {
    switch phase {
    case .unlinked:
      return false  // a first link, or after a disconnect
    case .otherDevice:
      throw .takenByOtherIPhone  // v2 has no "Read them here instead"
    case .reconnectRequired, .halted:
      if requested == current { return false }  // sign in again
    case .scanning, .awaitingCards, .authoringBackfill, .active:
      if requested == current { throw .alreadyConnected(address: address ?? requested.appName) }
    }
    guard replacing else {
      throw .failed("Disconnect \(current?.appName ?? "your email") first, then connect \(requested.appName).")
    }
    return true
  }

  /// Main's connect, behind `admit`: before a first link the server is asked whether
  /// another iPhone holds one; a confirmed switch replaces the other provider's link, and
  /// the new lane clears the shared tables only once its link is made; then the old lane
  /// ends its grant.
  @discardableResult
  func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lanes[provider] else { throw .failed("\(provider.appName) isn't available in this build.") }
    let current = rt.lane
    let status = await (current ?? lane).status()
    let replaces = try Self.admit(
      provider, current: current?.provider, phase: status.phase, address: status.address, replacing: replacing)
    if status.phase == .unlinked {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link)
    }
    let switching = current.map { $0.provider != provider } ?? false
    try Self.linked(await lane.connect(backfillDays: 90, replacing: replaces), provider: provider)
    rt.activate(provider)
    if switching, let old = current { await old.endGrant() }
    await rt.refreshMailbox()
    return Self.mailboxID(provider)
  }

  /// The same lane connect: the provider's sign-in and the step-up again, then the lane
  /// picks up where it stopped.
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) {
    let fallback = try lane().provider
    let provider = MailProviderKind(rawValue: mailboxID) ?? fallback
    try await connect(provider)
  }

  /// CoreMailbox's disconnect: the `mailbox.unlink` step-up, the watch or subscription
  /// stopped, the grant ended, the server's link deleted.
  func disconnect(_ mailboxID: String) async throws(MailConnectFailure) {
    let lane = try lane()
    // The server's delete has no holder check: from here it would end the other
    // iPhone's reading, and this iPhone holds no sign-in to delete.
    try Self.checkDisconnect(await lane.status().phase)
    guard await lane.disconnect() else { throw .failed("Couldn't disconnect \(lane.provider.appName). Try again.") }
    await runtime()?.refreshMailbox()
  }

  /// A disconnect from an iPhone that doesn't hold the link is refused, as `admit`
  /// refuses a connect there.
  static func checkDisconnect(_ phase: MailboxPhase) throws(MailConnectFailure) {
    if phase == .otherDevice { throw .takenByOtherIPhone }
  }

  private static func linked(_ result: ConnectResult, provider: MailProviderKind) throws(MailConnectFailure) {
    switch result {
    case .connected: return
    case .cancelled: throw .cancelled
    case .failed(.offline): throw .offline
    case .failed(let f): throw .failed(message(f, provider: provider))
    }
  }

  // MARK: The first scan

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
        // Profile stops saying "Importing" (it runs on after setup is left).
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
  static func message(_ f: ConnectFailure, provider: MailProviderKind = .gmail) -> String {
    switch f {
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .permissionMissing: "Hasala needs permission to read your bank alerts. Try again and allow it."
    case .noMailbox: "This Microsoft account has no Outlook mailbox. Connect the account your bank alerts go to."
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .notConfigured: "\(provider.appName) isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      provider == .outlook
        ? "Couldn't connect Outlook. Only personal Microsoft accounts work. Try again."
        : "Couldn't connect Gmail. Try again."
    }
  }
}
