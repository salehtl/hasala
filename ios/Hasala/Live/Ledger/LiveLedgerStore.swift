import CoreDomain
import CoreMailbox
import CorePrimitives
import CoreProjection
import CoreTime
import Foundation
import HasalaModels
import Observation

/// The screens' ledger over a live account (spec 04 §15.2): HasalaKit's `LedgerStore`
/// read from the projection through `LedgerStateMapper`, written through
/// `LedgerEditAuthor`. Not to be confused with CoreStore's `LedgerStore` (the encrypted
/// row store), which this never touches.
///
/// An edit is applied to `state` at once (so a swiped review card stays gone), authored
/// in the background in gesture order, and then `state` is read back from the projection,
/// which is the truth: an edit the core refuses disappears on that reload. Every sync run
/// reloads too (`WorkCoordinator`'s committed stage).
@MainActor
@Observable
final class LiveLedgerStore: HasalaModels.LedgerStore, UndoAvailability {
  private(set) var state: LedgerState
  private(set) var now: LocalDateTime
  private(set) var revision = 0
  /// The projection has been read at least once.
  private(set) var loaded = false
  /// The Gmail lane's phase, once read (spec 04 §7.4); nil before that, or with no lane.
  private(set) var mailboxPhase: MailboxPhase?
  /// Why the lane halted, read with its phase.
  private(set) var mailboxHalt: MailboxHaltCode?
  /// The ledger holds the App Review sample (`sample-` message ids, §6.13).
  private(set) var holdsSample = false
  /// The lane's last status, as read with its phase: the mailbox row comes from it
  /// (`LiveMailboxConnecting.mailboxes`). Read-only plumbing; nothing is authored from it.
  private(set) var mailboxStatus: MailboxStatus?
  private(set) var importProgress: MailboxProgress?
  private(set) var importSeen = false

  @ObservationIgnored let reader: LedgerReader
  @ObservationIgnored private let author: LedgerEditAuthor?
  @ObservationIgnored private let clock: @MainActor () -> LocalDateTime
  @ObservationIgnored var profile: ProfileInfo
  /// Bank alerts' health for the next reload (`noteMailbox`).
  @ObservationIgnored private(set) var mailbox = MailboxHealth(status: .notConnected, lastEmail: "", banks: "")
  @ObservationIgnored private let prefs: DevicePrefsStore
  @ObservationIgnored private var undos: [Int: [LedgerEditAuthor.Inverse]] = [:]
  @ObservationIgnored private var undoable: Set<Int> = []
  @ObservationIgnored private var nextToken = 1
  @ObservationIgnored private var writes: Task<Void, Never>?
  @ObservationIgnored private var reloadSeq = 0
  @ObservationIgnored private var writesInFlight = 0
  @ObservationIgnored var onWriteFailed: (@MainActor () -> Void)?

  init(
    reader: LedgerReader, author: LedgerEditAuthor?, profile: ProfileInfo, prefs: DevicePrefsStore,
    clock: @escaping @MainActor () -> LocalDateTime = LiveLedgerStore.localNow
  ) {
    self.reader = reader
    self.author = author
    self.profile = profile
    self.prefs = prefs
    self.clock = clock
    let now = clock()
    self.now = now
    state = LedgerState(
      categories: [], accounts: [], txns: [], plan: PlanState(income: .aed(0), payday: 28, startingSplit: [50, 30, 20], budgets: [:]),
      profile: profile, mailbox: MailboxHealth(status: .notConnected, lastEmail: "", banks: ""), prefs: prefs.prefs)
  }

  /// "Now" in the fixed local clock (UTC+04:00, spec 03c §1.5).
  static func localNow() -> LocalDateTime {
    local(Int64(Date().timeIntervalSince1970 * 1000))
  }

  static func runClock(_ environment: [String: String] = ProcessInfo.processInfo.environment)
    -> @MainActor () -> LocalDateTime
  {
    #if DEBUG
      if environment["HASALA_LEDGER_NOW"] == "sample" { return sampleNow }
    #endif
    return localNow
  }

  #if DEBUG
    static func sampleNow() -> LocalDateTime {
      let ms = Int64(Date().timeIntervalSince1970 * 1000)
      guard let seed = try? SampleSeed.Document(json: SampleSeed.bundled()),
        let anchor = try? parseInstantMs(seed.anchor),
        let target = SampleSeed.target(anchorMs: anchor, nowMs: ms)
      else { return local(ms) }
      return local(target.targetMs)
    }
  #endif

