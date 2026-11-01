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
final class LiveMailboxConnecting: MailboxConnecting, BankAlertsReporting, OtherBankProbing, SenderAddressAdding {
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
  var capabilities: MailboxCapabilities { [.connect, .signInAgain, .disconnect, .replace, .tryAgain] }

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
    return Self.mailboxes(status, provider: rt.lane?.provider ?? .gmail, nowMs: rt.context.clock.nowMs())
  }

  /// The provider of the account's link while another iPhone holds it and this one has
  /// never read it (a new install, a recovered account): a connect here takes the link
  /// over, after the provider screen's confirmation. The holder may be an iPhone the person
  /// no longer has (the server can't tell), so this iPhone isn't left with no way to read.
  var heldElsewhere: MailProviderKind? {
    guard let rt = runtime(), let lane = rt.lane, rt.store.mailboxStatus?.phase == .unlinked,
      case .holder(false, _)? = rt.serverLink
    else { return nil }
    return lane.provider
  }

  /// Known once the account is open and its lane's status was read (a build with no lane
  /// has none to read).
  var mailboxesKnown: Bool {
    guard let rt = runtime() else { return false }
    return rt.lane == nil || rt.store.mailboxStatus != nil
  }

  /// Observed through the runtime: the review flag arrives with `GET /account`.
  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  var connectRefusal: MailConnectRefusal? {
    guard let rt = runtime() else { return nil }
    return Self.refusal(reviewAccount: rt.reviewAccount, holdsSample: rt.store.holdsSample)
  }

  static func refusal(reviewAccount: Bool, holdsSample: Bool) -> MailConnectRefusal? {
    if holdsSample { return .sampleData }
    return reviewAccount ? .reviewAccount : nil
  }

  /// Observed through the runtime, like `mailboxes`.
  var offer: MailOffer? { runtime()?.mailOffer }

  var importing: MailImport? {
    guard let rt = runtime(), !rt.store.holdsSample else { return nil }
    return Self.importing(phase: rt.store.mailboxPhase, seen: rt.store.importSeen, progress: rt.store.importProgress)
  }

  var firstScanFinished: Bool {
    guard let rt = runtime(), !rt.store.holdsSample else { return false }
    return rt.store.mailboxPhase == .active && rt.store.mailboxStatus?.readFromMs == nil
  }

  var pastMailDays: Int {
    guard let rt = runtime() else { return 90 }
    if let status = rt.store.mailboxStatus, status.readFromMs != nil, let days = status.backfillDays { return days }
    return MailboxEngine.backfillDays(
      newestImportMs: (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil, nowMs: rt.context.clock.nowMs())
  }

  func importPastMail(_ mailboxID: String) async -> MailPastImport {
    guard let rt = runtime(), let lane = rt.lane else { return .later }
    let report = await lane.importPastMail()
    await rt.refreshMailbox()
    return report.completed && report.haltedOn == nil ? .finished(report.ops) : .later
  }

  static func importing(phase: MailboxPhase?, seen: Bool, progress: MailboxProgress?) -> MailImport? {
    let read = progress?.done ?? 0
    let total = progress?.total ?? 0
    switch phase {
    case .scanning?, .awaitingCards?, .authoringBackfill?:
      switch progress?.stage {
      case .done?: return nil
      case .failed(.offline)?: return MailImport(state: .offline, read: read, total: total)
      case .failed?: return MailImport(state: .paused, read: read, total: total)
      case .listing?, .downloading?, .authoring?, nil: return MailImport(state: .reading, read: read, total: total)
      }
    case .halted?:
      guard seen else { return nil }
      return MailImport(state: .stopped("Reading stopped"), read: read, total: total)
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

  func probeOtherBanks(_ candidates: [BankCandidate]) async -> OtherBankProbe {
    guard let lane = runtime()?.lane else { return .notReading }
    switch await lane.probeSenders(candidates.flatMap(\.domains)) {
    case .found(let domains): return .found(OtherBankProbe.hints(found: domains, in: candidates))
    case .notReading: return .notReading
    case .reconnectRequired: return .signInAgain
    case .offline: return .offline
    }
  }

  var unlistedSenders: [String] { runtime()?.store.mailboxStatus?.unlisted ?? [] }

  func addSenderAddress(_ typed: String, for domain: String) async -> SenderAddressOutcome {
    guard let rt = runtime(), let lane = rt.lane else { return .offline }
    let address: String
    do { address = try BankDomains.normalizeTypedAddress(typed) } catch { return .refused(Self.senderLine(error, domain)) }
    guard BankDomains.isMember(BankDomains.domainOf(address), of: [domain]) else {
      return .refused(Self.senderLine(.notQuerySafe, domain, other: true))
    }
    switch await lane.addSender(address) {
    case .failure(let e): return .refused(Self.senderLine(e, domain))
    case .success:
      await rt.refreshMailbox()
      return unlistedSenders.contains(domain) ? .offline : .added(address)
    }
  }

  static func senderLine(_ e: BankDomains.TypedDomainError, _ domain: String, other: Bool = false) -> String {
    if other { return "Type an address that ends in @\(domain)." }
    switch e {
    case .empty, .addressRequired: return "Type the full address, such as alerts@\(domain)."
    case .forwarder: return "That's a personal email service. Type the address your bank sends from."
    case .sharedSuffix, .notQuerySafe: return "Hasala can't read that address. Check it and try again."
    case .nonASCII: return "Type the address in English letters, as it shows on the alert."
    }
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
    return newest.map { RelativeTime.ago(ms: nowMs - $0, nowMs: nowMs) }
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
  static func mailboxes(_ s: MailboxStatus, provider: MailProviderKind = .gmail, nowMs: Int64) -> [MailboxSnapshot] {
    mailboxes(phase: s.phase, halt: s.haltedOn, address: s.address, lastSuccessAtMs: s.lastSuccessAtMs,
              bankDomains: s.health.map(\.domain), provider: provider, nowMs: nowMs,
              pastMailSkipped: s.readFromMs != nil)
  }

  /// The row from the status's parts (the table in plan B4.4). The mailbox page's "Last
  /// checked" is the last good run on this iPhone's clock, at the ledger's local time
  /// (`LocalClock`, as every transaction time is).
  static func mailboxes(
    phase: MailboxPhase, halt: MailboxHaltCode?, address: String?, lastSuccessAtMs: Int64?, bankDomains: [String],
    provider: MailProviderKind = .gmail, nowMs: Int64, timeZone: TimeZone = localTimeZone,
    pastMailSkipped: Bool = false
  ) -> [MailboxSnapshot] {
    let checked = lastSuccessAtMs.map { "Checked \(RelativeTime.ago(ms: nowMs - $0, nowMs: nowMs))" } ?? "Not checked yet"
    var row = MailboxSnapshot(
      id: mailboxID(provider), provider: provider, address: address ?? provider.appName, state: .connected, meta: checked,
      accountKind: provider == .outlook ? "Personal Microsoft" : nil,
      banks: Set(bankDomains.compactMap { LedgerStateMapper.bankName(domain: $0) }).sorted(),
      lastChecked: lastSuccessAtMs.map { checkedAt($0, timeZone: timeZone) },
      pastMailSkipped: pastMailSkipped && phase == .active)
    switch phase {
    case .unlinked:
      // None read here, even while the server names another iPhone as the link's holder (a
      // new install, a recovered account): that iPhone may be gone, so this one says it
      // reads nothing and offers the connect (`heldElsewhere`), never that alerts work.
      return []
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
        if halt == .noMailbox { row.note = message(.noMailbox, provider: provider) }
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
  /// email step. An iPhone without a link offers it once the server answered
  /// (`serverLink`), also while another iPhone holds the link: it may be one the person no
  /// longer has, and the connect asks before it takes the link over. A halt is offered a new sign-in only when signing in to the provider again
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
      case .noLink?, .holder?: return .connect
      case nil: return nil
      }
    case .reconnectRequired: return signInAgain
    case .halted:
      // A full account or missing templates aren't fixed by a new Google sign-in.
      switch halt {
      case .reconnectRequired?, .noMailbox?: return signInAgain
      default: return nil
      }
    // The first import runs on its own (Profile says "Importing").
    case .scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice: return nil
    }
  }

  /// Before a connect from an iPhone without a link, the server's answer asked just now:
  /// another iPhone holding the link refuses it unless the person confirmed taking it over
  /// (`confirmed`; the server moves the link and that iPhone stops reading), and no answer
  /// (`nil`, offline) refuses it, as no offer shows then.
  static func checkTakeover(_ link: MailboxLinkStatus?, confirmed: Bool = false) throws(MailConnectFailure) {
    switch link {
    case .noLink?, .holder(true, _)?: return
    case .holder(false, _)?: if !confirmed { throw .takenByOtherIPhone }
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
  func connect(
    _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
    ask: @escaping MailSwitchAsk
  ) async throws(MailConnectFailure) -> MailLinked {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    guard let lane = rt.lanes[provider] else { throw .failed("\(provider.appName) isn't available in this build.") }
    if let refusal = Self.refusal(reviewAccount: rt.reviewAccount, holdsSample: rt.store.holdsSample) {
      throw .failed(refusal.message)
    }
    let current = rt.lane
    let status = await (current ?? lane).status()
    let replaces = try Self.admit(
      provider, current: current?.provider, phase: status.phase, address: status.address, replacing: replacing)
    var takesOver = false
    if status.phase == .unlinked {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link, confirmed: replacing)
      if case .holder(false, _)? = link { takesOver = true }
    }
    let switching = current.map { $0.provider != provider } ?? false
    let days = MailboxEngine.backfillDays(
      newestImportMs: (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil, nowMs: rt.context.clock.nowMs())
    let oldPlan = switching && replaces && removingOld ? await current?.retirePlan() : nil
    let oldName = status.address ?? current?.provider.appName ?? provider.appName
    let old = switching ? current : nil
    await old?.stop()
    let newest = (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil
    let result = await lane.connect(
      backfillDays: days, pastMail: Self.pastMail(pastMail, takesOver: takesOver, newestImportMs: newest),
      replacing: replaces, confirm: Self.confirm(ask, provider: provider))
    let nowReading: String?
    do { nowReading = try Self.linked(result, provider: provider) } catch {
      await old?.resume()
      throw error
    }
    rt.linkedHere(provider)
    if switching, let old = current { await old.endGrant() }
    var retired = Self.retired(result)
    if let oldPlan, oldPlan.total > 0 || !oldPlan.countKnown { retired = await lane.retire(oldPlan) }
    await rt.refreshMailbox()
    let reads = await lane.status()
    if reads.phase == .active, reads.readFromMs != nil, reads.lastSuccessAtMs == nil {
      let scan = firstScan()
      Task { for await _ in scan {} }
    }
    return MailLinked(
      mailboxID: Self.mailboxID(provider), nowReading: nowReading, removal: Self.removal(retired, old: oldName))
  }

  static func pastMail(_ choice: MailPastChoice, takesOver: Bool, newestImportMs: Int64?) -> MailboxPastMail {
    switch choice {
    case .importPast: .read
    case .newOnly: .skip(catchUpFromMs: takesOver ? newestImportMs : nil)
    }
  }

  static func confirm(_ ask: @escaping MailSwitchAsk, provider: MailProviderKind) -> MailboxSwitchConfirm {
    { question in await Self.asked(ask, question, provider: provider) }
  }

  static func asked(_ ask: MailSwitchAsk, _ q: MailboxSwitchQuestion, provider: MailProviderKind) async
    -> MailboxSwitchChoice
  {
    switch await ask(question(q, provider: provider)) {
    case .keep: .keep
    case .remove: .remove
    case .cancel: .cancel
    }
  }

  static func question(_ q: MailboxSwitchQuestion, provider: MailProviderKind) -> MailSwitchQuestion {
    MailSwitchQuestion(
      provider: provider, oldAddress: q.oldAddress, newAddress: q.newAddress,
      impact: q.transactions.flatMap { $0 > 0 ? MailboxDisconnectImpact(transactions: $0, edited: q.edited) : nil },
      oldHasNoMailbox: q.oldHasNoMailbox, countUnknown: q.transactions == nil)
  }

  static func retired(_ result: ConnectResult) -> MailboxRetireOutcome? {
    if case .connected(_, _, let retired) = result { return retired }
    return nil
  }

  static func removal(_ retired: MailboxRetireOutcome?, old: String) -> MailSwitchRemoval? {
    switch retired {
    case nil: nil
    case .removed(let n)?: .removed(n)
    case .failed?: .failed(from: old)
    }
  }

  /// The same lane connect: the provider's sign-in and the step-up again, then the lane
  /// picks up where it stopped, or reads another address from the start.
  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
    let fallback = try lane().provider
    let provider = MailProviderKind(rawValue: mailboxID) ?? fallback
    let linked = try await connect(provider, replacing: false, removingOld: false, pastMail: .importPast, ask: ask)
    guard await linkState() == .scanning else { return linked }
    Task { for await _ in firstScan() {} }
    return linked
  }

  func tryAgain(_ mailboxID: String) async {
    await runtime()?.retryMailbox()
  }

  /// CoreMailbox's disconnect: the `mailbox.unlink` step-up, the watch or subscription
  /// stopped, the grant ended, the server's link deleted.
  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
    let lane = try lane()
    // The server's delete has no holder check: from here it would end the other
    // iPhone's reading, and this iPhone holds no sign-in to delete.
    try Self.checkDisconnect(await lane.status().phase)
    let plan = removeTransactions ? await lane.retirePlan() : nil
    let outcome = await lane.disconnect(removing: plan)
    let rt = runtime()
    await rt?.refreshMailbox()
    if let rt {
      rt.unlinkedHere(outcome)
    } else {
      BankTextsLinkKeeper(nowMs: { SystemClock().nowMs() }).disconnected(outcome)
    }
    try Self.disconnected(outcome, provider: lane.provider)
  }

  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? {
    guard let lane = try? lane(), let plan = await lane.retirePlan(), plan.total > 0 else { return nil }
    return MailboxDisconnectImpact(transactions: plan.total, edited: plan.edited)
  }

  static func disconnected(_ outcome: MailboxDisconnectOutcome, provider: MailProviderKind) throws(MailConnectFailure) {
    switch outcome {
    case .disconnected, .removed: return
    case .otherDevice: throw .takenByOtherIPhone
    case .failed: throw .failed("Couldn't disconnect \(provider.appName). Try again.")
    case .disconnectedRemoveFailed:
      throw .failed("\(provider.appName) is disconnected, but its transactions couldn't be removed. They stay for now.")
    }
  }

  /// A disconnect from an iPhone that doesn't hold the link is refused, as `admit`
  /// refuses a connect there.
  static func checkDisconnect(_ phase: MailboxPhase) throws(MailConnectFailure) {
    if phase == .otherDevice { throw .takenByOtherIPhone }
  }

  @discardableResult
  static func linked(_ result: ConnectResult, provider: MailProviderKind) throws(MailConnectFailure) -> String? {
    switch result {
    case .connected(let address, let another, _): return another ? address : nil
    case .cancelled: throw .cancelled
    case .declined: throw .switchDeclined
    case .failed(.offline): throw .offline
    case .failed(.noMailbox): throw .noMailbox(provider)
    case .failed(.permissionMissing): throw .permissionMissing(provider)
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
            last = Self.progress(p, provider: lane.provider)
            continuation.yield(last)
          case .ended(let t):
            continuation.yield(Self.ended(t, last: last, provider: lane.provider))
          }
        }
        // Profile stops saying "Importing" (it runs on after setup is left).
        await rt?.refreshMailbox()
        continuation.finish()
      }
    }
  }

  /// Where the first scan's foreground runs left it, with what they filed.
  static func ended(_ t: MailboxLane.FirstScanTotals, last: ScanProgress, provider: MailProviderKind) -> ScanProgress {
    let summary = SortSummary(
      total: t.ops, byRules: t.byRules, byDictionary: t.byDictionary, byModel: t.byModel, toReview: t.toReview)
    switch t.phase {
    case .active:
      return ScanProgress(phase: .finished, read: last.total, total: last.total, summary: summary)
    case .halted, .reconnectRequired, .otherDevice:
      return ScanProgress(
        phase: .failed(stopped(t.haltedOn, provider: provider)), read: last.read, total: last.total, summary: summary)
    case .unlinked, .scanning, .awaitingCards, .authoringBackfill:
      return ScanProgress(phase: .background, read: last.read, total: last.total, summary: summary)
    }
  }

  func loadSampleData() async throws(SetupFailure) {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    try await rt.loadSample()
  }

  static func progress(_ p: MailboxProgress, provider: MailProviderKind) -> ScanProgress {
    switch p.stage {
    case .listing, .downloading: ScanProgress(phase: .downloading, read: p.done, total: p.total)
    case .authoring: ScanProgress(phase: .sorting, read: p.done, total: p.total)
    case .done: ScanProgress(phase: .finished, read: p.total, total: p.total)
    case .failed(let code): ScanProgress(phase: .failed(stopped(code, provider: provider)), read: p.done, total: p.total)
    }
  }

  /// Why the first scan stopped, in words.
  static func stopped(_ code: MailboxHaltCode?, provider: MailProviderKind) -> String {
    code == .noMailbox ? message(.noMailbox, provider: provider) : "Reading your bank alerts stopped. Try again."
  }

  /// Plain-language copy for a failed connect (spec 04 §7.11; content-free).
  static func message(_ f: ConnectFailure, provider: MailProviderKind = .gmail) -> String {
    switch f {
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .permissionMissing: MailConnectFailure.permissionMissingLine(provider)
    case .noMailbox: MailConnectFailure.noMailboxLine(provider)
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .mailboxInUse:
      "This \(provider.appName) address is connected to another Hasala account. Disconnect it there, or connect a different address."
    case .notConfigured: "\(provider.appName) isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      provider == .outlook
        ? "Couldn't connect Outlook. Only personal Microsoft accounts work. Try again."
        : "Couldn't connect Gmail. Try again."
    }
  }

  #if DEBUG
    struct OutlookTrustSource: Sendable {
      let graph: GraphClient
      let groups: [[String]]
    }

    func outlookTrustSource() async -> OutlookTrustSource? {
      guard let rt = runtime(), let lane = rt.lanes[.outlook] else { return nil }
      let trusted = BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:])
      let groups = BankDomains.groups(trusted, size: GraphClient.maxDomainsPerList).filter { !$0.isEmpty }
      guard !groups.isEmpty, let token = try? await lane.tokens.accessToken(forceRefresh: false)
      else { return nil }
      let graph = GraphClient(
        http: URLSessionHTTPExchange.ephemeral(maxResponseBytes: MailboxLimits.maxResponseBytes), accessToken: token.value,
        link: MemoryOutlookLinkStore(),
        knownSenders: OutlookSenders.known + (await lane.engine.senderAddresses()), nowMs: { SystemClock().nowMs() })
      return OutlookTrustSource(graph: graph, groups: groups)
    }
  #endif
}
