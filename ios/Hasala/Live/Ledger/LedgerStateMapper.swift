import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreProjection
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaModels

/// The projection (`projection.sqlite` through `LedgerReader`) as the screens' read model,
/// HasalaKit's `LedgerState` (spec 04 §15.1-§15.2): categories, accounts, transactions,
/// the plan, bills, projects, goals and rules at one instant. The screens' engines
/// (`HomeEngine`, `PlanEngine`, `ActivityEngine`, `BillsEngine`, `ReviewEngine`) run over it
/// unchanged, so a live account shows the same boards as the Maya mock (AT-REV-3).
///
/// Every figure comes from the fold: budgets are CoreDomain's `PlanEngine.assigned`
/// (carry-forward and moves applied), a bill's next due date is its schedule minus the
/// resolved occurrences, a balance is the latest check-in. What no op family holds (the
/// detector's bill proposals, review suggestions, row detail overrides) is left empty.
nonisolated enum LedgerStateMapper {
  /// What the projection doesn't hold: who is signed in, the mailbox's health and the
  /// device's own preferences.
  struct Context: Sendable {
    var today: LocalDate
    var profile: ProfileInfo
    var mailbox = MailboxHealth(status: .notConnected, lastEmail: "", banks: "")
    var prefs = DevicePrefs()
    /// The review cards skipped today, as digests (`DevicePrefsStore`), and their salt.
    var skippedDigests: Set<String> = []
    var digestSalt = ""
    var unreadSenders: [String: String] = [:]
    var dismissedNotices: Set<String> = []
    var forkOps: [String: Op] = [:]
  }

  enum MapError: Error { case date }

  /// Display names of the banks the beta reads (card accounts name their bank by id).
  static let bankNames = RuntimeMailboxLedger.bankNames

  struct Mapped: Sendable {
    var state: LedgerState
    var candidates: [BillCandidateCore]
  }

  static func map(_ r: LedgerReader, context c: Context) throws -> LedgerState {
    try mapped(r, context: c).state
  }

  static func mapped(_ r: LedgerReader, context c: Context) throws -> Mapped {
    guard let today = CivilDate(year: c.today.year, month: c.today.month, day: c.today.day) else { throw MapError.date }
    let month = today.yearMonth
    var rows = try r.activity(limit: 1_000_000)
    rows += try r.archived(limit: 1_000_000)
    let feed = try billFeed(r, rows: rows, today: today)
    let engine = try r.planEngine(month: month, today: today, bills: feed.expectations)
    let taxonomy = feed.taxonomy

    let categories = byParent(taxonomy.ordered).map { category($0, engine: engine) }
    let billOfTxn = feed.billOfTxn

    // Accounts: the latest check-in is the balance (03b §4.6).
    let cards = try r.cards()
    let checkins = try r.checkins()
    let liveAccounts = try r.accounts().filter(\.active)
    let accounts: [HasalaModels.Account] = liveAccounts.map { a in
      let card = cards.first { $0.account == a.id && $0.state == "mine" }
      let balance = checkins.first { $0.account == a.id && !$0.void }?.balanceMinor ?? 0
      return HasalaModels.Account(
        id: a.id, name: a.name, shortName: shortName(a), last4: card?.last4, kind: accountKind(a.kind),
        balance: Money(minor: balance, currency: a.currency), inPlan: a.inPlan, detail: "")
    }

    // Transactions: every live, parsed row (archived ones too, flagged).
    let rules = try r.rules()
    let ruleByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let home = try r.homeCurrency() ?? "AED"
    let reachRows = rows.map(\.reachRow)
    let paired = RuleReach.paired(reachRows, home: home)
    let rejections = try r.rejections()
    let combined = try r.transferCopies()
    var txns: [HasalaModels.Txn] = []
    txns.reserveCapacity(rows.count)
    for (i, row) in rows.enumerated() {
      var t = try txn(row, r: r, ruleByID: ruleByID, billID: billOfTxn[row.id])
      t.reachable = RuleReach.waiting(reachRows[i], samePurchase: paired)
      if let g = row.merchantGroup, let rejected = rejections[g] { t.rejectedCategories = rejected }
      t.combinedCopy = combined[row.id]?.copyID
      txns.append(t)
    }
    markSamePurchases(&txns, rows: rows, home: home)
    let unreadMail = try r.review(lanes: [.unreadable], limit: 1_000_000).map {
      Self.unreadMail($0, senders: c.unreadSenders, accounts: liveAccounts)
    }

    // The plan: CoreDomain's assigned budgets around this month, the income sources.
    var budgets: [String: Money] = [:]
    var incomeByMonth: [YearMonth: Money] = [:]
    let months = [month.adding(months: -1), month, month.adding(months: 1)].compactMap { $0 }
    for m in months {
      incomeByMonth[YearMonth(m.year, m.month)] = .aed(engine.income(m).total)
      for info in taxonomy.ordered where info.kind == .spending {
        let v = engine.assigned(m, info.id)
        if v != 0 { budgets[HasalaModels.PlanState.key(info.id, YearMonth(m.year, m.month))] = .aed(v) }
      }
    }
    let sources = engine.plan.incomeSources.values.filter(\.active)
    let split = try r.budgetTemplate()
    let plan = HasalaModels.PlanState(
      income: .aed(Fils.sum(sources.map(\.amountMinor))), payday: Int(sources.first?.payday ?? 28),
      startingSplit: split.map { [Int($0.need), Int($0.want), Int($0.saving)] } ?? [50, 30, 20], budgets: budgets,
      incomeByMonth: incomeByMonth)

    let bills = try liveBills(feed, r: r, context: c, txns: txns, income: engine.plan.incomeSources.values)

    let projects: [HasalaModels.Project] = try r.projects().map { id, p in
      HasalaModels.Project(
        id: id, name: p.name, glyph: glyph(p.icon ?? "flag"), budget: p.budgetMinor.map { .aed($0) },
        starts: p.startsOn.flatMap(CivilDate.init(wire:)).map(local),
        ends: p.endsOn.flatMap(CivilDate.init(wire:)).map(local), countInPlan: p.countInPlan,
        complete: p.status == "completed", completedOn: p.completedOn.flatMap(CivilDate.init(wire:)).map(local),
        startVerb: p.icon == "plane" ? "flies" : "starts")
    }

    let goals: [HasalaModels.Goal] = try r.goals().compactMap { id, g in
      guard g.status == "active", let category = g.source.categoryID else { return nil }
      let by = g.targetMonth.flatMap(CivilMonth.init(wire:)).map { YearMonth($0.year, $0.month) } ?? c.today.yearMonth
      let progress = engine.goalProgress(id: id, g, month: month)
      return HasalaModels.Goal(
        id: id, name: g.name, glyph: glyph(g.icon ?? "jar"), categoryID: category, target: .aed(g.targetMinor),
        saved: .aed(progress.progress), by: by)
    }

    let mappedRules: [HasalaModels.Rule] = rules.map { rule in
      HasalaModels.Rule(
        id: rule.id, patterns: rule.patterns, match: ruleMatch(rule.match), categoryID: rule.category,
        enabled: rule.enabled,
        learnedToday: rule.origin == "learned" && rule.createdAt.flatMap(localDay) == c.today)
    }

    let state = LedgerState(
      categories: categories, accounts: accounts, txns: txns, plan: plan, bills: bills, billCandidates: feed.candidates,
      projects: projects, goals: goals, rules: mappedRules, profile: c.profile, mailbox: c.mailbox, prefs: c.prefs,
      netWorth: NetWorthHistory(), skippedReview: skipped(txns, c),
      rates: try r.rates().map { CurrencyRate(currency: $0.currency, rateMicro: $0.rateMicro, updatedAt: $0.updatedAt) },
      unreadMail: unreadMail)
    return Mapped(state: state, candidates: feed.derived.candidates)
  }

  static func unreadMail(_ row: TxnRow, senders: [String: String] = [:], accounts: [CoreReplay.Account] = []) -> UnreadMail {
    let bank = row.mailboxMessageID.flatMap { senders[$0] }.flatMap { Self.bank(domain: $0) }
    let ofBank = accounts.filter { a in bank.map { a.institution == $0 } ?? false }
    return UnreadMail(
      id: row.id, provider: row.sourceProvider.flatMap(MailProviderKind.init(rawValue:)),
      receivedOn: CivilDate(wire: row.localDate).map(local) ?? LocalDate(1970, 1, 1),
      bank: bank.flatMap { bankNames[$0] }, accountID: (ofBank.first(where: \.inPlan) ?? ofBank.first)?.id)
  }

  /// The transactions whose digest is among the skipped cards'.
  static func skipped(_ txns: [HasalaModels.Txn], _ c: Context) -> Set<TxnID> {
    guard !c.skippedDigests.isEmpty else { return [] }
    return Set(txns.lazy.map(\.id).filter { c.skippedDigests.contains(LocalAccountData.digest($0, salt: c.digestSalt)) })
  }

  // MARK: Categories

  static func category(_ info: CategoryInfo, engine: CoreDomain.PlanEngine) -> HasalaModels.Category {
    let kind: HasalaModels.CategoryKind
    let bucket: HasalaModels.Bucket
    let role: CategoryRole
    switch (info.kind, info.bucket) {
    case (.spending, .saving?):
      (kind, bucket, role) = (.spending, .savings, .saving)
    case (.spending, let b):
      let isBill = engine.role(info.id) == "bills"
      (kind, bucket, role) = (.spending, b == .want ? .wants : .needs, isBill ? .bill : .everyday)
    case (.income, _):
      (kind, bucket, role) = (.income, .income, .none)
    case (.excluded, _):
      (kind, bucket, role) = (.excluded, .other, .none)
    }
    return HasalaModels.Category(
      id: info.id, name: info.name, kind: kind, bucket: bucket, glyph: glyph(info.icon), role: role,
      archived: !info.active, parent: info.parent, builtin: info.builtin)
  }

  static func byParent(_ infos: [CategoryInfo]) -> [CategoryInfo] {
    let ids = Set(infos.map(\.id))
    var children: [String: [CategoryInfo]] = [:]
    var top: [CategoryInfo] = []
    for c in infos {
      if !c.builtin, let p = c.parent, ids.contains(p) { children[p, default: []].append(c) } else { top.append(c) }
    }
    return top.flatMap { [$0] + (children[$0.id] ?? []) }
  }

  /// 03c §1.7 icon tokens → HasalaModels' glyphs (the inverse of the seed export's table).
  static let glyphs: [String: Glyph] = [
    "house": .rent, "bolt": .utilities, "basket": .groceries, "car": .transport, "cross": .healthcare,
    "shield_check": .insurance, "fork_knife": .dining, "ticket": .entertainment, "bag": .shopping, "plane": .travel,
    "repeat": .subscriptions, "jar": .savingsJar, "trend": .investments, "card": .debt, "briefcase": .salary,
    "laptop": .freelance, "arrows_swap": .transfer, "receipt": .refunds, "flag": .flag, "tag": .tag,
  ]

  static func glyph(_ icon: String) -> Glyph { glyphs[icon] ?? .tag }

  static func icon(_ glyph: Glyph) -> String {
    glyphs.filter { $0.value == glyph }.map(\.key).sorted().first ?? "flag"
  }

  // MARK: Accounts

  static func accountKind(_ kind: String) -> AccountKind {
    switch kind {
    case "credit_card": .credit
    case "cash": .cash
    case "investment": .investment
    default: .current
    }
  }

  /// How rows name an account: "Emirates NBD", "DIB card"; otherwise its own name.
  static func shortName(_ a: CoreReplay.Account) -> String {
    guard let bank = a.institution, let name = bankNames[bank] else { return a.name }
    return a.kind == "credit_card" ? "\(name) card" : name
  }

  // MARK: Transactions

  static func txn(_ row: TxnRow, r: LedgerReader, ruleByID: [String: RuleRow], billID: String?) throws
    -> HasalaModels.Txn
  {
    let date = CivilDate(wire: row.localDate).map(local) ?? LocalDate(1970, 1, 1)
    let minutes = Int(((row.postedMs + LocalClock.offsetMs) % 86_400_000 + 86_400_000) % 86_400_000 / 60_000)
    let at = LocalDateTime(date: date, hour: minutes / 60, minute: minutes % 60)
    let timeKnown = row.postedPrecision != "day"
    var splits: [SplitLine] = []
    if row.split {
      splits = try r.parts(row.id).map {
        SplitLine(id: $0.idx, categoryID: $0.category, amount: Money(minor: $0.amountMinor, currency: row.currency),
                  homeMinor: .some($0.amountHomeMinor), note: $0.note ?? "")
      }
    }
    let source: HasalaModels.CategorySource? =
      switch row.categorySource {
      case "rule": .rule(pattern: row.categorySourceRef.flatMap { ruleByID[$0]?.patterns.first } ?? "")
      case "dictionary": .dictionary
      case "model": .model(tag: row.categorySourceRef)
      case "user", "held": .user
      default: nil
      }
    let provenance = row.entryMethod == "mailbox"
      ? Provenance(
        title: "\(row.bank.flatMap { bankNames[$0] } ?? "Bank") transaction alert",
        readAt: timeKnown ? "Read automatically at \(at.time)" : "Read automatically", rawMerchant: row.merchantRaw,
        senderCheck: row.senderCheck)
      : nil
    return HasalaModels.Txn(
      id: row.id, merchant: row.displayName, place: row.location, amount: Money(minor: row.amountMinor, currency: row.currency),
      homeMinor: .some(row.amountHomeMinor),
      homeSource: .some(row.homeSource.flatMap { HasalaModels.HomeSource(rawValue: $0.rawValue) }), homeRateMicro: row.homeRateMicro,
      direction: row.direction == "credit" ? .in : .out, postedAt: at, postedTimeKnown: timeKnown, accountID: row.effectiveAccountID,
      categoryID: row.category, categorySource: source, needsReview: row.needsReview, isNewMerchant: row.isNewMerchant,
      suggestion: nil, note: row.note ?? "", splits: splits,
      isRefund: row.category == "refunds" || row.refundState != nil,
      isTransfer: row.category == "transfer" || row.transferState != nil, archived: row.archived != nil,
      projectID: row.projectID, billID: billID, provenance: provenance,
      detailOverride: billID != nil ? "monthly bill" : nil, mailboxMessageID: row.mailboxMessageID,
      heldCopy: try heldCopy(row, r: r),
      reviewReason: row.reviewReason.flatMap { TxnReviewReason(rawValue: $0.rawValue) }, merchantKey: row.merchantKey,
      merchantGroup: row.merchantGroup, categorizedAt: row.categorizedMs.map(localTime),
      ruleID: row.categorySource == "rule" ? row.categorySourceRef : nil)
  }

  static func localTime(_ ms: Int64) -> LocalDateTime {
    let date = LocalClock.localDate(ms).map(local) ?? LocalDate(1970, 1, 1)
    let minutes = Int(((ms + LocalClock.offsetMs) % 86_400_000 + 86_400_000) % 86_400_000 / 60_000)
    return LocalDateTime(date: date, hour: minutes / 60, minute: minutes % 60)
  }

  static func samePurchaseRow(_ row: TxnRow) -> SamePurchase.Row { row.samePurchaseRow }

  static func markSamePurchases(_ txns: inout [HasalaModels.Txn], rows: [TxnRow], home: String) {
    let pairs = SamePurchase.pairs(rows.map(samePurchaseRow), home: home)
    guard !pairs.isEmpty else { return }
    let index = Dictionary(txns.indices.map { (txns[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
    for p in pairs {
      guard let i = index[p.home], index[p.foreign] != nil else { continue }
      txns[i].samePurchase = SamePurchaseMatch(of: p.foreign, merchantMissing: p.merchantMissing)
    }
  }

  static func heldCopy(_ row: TxnRow, r: LedgerReader) throws -> HeldCopy? {
    guard row.heldCopy, let other = row.copyOf else { return nil }
    let source = try r.txn(other)?.sourceMailbox
    return HeldCopy(of: other, fromOtherInbox: source != row.sourceMailbox)
  }

  // MARK: Bills

  static func charged(_ t: HasalaModels.Txn, in currency: String) -> Money? {
    if t.amount.currency == currency { return t.amount }
    return currency == Money.home ? t.homeMinor.map(Money.aed) : nil
  }

  static func clamp(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
    LocalDate(year, month, min(day, CivilCalendar.daysIn(year: year, month: month)))
  }

  /// The next payday on or after `after` (day clamped to short months).
  static func nextPayday(_ day: Int, after: LocalDate) -> LocalDate {
    let this = clamp(after.year, after.month, day)
    if this >= after { return this }
    let n = after.yearMonth.next
    return clamp(n.year, n.month, day)
  }

  // MARK: Mailbox

  /// Bank alerts' health for Profile (spec 04 §7.10; content-free).
  static func health(_ st: MailboxStatus, nowMs: Int64) -> MailboxHealth {
    let status: MailboxHealth.Status
    switch st.hero {
    case .working, .otherDevice: status = .working
    case .catchingUp:
      // The first import (scan and backfill) is "importing"; an active lane that hasn't
      // succeeded for a while is still working.
      switch st.phase {
      case .scanning, .awaitingCards, .authoringBackfill: status = .importing
      default: status = .working
      }
    case .needsYou: status = .reconnect
    case .notConnected: status = .notConnected
    }
    let newest = st.health.compactMap(\.lastEmailAtMs).max() ?? st.lastSuccessAtMs
    let names = Set(st.health.compactMap { bankName(domain: $0.domain) }).sorted()
    return MailboxHealth(
      status: status, lastEmail: newest.map { ago(nowMs - $0) } ?? "", banks: names.joined(separator: " and "),
      unreadable: st.unreadable)
  }

  /// Each bank's sender domains, from its bundled templates (03c §7.2), e.g. Emirates NBD
  /// → emiratesnbd.com: a health row names its bank by the template it matched.
  static let bankDomains: [(bank: String, domains: [String])] = bankNames.keys.sorted().map {
    (bank: $0, domains: MailboxLane.senderDomains(bank: $0))
  }

  static func bank(domain: String) -> String? {
    bankDomains.first { BankDomains.isMember(domain, of: $0.domains) }?.bank
  }

  /// The bank a sender domain belongs to, if it is one the beta reads.
  static func bankName(domain: String) -> String? {
    bank(domain: domain).flatMap { bankNames[$0] }
  }

  /// "4 min ago", "3 h ago", "2 days ago".
  static func ago(_ ms: Int64) -> String {
    let minutes = max(0, ms / 60_000)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
    return "\(minutes / (24 * 60)) days ago"
  }

  // MARK: Rules

  static func ruleMatch(_ m: String) -> RuleMatch {
    switch m {
    case "starts_with": .startsWith
    case "exact": .exact
    default: .contains
    }
  }

  // MARK: Dates

  static func local(_ d: CivilDate) -> LocalDate { LocalDate(d.year, d.month, d.day) }

  /// The local day of an RFC 3339 instant.
  static func localDay(_ instant: String) -> LocalDate? {
    guard let ms = try? parseInstantMs(instant), let d = LocalClock.localDate(ms) else { return nil }
    return local(d)
  }
}