  private static func local(_ ms: Int64) -> LocalDateTime {
    let d = LocalClock.localDate(ms) ?? CivilDate(year: 2026, month: 1, day: 1)!
    let minutes = Int(((ms + LocalClock.offsetMs) % 86_400_000) / 60_000)
    return LocalDateTime(d.year, d.month, d.day, minutes / 60, minutes % 60)
  }

  /// The Gmail lane's status: its health shows from the next reload, its phase at once.
  func noteMailbox(_ status: MailboxStatus, nowMs: Int64) {
    mailbox = LedgerStateMapper.health(status, nowMs: nowMs)
    if mailboxStatus != status { mailboxStatus = status }
    if mailboxPhase != status.phase { mailboxPhase = status.phase }
    if mailboxHalt != status.haltedOn { mailboxHalt = status.haltedOn }
    switch status.phase {
    case .scanning, .awaitingCards, .authoringBackfill:
      if !importSeen { importSeen = true }
    case .active, .unlinked, .otherDevice:
      if importSeen { importSeen = false }
      if importProgress != nil { importProgress = nil }
    case .halted, .reconnectRequired:
      break
    }
  }

  func noteImport(_ progress: MailboxProgress) {
    var next = progress
    if case .failed = progress.stage, let last = importProgress {
      next.done = last.done
      next.total = last.total
    }
    if importProgress != next { importProgress = next }
  }

  /// Reads the projection again (off the main actor) and publishes it. A later reload
  /// that finishes first wins; an older one is dropped.
  func reload() async {
    reloadSeq += 1
    let seq = reloadSeq
    let today = clock()
    let context = LedgerStateMapper.Context(
      today: today.date, profile: profile, mailbox: mailbox, prefs: prefs.prefs,
      skippedDigests: prefs.skippedDigests(on: today.date), digestSalt: prefs.salt)
    let reader = self.reader
    let mapped = await Task.detached(priority: .userInitiated) { try? LedgerStateMapper.map(reader, context: context) }
      .value
    guard seq == reloadSeq, writesInFlight == 0, let mapped else { return }
    state = mapped
    now = today
    loaded = true
    let sample = mapped.txns.contains(where: \.isSample)
    if holdsSample != sample { holdsSample = sample }
    revision += 1
  }

  @discardableResult
  func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken? {
    let before = state
    var s = state
    let (title, inverses) = try Self.patch(edit, &s, now: now)
    // A reload already in flight read the projection before this edit: drop it, so it
    // can't bring the old state back. The write's own reload follows.
    reloadSeq += 1
    switch edit {
    case .skipReview(let id): prefs.skip(id, on: now.date)
    case .setNotifications(let level): prefs.update { $0.notifications = level }
    case .setFaceIDLock(let on): prefs.update { $0.faceIDLock = on }
    default: break
    }
    state = s
    revision += 1
    let token = title.map { UndoToken(id: nextToken, title: $0) }
    if token != nil { nextToken += 1 }
    if let token {
      if !inverses.isEmpty { undos[token.id] = inverses }
      if !inverses.isEmpty || (author != nil && Self.authorsInverse(edit)) { undoable.insert(token.id) }
    }
    if let author {
      let today = now.date
      enqueue(undo: token?.id) { try await author.author(edit, before: before, today: today) }
    }
    return token
  }

  static func authorsInverse(_ edit: LedgerEdit) -> Bool {
    switch edit {
    case .setBudget, .moveMoney, .acceptBillAmount, .stopTrackingBill: true
    case .resolveCopy(_, let merge): merge
    default: false
    }
  }

  func undo(_ token: UndoToken) {
    guard undoable.remove(token.id) != nil, let author else { return }
    enqueue { [weak self] in
      guard let inverses = await self?.takeUndo(token.id), !inverses.isEmpty else { return [] }
      try await author.undo(inverses)
      return []
    }
  }

  private func takeUndo(_ id: Int) -> [LedgerEditAuthor.Inverse]? { undos.removeValue(forKey: id) }

