import CoreMailbox
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
final class LiveLedgerStore: HasalaModels.LedgerStore {
  private(set) var state: LedgerState
  private(set) var now: LocalDateTime
  private(set) var revision = 0
  /// The projection has been read at least once.
  private(set) var loaded = false
  /// The Gmail lane's phase, once read (spec 04 §7.4); nil before that, or with no lane.
  private(set) var mailboxPhase: MailboxPhase?
  /// The ledger holds the App Review sample (`sample-` message ids, §6.13).
  private(set) var holdsSample = false

  @ObservationIgnored let reader: LedgerReader
  @ObservationIgnored private let author: LedgerEditAuthor?
  @ObservationIgnored private let clock: @MainActor () -> LocalDateTime
  @ObservationIgnored var profile: ProfileInfo
  /// Bank alerts' health for the next reload (`noteMailbox`).
  @ObservationIgnored private(set) var mailbox = MailboxHealth(status: .notConnected, lastEmail: "", banks: "")
  @ObservationIgnored private let prefs: DevicePrefsStore
  @ObservationIgnored private var undos: [Int: [LedgerEditAuthor.Inverse]] = [:]
  @ObservationIgnored private var nextToken = 1
  @ObservationIgnored private var writes: Task<Void, Never>?
  @ObservationIgnored private var reloadSeq = 0

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
    let ms = Int64(Date().timeIntervalSince1970 * 1000)
    let d = LocalClock.localDate(ms) ?? CivilDate(year: 2026, month: 1, day: 1)!
    let minutes = Int(((ms + LocalClock.offsetMs) % 86_400_000) / 60_000)
    return LocalDateTime(d.year, d.month, d.day, minutes / 60, minutes % 60)
  }

  /// The Gmail lane's status: its health shows from the next reload, its phase at once.
  func noteMailbox(_ status: MailboxStatus, nowMs: Int64) {
    mailbox = LedgerStateMapper.health(status, nowMs: nowMs)
    if mailboxPhase != status.phase { mailboxPhase = status.phase }
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
    guard seq == reloadSeq, let mapped else { return }
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
    if let author {
      let today = now.date
      enqueue { try await author.author(edit, before: before, today: today) }
    }
    guard let title else { return nil }
    let token = UndoToken(id: nextToken, title: title)
    nextToken += 1
    if !inverses.isEmpty { undos[token.id] = inverses }
    return token
  }

  func undo(_ token: UndoToken) {
    guard let inverses = undos.removeValue(forKey: token.id), let author else { return }
    enqueue { try await author.undo(inverses) }
  }

  /// Runs `write` after every earlier one, then reloads (a failure reloads too, so the
  /// optimistic change is replaced by what the projection holds).
  private func enqueue(_ write: @escaping @Sendable () async throws -> Void) {
    let previous = writes
    writes = Task { [weak self] in
      await previous?.value
      try? await write()
      await self?.reload()
    }
  }

  // MARK: The optimistic change

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
      s.txns[i].splits = lines
      if let first = lines.first { s.txns[i].categoryID = first.categoryID }
      s.txns[i].needsReview = false
      return (lines.isEmpty ? "Split removed" : "Split into \(lines.count) categories", [.split(txn: id, lines: t.splits)])
    case .archive(let id, let archived):
      let i = try index(id)
      s.txns[i].archived = archived
      return (archived ? "Archived" : "Restored", [.archived(txn: id, archived: !archived)])
    case .skipReview(let id):
      s.skippedReview.insert(id)
      return (nil, [])
    case .setBudget(let c, let month, let amount):
      guard amount.minor >= 0 else { throw .invalidAmount }
      let old = s.plan.budget(c, month)
      s.plan.budgets[PlanState.key(c, month)] = amount
      return ("\(name(c)) budget changed", [.budget(category: c, month: month, amount: old)])
    case .moveMoney(let from, let to, let month, let amount):
      guard amount.minor > 0 else { throw .invalidAmount }
      if let from {
        let left = s.plan.budget(from, month).minor - s.spent(from, in: month).minor
        guard left >= amount.minor else { throw .insufficientFunds }
        s.plan.budgets[PlanState.key(from, month)] = .aed(s.plan.budget(from, month).minor - amount.minor)
      } else {
        guard PlanEngine.snapshot(s, now: now).readyToAssign.minor >= amount.minor else { throw .insufficientFunds }
      }
      s.plan.budgets[PlanState.key(to, month)] = .aed(s.plan.budget(to, month).minor + amount.minor)
      return ("Moved to \(name(to))", [.move(from: to, to: from, month: month, amount: amount)])
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
    case .setNotifications(let level):
      s.prefs.notifications = level
      return (nil, [])
    case .setFaceIDLock(let on):
      s.prefs.faceIDLock = on
      return (nil, [])
    }
  }
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

  /// The Face ID lock is off until the app lock exists (§4.5 `appLock.enabled` defaults to
  /// false; nothing locks the app in this build, so the toggle must not read as on).
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