  /// Runs `write` after every earlier one, then reloads (a failure reloads too, so the
  /// optimistic change is replaced by what the projection holds).
  func enqueue(undo: Int? = nil, _ write: @escaping @Sendable () async throws -> [LedgerEditAuthor.Inverse]) {
    let previous = writes
    writesInFlight += 1
    writes = Task { [weak self] in
      await previous?.value
      var authored: [LedgerEditAuthor.Inverse] = []
      let failed: Bool
      do {
        authored = try await write()
        failed = false
      } catch {
        failed = true
      }
      guard let self else { return }
      writesInFlight -= 1
      if failed {
        if let undo {
          undos[undo] = nil
          undoable.remove(undo)
        }
        onWriteFailed?()
      } else if let undo, !authored.isEmpty {
        undos[undo, default: []] += authored
      }
      await reload()
    }
  }

  func canUndo(_ token: UndoToken) -> Bool { undoable.contains(token.id) }

  // MARK: The optimistic change

  static func projectInverse(_ p: Project) -> LedgerEditAuthor.Inverse {
    let completed = p.completedOn.flatMap { CivilDate(year: $0.year, month: $0.month, day: $0.day)?.wire }
    return .projectState(
      project: p.id, status: p.complete ? "completed" : "active", completedOn: p.complete ? completed : nil,
      countInPlan: p.countInPlan)
  }

  func newProjectID() -> ProjectID {
    (try? Ulid.mint(ms: Int64(Date().timeIntervalSince1970 * 1000), random: SystemRandom())) ?? UUID().uuidString
  }

  /// Applies `edit` to `s` as the projection will show it, or throws why it can't be
  /// applied. Returns the toast's title and the undo's inverse writes.
  static func patch(_ edit: LedgerEdit, _ s: inout LedgerState, now: LocalDateTime) throws(ActionError)
    -> (String?, [LedgerEditAuthor.Inverse])
  {
    func index(_ id: TxnID) throws(ActionError) -> Int {
      guard let i = s.txns.firstIndex(where: { $0.id == id }) else { throw .notFound }
      return i
    }
    func name(_ c: CategoryID) -> String { s.category(c)?.name ?? "Uncategorized" }

    switch edit {
    case .addTransaction(let d):
      if let refusal = d.refusal { throw refusal }
      if let c = d.categoryID, s.category(c) == nil { throw .notFound }
      if let a = d.accountID, !s.accounts.contains(where: { $0.id == a }) { throw .notFound }
      s.txns.append(d.txn(id: "pending-manual-\(UUID().uuidString.lowercased())"))
      return (nil, [])
    case .categorize(let id, let c, _, let project):
      guard s.category(c) != nil else { throw .notFound }
      let i = try index(id)
      let old = s.txns[i]
      s.txns[i].categoryID = c
      s.txns[i].categorySource = .user
      s.txns[i].needsReview = false
      s.txns[i].isTransfer = c == "transfer"
      s.txns[i].splits = []
      if let project { s.txns[i].projectID = project }
      // Undo puts back what the gesture changed: the split (which held the categories)
      // or the category, and the project.
      var inverses: [LedgerEditAuthor.Inverse] =
        old.splits.isEmpty
        ? [.category(txn: id, category: old.categoryID, needsReview: old.needsReview)]
        : [.split(txn: id, lines: old.splits)]
      if let project, project != old.projectID { inverses.append(.project(txn: id, project: old.projectID)) }
      return ("Sorted into \(name(c))", inverses)
    case .markTransfer(let id):
      let i = try index(id)
      let old = s.txns[i]
      s.txns[i].categoryID = "transfer"
      s.txns[i].categorySource = .user
      s.txns[i].isTransfer = true
      s.txns[i].needsReview = false
      return ("Marked as a transfer", [.category(txn: id, category: old.categoryID, needsReview: old.needsReview)])
    case .markRefund(let id):
      let i = try index(id)
      let old = s.txns[i]
      let refund = old.categoryID != "refunds"
      s.txns[i].categoryID = refund ? "refunds" : nil
      s.txns[i].isRefund = refund
      s.txns[i].needsReview = !refund
      return (
        refund ? "Marked as a refund" : "No longer a refund",
        [.category(txn: id, category: old.categoryID, needsReview: old.needsReview)]
      )
    case .setNote(let id, let note):
      let i = try index(id)
      s.txns[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return (nil, [])
    case .renameMerchant(let id, let new):
      let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
      let i = try index(id)
      guard !new.isEmpty else { throw .notFound }
      let old = s.txns[i].merchant
      for j in s.txns.indices where s.txns[j].merchant == old { s.txns[j].merchant = new }
      return ("Renamed to \(new)", [.displayName(txn: id, shown: old)])
    case .split(let id, let lines):
      let i = try index(id)
      let t = s.txns[i]
      if !lines.isEmpty, !TransactionEngine.splitAddsUp(lines, total: t.amount) { throw .splitDoesNotAddUp }
      s.txns[i].splits = t.apportioned(lines)
      if let first = lines.first { s.txns[i].categoryID = first.categoryID }
      s.txns[i].needsReview = false
      return (lines.isEmpty ? "Split removed" : "Split into \(lines.count) categories", [.split(txn: id, lines: t.splits)])
    case .archive(let id, let archived):
      let i = try index(id)
      s.txns[i].archived = archived
      return (archived ? "Archived" : "Restored", [.archived(txn: id, archived: !archived)])
    case .resolveCopy(let id, let merge):
      let i = try index(id)
      guard s.txns[i].isHeldCopy else { throw .notFound }
      if merge {
        s.txns.remove(at: i)
        return ("Merged", [])
      }
      s.txns[i].heldCopy = nil
      return ("Kept both", [.copyReopened(txn: id)])
    case .resolveSamePurchase(let id, let same):
      let i = try index(id)
      guard let match = s.txns[i].samePurchase, let j = s.txns.firstIndex(where: { $0.id == match.of }) else {
        throw .notFound
      }
      s.txns[i].samePurchase = nil
      guard same else { return ("Kept both", [.samePurchaseDeclined(home: id)]) }
      guard let previous = s.txns[j].homeMinor else { throw .notFound }
      let previousRate = s.txns[j].homeSource == .rate ? s.txns[j].homeRateMicro : nil
      let oldNote = s.txns[i].note
      s.txns[i].archived = true
      s.txns[i].note = SamePurchaseText.note(s.txns[j].amount)
      s.txns[j].homeMinor = s.txns[i].amount.minor
      return (
        "Counted once",
        [.samePurchase(foreign: match.of, previousHome: previous, previousRateMicro: previousRate, home: id, previousNote: oldNote)]
      )
    case .skipReview(let id):
      s.skippedReview.insert(id)
      return (nil, [])
    case .setBudget(let c, let month, let amount):
      guard amount.minor >= 0 else { throw .invalidAmount }
      s.plan.budgets[PlanState.key(c, month)] = amount
      return ("\(name(c)) budget changed", [])
    case .moveMoney(let from, let to, let month, let amount):
      guard amount.minor > 0 else { throw .invalidAmount }
      if let from {
        let left = s.plan.budget(from, month).minor.minus(s.spent(from, in: month).minor)
        guard left >= amount.minor else { throw .insufficientFunds }
        s.plan.budgets[PlanState.key(from, month)] = .aed(s.plan.budget(from, month).minor - amount.minor)
      } else {
        guard PlanEngine.snapshot(s, now: now).readyToAssign.minor >= amount.minor else { throw .insufficientFunds }
      }
      s.plan.budgets[PlanState.key(to, month)] = .aed(s.plan.budget(to, month).minor + amount.minor)
      return ("Moved to \(name(to))", [])
    case .trackCandidate, .dismissCandidate:
      throw .notFound
    case .markBillPaid(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }), !s.bills[i].isIncome else { throw .notFound }
      let due = s.bills[i].nextDue
      let next = due.yearMonth.next
      s.bills[i].history.insert(due, at: 0)
      s.bills[i].nextDue = LocalDate(next.year, next.month, min(s.bills[i].usualDay, next.days))
      return ("\(s.bills[i].name) marked paid", [.occurrence(bill: id, due: due)])
    case .acceptBillAmount(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      s.bills[i].priceChangeFrom = nil
      return ("New amount accepted", [])
    case .stopTrackingBill(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }), !s.bills[i].isIncome else { throw .notFound }
      s.bills[i].state = .dismissed
      return ("Stopped tracking \(s.bills[i].name)", [])
    case .setRuleEnabled(let id, let enabled):
      guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
      s.rules[i].enabled = enabled
      return (nil, [])
    case .setRate(let currency, let micro):
      guard ExchangeRates.isSettable(currency, micro) else { throw .invalidAmount }
      s.setRate(currency, micro: micro)
      return (nil, [])
    case .unsetRate(let currency):
      guard ExchangeRates.isSettable(currency, nil) else { throw .invalidAmount }
      s.unsetRate(currency)
      return (nil, [])
    case .saveProject(let id, let draft):
      guard draft.refusal == nil else { throw .invalidProject }
      let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let verb = draft.glyph == .travel ? "flies" : "starts"
      if let i = s.projects.firstIndex(where: { $0.id == id }) {
        let old = s.projects[i]
        s.projects[i] = Project(
          id: id, name: name, glyph: draft.glyph, budget: draft.budget, starts: draft.starts, ends: draft.ends,
          countInPlan: draft.countInPlan, complete: old.complete, completedOn: old.completedOn, startVerb: verb)
      } else {
        s.projects.append(Project(
          id: id, name: name, glyph: draft.glyph, budget: draft.budget, starts: draft.starts, ends: draft.ends,
          countInPlan: draft.countInPlan, startVerb: verb))
      }
      return (nil, [])
    case .setProjectCountInPlan(let id, let on):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      let old = s.projects[i]
      s.projects[i].countInPlan = on
      return (
        on ? "Counted in your monthly plan" : "Kept out of your monthly plan",
        [Self.projectInverse(old)]
      )
    case .completeProject(let id, let done):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      let old = s.projects[i]
      s.projects[i].complete = done
      s.projects[i].completedOn = done ? now.date : nil
      return (done ? "\(old.name) marked complete" : "\(old.name) reopened", [Self.projectInverse(old)])
    case .removeProject(let id):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      s.projects.remove(at: i)
      for k in s.txns.indices where s.txns[k].projectID == id { s.txns[k].projectID = nil }
      return (nil, [])
    case .assignProject(let ids, let project):
      if let project, s.project(project) == nil { throw .notFound }
      guard !ids.isEmpty else { throw .notFound }
      var inverses: [LedgerEditAuthor.Inverse] = []
      for id in ids {
        let i = try index(id)
        inverses.append(.project(txn: id, project: s.txns[i].projectID))
        s.txns[i].projectID = project
      }
      let name = s.project(project)?.name ?? ""
      return (
        project == nil ? "Taken out of the project" : ids.count == 1 ? "Added to \(name)" : "Added \(ids.count) to \(name)",
        inverses
      )
    case .setNotifications(let level):
      s.prefs.notifications = level
      return (nil, [])
    case .setFaceIDLock(let on):
      s.prefs.faceIDLock = on
      return (nil, [])
    }
  }
}

@MainActor
protocol UndoAvailability: AnyObject {
  func canUndo(_ token: UndoToken) -> Bool
}

/// The device's own preferences (spec 04 §4.5; never synced): notification level, the
/// Face ID lock, and the review cards skipped until the next local midnight (kept as
/// digests: §4.5 allows no identifier in UserDefaults).
@MainActor
final class DevicePrefsStore {
  private let defaults: UserDefaults
  private static let prefsKey = "prefs.device.v1"
  private static let skippedKey = "prefs.review.skipped.v2"
  /// The earlier form, which held transaction ids.
  private static let legacySkippedKey = "prefs.review.skipped.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The app lock is off until it is turned on in Profile (§4.5 `appLock.enabled`
  /// defaults to false).
  var prefs: DevicePrefs {
    guard let d = defaults.data(forKey: Self.prefsKey), let p = try? JSONDecoder().decode(DevicePrefs.self, from: d) else {
      return DevicePrefs(faceIDLock: false)
    }
    return p
  }

  /// This install's salt for the skipped cards' digests.
  var salt: String { LocalAccountData.salt(defaults) }

  func update(_ change: (inout DevicePrefs) -> Void) {
    var p = prefs
    change(&p)
    if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: Self.prefsKey) }
  }

  private struct Skipped: Codable {
    var day: String
    var ids: [String]
  }

  /// The digests of the cards skipped today (`LocalAccountData.digest` of each id).
  func skippedDigests(on day: LocalDate) -> Set<String> {
    defaults.removeObject(forKey: Self.legacySkippedKey)
    guard let d = defaults.data(forKey: Self.skippedKey), let s = try? JSONDecoder().decode(Skipped.self, from: d),
      s.day == "\(day.year)-\(day.month)-\(day.day)"
    else { return [] }
    return Set(s.ids)
  }

  func skip(_ id: TxnID, on day: LocalDate) {
    var ids = skippedDigests(on: day)
    ids.insert(LocalAccountData.digest(id, salt: salt))
    let s = Skipped(day: "\(day.year)-\(day.month)-\(day.day)", ids: ids.sorted())
    if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: Self.skippedKey) }
  }

  /// The account's data left this iPhone: forget the skipped cards.
  func forgetAccountData() {
    defaults.removeObject(forKey: Self.skippedKey)
    defaults.removeObject(forKey: Self.legacySkippedKey)
  }
}
